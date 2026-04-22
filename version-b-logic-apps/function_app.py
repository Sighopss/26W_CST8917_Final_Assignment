"""
Expense Approval Pipeline - Version B (Azure Functions validation service).

This Function exposes a single HTTP endpoint the Logic App calls as its first
step. Keeping validation here (instead of inside Logic App conditions) gives us:

  * Unit-testable Python with the same rules as Version A
  * Clean separation: Logic App = orchestration, Function = business rules
  * Reusable contract if we later want to swap Logic App for something else

Endpoint: POST /api/validate-expense
Body:    <raw expense JSON>
Returns: { "valid": bool, "errors": [str], "auto_approve": bool, "normalized": {...} }
"""

from __future__ import annotations

import json
import logging
import os
import urllib.parse
import urllib.request
from typing import Any

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

AUTO_APPROVE_THRESHOLD = float(os.getenv("AUTO_APPROVE_THRESHOLD", "100"))
VALID_CATEGORIES = {"travel", "meals", "supplies", "equipment", "software", "other"}
REQUIRED_FIELDS = ("employee_name", "employee_email", "amount", "category", "description", "manager_email")


@app.route(route="validate-expense", methods=["POST"])
def validate_expense(req: func.HttpRequest) -> func.HttpResponse:
    try:
        expense = req.get_json()
    except ValueError:
        return _json({"valid": False, "errors": ["Body must be valid JSON"], "auto_approve": False}, 400)

    result = _validate(expense)
    logging.info("Validation result: %s", result)
    return _json(result, 200)


def _validate(expense: Any) -> dict[str, Any]:
    errors: list[str] = []

    if not isinstance(expense, dict):
        return {"valid": False, "errors": ["Payload must be a JSON object"], "auto_approve": False}

    for field in REQUIRED_FIELDS:
        value = expense.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append(f"Missing required field: {field}")

    category = str(expense.get("category", "")).lower().strip()
    if category and category not in VALID_CATEGORIES:
        errors.append(f"Invalid category '{category}'. Valid: {sorted(VALID_CATEGORIES)}")

    amount_val: float | None = None
    try:
        amount_val = float(expense.get("amount"))
        if amount_val <= 0:
            errors.append("amount must be greater than 0")
    except (TypeError, ValueError):
        errors.append("amount must be a number")

    if errors:
        return {"valid": False, "errors": errors, "auto_approve": False}

    normalized = {
        "employee_name": expense["employee_name"],
        "employee_email": expense["employee_email"],
        "amount": amount_val,
        "category": category,
        "description": expense["description"],
        "manager_email": expense["manager_email"],
    }
    return {
        "valid": True,
        "errors": [],
        "auto_approve": amount_val < AUTO_APPROVE_THRESHOLD,
        "normalized": normalized,
    }


def _json(body: dict[str, Any], status: int) -> func.HttpResponse:
    return func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json")


@app.route(route="request-approval", methods=["POST"])
def request_approval(req: func.HttpRequest) -> func.HttpResponse:
    """
    Called by the Logic App's HTTP Webhook 'subscribe' step. Sends the manager
    an email containing two one-click links (approve / reject) that each point
    at /api/approval-callback. The callback endpoint then POSTs the decision
    back to the Logic App's listCallbackUrl, resuming the paused workflow.

    Body:
      {
        "callback_url": "<listCallbackUrl output from Logic App>",
        "expense": { ...normalized expense... }
      }
    """
    try:
        payload = req.get_json()
    except ValueError:
        return _json({"error": "Body must be JSON"}, 400)

    callback_url = payload.get("callback_url")
    expense = payload.get("expense") or {}
    if not callback_url or not expense.get("manager_email"):
        return _json({"error": "callback_url and expense.manager_email required"}, 400)

    callback_base = os.getenv("APPROVAL_CALLBACK_BASE_URL", "").rstrip("/")
    if not callback_base:
        return _json({"error": "APPROVAL_CALLBACK_BASE_URL not configured"}, 500)

    fn_key = os.getenv("APPROVAL_CALLBACK_FUNCTION_KEY", "")
    key_qs = f"&code={urllib.parse.quote(fn_key)}" if fn_key else ""
    encoded_cb = urllib.parse.quote(callback_url, safe="")

    approve_url = f"{callback_base}/api/approval-callback?callback={encoded_cb}&decision=approve{key_qs}"
    reject_url = f"{callback_base}/api/approval-callback?callback={encoded_cb}&decision=reject{key_qs}"

    subject = f"Approval required: {expense.get('employee_name')} - ${expense.get('amount'):.2f}"
    body_html = (
        f"<p><strong>{expense.get('employee_name')}</strong> submitted a "
        f"${expense.get('amount'):.2f} {expense.get('category')} expense:</p>"
        f"<blockquote>{expense.get('description')}</blockquote>"
        f"<p><a href=\"{approve_url}\">APPROVE</a> &nbsp;|&nbsp; "
        f"<a href=\"{reject_url}\">REJECT</a></p>"
    )

    _send_email(expense["manager_email"], subject, body_html)
    logging.info("APPROVAL_LINKS manager=%s approve=%s reject=%s",
                 expense["manager_email"], approve_url, reject_url)
    return _json({"ok": True, "approve_url": approve_url, "reject_url": reject_url}, 200)


def _send_email(to: str, subject: str, html: str) -> None:
    """Send via SendGrid if SENDGRID_API_KEY is set; otherwise log (demo mode)."""
    sendgrid_key = os.getenv("SENDGRID_API_KEY")
    sender = os.getenv("EMAIL_FROM", "noreply@example.com")

    if not sendgrid_key:
        logging.info("EMAIL (demo mode) to=%s subject=%s html=%s", to, subject, html)
        return

    data = json.dumps({
        "personalizations": [{"to": [{"email": to}]}],
        "from": {"email": sender},
        "subject": subject,
        "content": [{"type": "text/html", "value": html}],
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://api.sendgrid.com/v3/mail/send",
        data=data,
        headers={"Authorization": f"Bearer {sendgrid_key}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        logging.info("SendGrid accepted, status=%s", resp.status)


@app.route(route="send-notification", methods=["POST"])
def send_notification(req: func.HttpRequest) -> func.HttpResponse:
    """
    Called by the notifier Logic Apps for each topic subscription. Sends the
    employee an email describing the final outcome (approved / rejected /
    escalated). Falls back to log-only if SENDGRID_API_KEY is not set.

    Body: {"outcome":"approved|rejected|escalated","expense":{...},"approver":"..."}
    """
    try:
        data = req.get_json()
    except ValueError:
        return _json({"error": "Body must be JSON"}, 400)

    expense = data.get("expense") or {}
    outcome = data.get("outcome") or "unknown"
    to = expense.get("employee_email")
    if not to:
        return _json({"error": "expense.employee_email required"}, 400)

    subject = f"Your expense was {outcome}"
    amount = expense.get("amount")
    amount_str = f"${float(amount):.2f}" if amount is not None else "n/a"
    errors = data.get("errors") or []
    errors_html = ("<p><strong>Validation errors:</strong><ul>"
                   + "".join(f"<li>{e}</li>" for e in errors) + "</ul></p>") if errors else ""
    body_html = (
        f"<p>Hi {expense.get('employee_name','')},</p>"
        f"<p>Your <strong>{expense.get('category','')}</strong> expense for "
        f"<strong>{amount_str}</strong> has been <strong>{outcome.upper()}</strong>.</p>"
        f"<p>Description: {expense.get('description','')}</p>"
        f"<p>Approver: {data.get('approver','n/a')}</p>"
        f"{errors_html}"
    )

    _send_email(to, subject, body_html)
    return _json({"ok": True, "to": to, "outcome": outcome}, 200)


@app.route(route="approval-callback", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def approval_callback(req: func.HttpRequest) -> func.HttpResponse:
    """
    Bridge between the manager's one-click email link and the Logic App HTTP
    Webhook action. The email contains two links (approve / reject) that
    redirect here; this function forwards the decision as a POST to the
    Logic App's listCallbackUrl, which resumes the paused workflow.

    Query params:
      callback : URL-encoded Logic App callback URL (from listCallbackUrl())
      decision : 'approve' or 'reject'
      approver : optional string for audit trail
    """
    callback = req.params.get("callback")
    decision = (req.params.get("decision") or "").lower().strip()
    approver = req.params.get("approver", "manager")

    if not callback or decision not in {"approve", "reject"}:
        return func.HttpResponse("Missing or invalid 'callback' / 'decision' query params.", status_code=400)

    payload = json.dumps({"decision": decision, "approver": approver}).encode("utf-8")
    request = urllib.request.Request(
        urllib.parse.unquote(callback),
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as resp:
            logging.info("Forwarded decision=%s to Logic App, status=%s", decision, resp.status)
    except Exception as exc:  # noqa: BLE001 - surface any transport error to the manager
        logging.exception("Failed to forward decision to Logic App")
        return func.HttpResponse(f"Failed to record decision: {exc}", status_code=502)

    html = f"""<!doctype html><meta charset="utf-8"><title>Decision recorded</title>
    <body style="font-family:system-ui;padding:40px;max-width:560px;margin:auto">
    <h1>Thank you</h1>
    <p>Your decision <strong>{decision.upper()}</strong> has been recorded. You can close this tab.</p>
    </body>"""
    return func.HttpResponse(html, status_code=200, mimetype="text/html")
