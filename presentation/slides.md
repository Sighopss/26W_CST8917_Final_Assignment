# Expense Approval Pipeline - Durable Functions vs Logic Apps

Slide deck outline. Import into PowerPoint / Google Slides / Keynote.
Suggested count: 14-16 slides for a 10-15 minute presentation.

---

## Slide 1 - Title

- Compare & Contrast: Dual Implementation of an Expense Approval Workflow
- CST8917 - Serverless Applications (Winter 2026)
- Trevor Kutto | 041164341
- April 2026

---

## Slide 2 - Agenda

1. The workflow and business rules
2. Version A - Durable Functions
3. Version B - Logic Apps + Service Bus
4. Head-to-head comparison (6 dimensions)
5. Recommendation
6. Lessons learned

---

## Slide 3 - The workflow

- Employee submits an expense
- Validate required fields + category
- Under $100 -> auto-approve
- $100 or more -> manager decision
- No decision within timeout -> escalate
- Always: email the employee with the outcome

Valid categories: travel, meals, supplies, equipment, software, other

---

## Slide 4 - Version A architecture

Diagram:

```
HTTP POST /api/expenses
        |
        v
  Client Function  --- starts --->  Orchestrator
                                       |
                 +---------------------+---------------------+
                 |                     |                     |
           validate_expense    (< $100 auto-approve)  (>= $100 HITL)
                 |                     |                     |
                 |                     |            wait_for_external_event
                 |                     |            ||  timer (timeout)
                 |                     |                     |
                 +---------> send_notification <-------------+
                                       |
                                 log_outcome
```

Key design choices:
- Single `function_app.py` (Python v2 model)
- `task_any([timer, event])` for the HITL race
- Activities are pure functions -> unit testable

---

## Slide 5 - Version A live demo

**A-1: Auto-approve ($50)**
- Under the $100 threshold, no human needed
- Validate -> auto-approve -> notify -> log in under 10 seconds
- Final status: `auto_approved`

**A-2: Manager approve ($1,500)**
- Orchestrator parks in `Running` state, waiting on the `ManagerDecision` event
- Raise the event with `approve` -> orchestrator wakes, publishes outcome, completes
- Approver captured in the output

**A-3: Escalation ($1,500, no decision)**
- Fire and forget - no decision sent
- While the 60-second timer runs, show the orchestrator in the editor
- HITL pattern: `wait_for_external_event` races `create_timer`, `task_any` picks the winner
- Timer wins -> status flips to `escalated`

---

## Slide 6 - Version B architecture

```
Service Bus queue: expense-requests
        |
        v
  Logic App (main)
    +- Parse message
    +- HTTP -> /api/validate-expense      (Function)
    +- If valid && auto_approve -> publish "approved"
    +- If valid && needs-manager -> HttpWebhook action
        subscribe: POST /api/request-approval   -> sends email w/ 2 links
        manager GETs /api/approval-callback     -> POST to listCallbackUrl
        success: publish "approved" / "rejected"
        timeout: publish "escalated"
    +- Else -> publish "rejected" (validation error)
        |
        v
Service Bus topic: expense-outcomes
    +- sub-approved   (filter: outcome = 'approved')
    +- sub-rejected   (filter: outcome = 'rejected')
    +- sub-escalated  (filter: outcome = 'escalated')
        |
        v
 3 notifier Logic Apps -> email employee
```

---

## Slide 7 - Version B live demo

Trigger is a Service Bus message, not HTTP. Show everything in the Azure portal run history.

**B-1: Auto-approve ($50)**
- Message lands on `expense-requests` queue
- Main Logic App picks it up, validate function returns `auto_approve`
- Publish `approved` to the outcomes topic
- Approved-notifier subscription fires -> email sent
- Two Logic App runs to point at in the portal: `main` and `notify-approved`

**B-2 + B-3: Manager approve + reject**
- Two messages: $1,500 travel, $2,500 equipment
- Main Logic App parks on the `HttpWebhook` action - same HITL pattern, different shape
- Manager clicks approve on one, reject on the other
- Webhook resumes, publishes outcome, correct notifier fires
- Show both `notify-approved` and `notify-rejected` run history

**B-4: Escalation**
- No live demo - `approvalTimeout` is 10 minutes, too long for camera
- Walk through it in the designer: `runAfter: [TimedOut]` branch publishes `escalated`
- Escalated-notifier emails the employee
- Same timer-vs-event race as Version A, declarative instead of programmatic

---

## Slide 8 - Comparison: Development experience

| Metric                   | Durable Functions | Logic Apps             |
| ------------------------ | ----------------- | ---------------------- |
| Initial scaffolding time | Medium            | Fast                   |
| Iteration speed          | Fast (file save)  | Medium (deploy or portal edit) |
| IntelliSense / linting   | Yes               | Limited in code view   |
| Non-developer readable   | No                | Yes                    |

---

## Slide 9 - Comparison: Testability

| Metric                   | Durable Functions | Logic Apps             |
| ------------------------ | ----------------- | ---------------------- |
| Local tests              | pytest + func start | Almost none           |
| Automated CI             | Straightforward   | Hard (needs deployed resources) |
| Debugger support         | Full              | Run history only       |

---

## Slide 10 - Comparison: Error handling

- Logic Apps: declarative retry policies per action, built-in DLQ from Service Bus
- Durable Functions: programmatic retries, sub-orchestrations for compensation
- HTTP webhook timeout in Logic Apps -> `runAfter: [TimedOut]` branch (clean)
- Durable timer vs event race -> pattern fits HITL perfectly

---

## Slide 11 - Comparison: Human Interaction

| Aspect                | Durable Functions  | Logic Apps          |
| --------------------- | ------------------ | ------------------- |
| First-class primitive | Yes                | No (HttpWebhook + helper) |
| Lines/components      | ~5 lines of Python | 1 Logic App action + 2 helper Functions |
| Debuggability         | Breakpoint inside orchestrator | Portal-only |

---

## Slide 12 - Comparison: Observability & cost

Observability:
- Logic Apps: portal run history is unbeatable for a single run, zero setup
- Durable Functions: Application Insights + KQL, more power, steeper learning curve

Cost (rough monthly, East US, Consumption):

| Volume         | Version A | Version B |
| -------------- | --------- | --------- |
| 100/day        | ~$0-1     | ~$14      |
| 10,000/day     | ~$35-40   | ~$385-400 |

Key driver: Logic Apps charges per *action*; Durable Functions charges per *execution*.

---

## Slide 13 - Recommendation

**I would build this in Durable Functions.**

- HITL is a first-class primitive (3 lines vs 4 components)
- Full local testing and debugging
- ~10x cheaper at 10,000 requests/day
- Compensation patterns via sub-orchestrations

Choose Logic Apps when:
- Business analysts, not developers, own the workflow
- Integration-heavy (Salesforce, SharePoint, Slack) where connectors save weeks
- Observability for non-engineers is paramount

---

## Slide 14 - Lessons learned

- Orchestrator determinism is real: `context.current_utc_datetime`, never `datetime.utcnow()`
- Logic Apps "visual" stops at 80% - the last 20% is JSON and string templating
- `HttpWebhook` in Logic Apps is powerful but needs a bridge to play nicely with email clients
- If I redid Version B I would try Standard Logic Apps (workflow-as-code, local runtime) to close the testability gap

---

## Slide 15 - Q&A / Thank you

- Repository: <paste GitHub URL>
- Video: <paste YouTube URL>
- Contact: Trevor Kutto
