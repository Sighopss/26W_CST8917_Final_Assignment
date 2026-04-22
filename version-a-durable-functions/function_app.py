"""
Expense Approval Pipeline - Version A (Azure Durable Functions, Python v2).

Flow:
  1. HTTP POST /api/expenses                -> client starter kicks off orchestrator
  2. Orchestrator validates input (activity).
  3. If amount < 100            -> auto-approve -> notify employee (activity)
     If amount >= 100           -> wait_for_external_event("ManagerDecision")
                                    with durable timer race (timeout -> escalated)
                                 -> notify employee
  4. HTTP POST /api/expenses/{instance_id}/decision  -> raises ManagerDecision event
"""

import json
import logging
import os
from datetime import timedelta

import azure.durable_functions as df
import azure.functions as func

app = df.DFApp(http_auth_level=func.AuthLevel.ANONYMOUS)

AUTO_APPROVE_THRESHOLD = float(os.getenv("AUTO_APPROVE_THRESHOLD", "100"))
APPROVAL_TIMEOUT_SECONDS = int(os.getenv("APPROVAL_TIMEOUT_SECONDS", "60"))
VALID_CATEGORIES = {"travel", "meals", "supplies", "equipment", "software", "other"}
REQUIRED_FIELDS = ("employee_name", "employee_email", "amount", "category", "description", "manager_email")


# ----------------------------- HTTP client starter -----------------------------
@app.route(route="expenses", methods=["POST"])
@app.durable_client_input(client_name="client")
async def start_expense(req: func.HttpRequest, client) -> func.HttpResponse:
    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Request body must be valid JSON"}),
            status_code=400, mimetype="application/json",
        )

    instance_id = await client.start_new("expense_orchestrator", None, payload)
    logging.info("Started orchestration instance %s", instance_id)

    base = req.url.split("/api/")[0]
    body = {
        "instance_id": instance_id,
        "decision_url": f"{base}/api/expenses/{instance_id}/decision",
        "status_url": f"{base}/runtime/webhooks/durabletask/instances/{instance_id}",
    }
    return func.HttpResponse(json.dumps(body), status_code=202, mimetype="application/json")


# ----------------------------- Manager decision webhook -----------------------------
@app.route(route="expenses/{instance_id}/decision", methods=["POST"])
@app.durable_client_input(client_name="client")
async def manager_decision(req: func.HttpRequest, client) -> func.HttpResponse:
    instance_id = req.route_params.get("instance_id")
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Body must be JSON: {\"decision\":\"approve|reject\",\"approver\":\"...\"}"}),
            status_code=400, mimetype="application/json",
        )

    decision = (body.get("decision") or "").lower().strip()
    if decision not in {"approve", "reject"}:
        return func.HttpResponse(
            json.dumps({"error": "decision must be 'approve' or 'reject'"}),
            status_code=400, mimetype="application/json",
        )

    status = await client.get_status(instance_id)
    if status is None or status.runtime_status is None:
        return func.HttpResponse(
            json.dumps({"error": f"Instance {instance_id} not found"}),
            status_code=404, mimetype="application/json",
        )

    await client.raise_event(instance_id, "ManagerDecision", {
        "decision": decision,
        "approver": body.get("approver", "unknown"),
        "comment": body.get("comment"),
    })
    return func.HttpResponse(
        json.dumps({"ok": True, "instance_id": instance_id, "decision": decision}),
        status_code=200, mimetype="application/json",
    )


# ----------------------------- Orchestrator -----------------------------
@app.orchestration_trigger(context_name="context")
def expense_orchestrator(context: df.DurableOrchestrationContext):
    expense = context.get_input() or {}

    validation = yield context.call_activity("validate_expense", expense)
    if not validation["valid"]:
        yield context.call_activity("send_notification", {
            "to": expense.get("employee_email", "unknown"),
            "subject": "Expense rejected - validation failed",
            "status": "validation_error",
            "expense": expense,
            "errors": validation["errors"],
        })
        return {"status": "validation_error", "errors": validation["errors"]}

    amount = float(expense["amount"])

    if amount < AUTO_APPROVE_THRESHOLD:
        outcome = {"status": "auto_approved", "approver": "system", "amount": amount}
    else:
        deadline = context.current_utc_datetime + timedelta(seconds=APPROVAL_TIMEOUT_SECONDS)
        timer_task = context.create_timer(deadline)
        event_task = context.wait_for_external_event("ManagerDecision")
        winner = yield context.task_any([timer_task, event_task])

        if winner == event_task:
            timer_task.cancel()
            raw = event_task.result
            if isinstance(raw, str):
                try:
                    raw = json.loads(raw)
                except ValueError:
                    raw = {"decision": raw}
            if not isinstance(raw, dict):
                raw = {"decision": str(raw)}
            status = "approved" if raw.get("decision") == "approve" else "rejected"
            outcome = {
                "status": status,
                "approver": raw.get("approver", "unknown"),
                "comment": raw.get("comment"),
                "amount": amount,
            }
        else:
            outcome = {"status": "escalated", "approver": "system_timeout", "amount": amount}

    yield context.call_activity("send_notification", {
        "to": expense["employee_email"],
        "subject": f"Expense {outcome['status']}",
        "status": outcome["status"],
        "expense": expense,
        "outcome": outcome,
    })
    yield context.call_activity("log_outcome", {"expense": expense, "outcome": outcome})
    return outcome


# ----------------------------- Activities -----------------------------
@app.activity_trigger(input_name="expense")
def validate_expense(expense: dict) -> dict:
    errors = []

    if not isinstance(expense, dict):
        return {"valid": False, "errors": ["Request body must be a JSON object"]}

    for field in REQUIRED_FIELDS:
        value = expense.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append(f"Missing required field: {field}")

    category = str(expense.get("category", "")).lower().strip()
    if category and category not in VALID_CATEGORIES:
        errors.append(f"Invalid category '{category}'. Valid: {sorted(VALID_CATEGORIES)}")

    amount = expense.get("amount")
    try:
        amount_val = float(amount)
        if amount_val <= 0:
            errors.append("amount must be greater than 0")
    except (TypeError, ValueError):
        errors.append("amount must be a number")

    return {"valid": not errors, "errors": errors}


@app.activity_trigger(input_name="payload")
def send_notification(payload: dict) -> dict:
    """Stub email sender. In production swap for SendGrid / ACS Email / SMTP."""
    logging.info("NOTIFY -> %s | subject=%s | status=%s",
                 payload.get("to"), payload.get("subject"), payload.get("status"))
    return {"sent": True, "to": payload.get("to"), "status": payload.get("status")}


@app.activity_trigger(input_name="record")
def log_outcome(record: dict) -> dict:
    logging.info("OUTCOME %s", json.dumps(record, default=str))
    return {"logged": True}
