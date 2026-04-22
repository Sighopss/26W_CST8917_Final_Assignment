# Compare & Contrast: Dual Implementation of an Expense Approval Workflow

| Field              | Value                                                                       |
| ------------------ | --------------------------------------------------------------------------- |
| **Student Name**   | Trevor Kutto                                                                |
| **Student Number** | 041164341                                                                   |
| **Course**         | CST8917 - Serverless Applications                                           |
| **Project**        | Final Project - Durable Functions vs Logic Apps + Service Bus               |
| **Term**           | Winter 2026                                                                 |
| **Date**           | April 2026                                                                  |

---

## Repository Layout

```
CST8917-FinalProject-TrevorKutto/
├── README.md                               (this file)
├── version-a-durable-functions/
│   ├── function_app.py                     (orchestrator + activities + client)
│   ├── host.json
│   ├── requirements.txt
│   ├── local.settings.example.json
│   └── test-durable.http                   (6 test scenarios)
├── version-b-logic-apps/
│   ├── function_app.py                     (validation + approval helpers)
│   ├── host.json
│   ├── requirements.txt
│   ├── local.settings.example.json
│   ├── test-expense.http                   (6 test scenarios)
│   ├── infra/
│   │   ├── servicebus.bicep                (queue + topic + 3 filtered subs)
│   │   ├── workflow.json                   (main Logic App)
│   │   ├── notifier-workflow.json          (per-subscription notifier Logic App)
│   │   └── README.md
│   └── screenshots/
└── presentation/
    ├── slides.md                           (slide outline - source for the deck)
    ├── slides.pptx                         (final PowerPoint deck for submission)
    └── video-link.md
```

---

## Version A Summary - Azure Durable Functions (Python v2)

Version A implements the full expense approval pipeline inside a single `function_app.py` using the Python v2 programming model with Durable Functions. The entry point is an anonymous HTTP trigger `POST /api/expenses` (the **client function**) that hands the payload to the `expense_orchestrator`. The orchestrator calls a `validate_expense` **activity**, short-circuits to a notification if validation fails, then either auto-approves expenses below `AUTO_APPROVE_THRESHOLD` (default `$100`) or enters the **Human Interaction pattern**.

The human-interaction block is a direct race between a durable timer and a named external event:

```python
deadline = context.current_utc_datetime + timedelta(seconds=APPROVAL_TIMEOUT_SECONDS)
timer_task = context.create_timer(deadline)
event_task = context.wait_for_external_event("ManagerDecision")
winner = yield context.task_any([timer_task, event_task])
```

A second HTTP endpoint `POST /api/expenses/{instance_id}/decision` simulates the manager's approve/reject click and raises the `ManagerDecision` event via `client.raise_event`. If the timer wins first, the orchestration flags the request as `escalated`. All paths converge on a `send_notification` activity and an audit `log_outcome` activity.

**Design decisions**

- **Single `function_app.py`** - the v2 programming model means everything (triggers, orchestrators, activities, client bindings) ships in one file with decorators. No per-function folder structure.
- **`task_any` over `call_activity_with_retry`** - the HITL pattern is fundamentally a race, so expressing it as `task_any` is more honest than polling.
- **Thresholds read from env** - makes the six test scenarios reproducible without code changes.
- **Validation is an activity** (not inline in the orchestrator) - keeps the orchestrator deterministic and lets me unit-test validation in isolation.

**Challenges**

- Orchestrator determinism: my first draft used `datetime.utcnow()` inside the orchestrator, which fails on replay. Fix: always use `context.current_utc_datetime`.
- Local storage emulator: Durable Functions needs Azurite (or a real storage account). Starting Azurite before `func start` is a prerequisite that did not apply to Version B.

---

## Version B Summary - Logic Apps + Service Bus

Version B moves orchestration into a visual Logic App. The entry point is the **`expense-requests` Service Bus queue**; each message body is a JSON expense. The Logic App:

1. Peeks a message, parses the JSON.
2. Calls the Azure Function at `/api/validate-expense` via an HTTP action (retry policy: 3 attempts, exponential backoff).
3. Branches on `validation.valid`, then on `validation.auto_approve`.
4. For manager-approval branch, uses an **`HttpWebhook` action** whose subscribe step posts to `/api/request-approval` on the same Function App. That helper sends the manager an HTML email containing two one-click links to `/api/approval-callback?callback=...&decision=approve|reject`. The callback function POSTs the decision to the `listCallbackUrl()` the Logic App handed out, which resumes the paused workflow. The action's `limit.timeout` (e.g. `PT2M`) is the escalation trigger.
5. Publishes the final outcome to the **`expense-outcomes` Service Bus topic** with a custom `outcome` property (`approved` / `rejected` / `escalated`).
6. Completes the queue message.

The topic has **three SQL-filtered subscriptions** (`sub-approved`, `sub-rejected`, `sub-escalated`). Each subscription is consumed by a dedicated notifier Logic App (`notifier-workflow.json`) that emails the employee via the Office 365 connector.

**Manager-approval approach (the HTTP webhook pattern)**

Logic Apps has no first-class "pause until a human clicks a link" action. The cleanest pattern is `HttpWebhook`, which exposes `listCallbackUrl()` inside the subscribe block. Because email clients cannot POST JSON to that URL (they can only GET links), I added a tiny Python bridge: `/api/approval-callback` accepts the manager's GET, forwards a POST to the callback URL, and returns a friendly HTML confirmation page. This keeps the Logic App's visual semantics (single action that pauses and resumes) while giving the manager a one-click experience in email.

**Challenges**

- `HttpWebhook` + email-link handoff required two helper endpoints that do not exist in Version A. The Logic App is visually clean, but "clean" hides a real Function App dependency.
- Encoding the `listCallbackUrl()` through the Function URL query string needed double-URL-encoding to survive both hops.
- Authoring the workflow in the Azure portal designer is fast until you need a conditional on a raw expression - then you end up in code view anyway.

---

## Comparison Analysis



### 1. Development Experience

Version A was noticeably faster once the scaffolding was done. The whole pipeline fits in one Python file, the decorators carry all the metadata, and iterating means saving the file and re-running `func start`. IntelliSense, linting, `black`, and type hints all "just work" because it is ordinary Python. Debugging is the standout: I set a breakpoint on the orchestrator, replayed an instance, and stepped through the exact path that would run in Azure. When my first attempt accidentally called `datetime.utcnow()` the replay detector barked immediately - a class of bug Logic Apps cannot produce because it does not offer that primitive to begin with.

Version B was faster to *visualize* but slower to *author*. The Azure portal designer is great for the first 80% - trigger, condition, action, done - and then you spend the next 40% of your time in code view fighting the workflow definition language (`@{concat(...)}`, `@body(...)?[...]`, nested `createObject`). Three full iterations of the workflow definition were needed before the Service Bus `ApiConnection` message body accepted a base64-encoded JSON payload without mangling it.

Winner: **Version A** for *correctness confidence*. The code I wrote is the code that runs. Winner: **Version B** for *explainability to non-engineers* - the run-history graph was immediately legible to a non-developer colleague.

### 2. Testability

Version A can be fully tested locally. I wrote the activity functions as pure Python (`validate_expense`, `send_notification`, `log_outcome`), and they can be unit-tested with `pytest` because they are just functions with dict input/output. The orchestrator itself can be exercised with `DurableOrchestrationContext` mocks or end-to-end through `func start` plus the `test-durable.http` file. Integration testing is a loop of "post JSON → read instance status → raise event → assert outcome" that completes in under a second per scenario.

Version B's validation Function is equally testable, but the Logic App orchestration itself is effectively *untestable* outside Azure. There is no `func start`-equivalent for Consumption Logic Apps (Standard Logic Apps improve this, but the project uses Consumption). Every test requires deployed resources, a real Service Bus, and checking run history through the portal. I could not automate any part of this - every scenario in `test-expense.http` has to be poked manually and verified visually.

Winner: **Version A**, decisively.

### 3. Error Handling

Version B's retry policies are the nicest surface feature it has: `"retryPolicy": {"type": "exponential", "count": 3}` on any HTTP action, declaratively, without a line of code. `runAfter: ["TimedOut", "Failed"]` gives me a clean catch branch for the `HttpWebhook` timeout. Service Bus brings dead-letter queues, max-delivery counts, and TTL for free.

Version A's error handling is more flexible but more code. I can wrap an activity call in `try/except` around a `yield`, use `call_activity_with_retry` with a custom `RetryOptions`, or stick a compensation activity in a finally-style scope. The Durable Task framework gives me sub-orchestrations for transactional rollback (which Logic Apps cannot express). The price is that every retry nuance becomes a tested-and-reviewed code change rather than a JSON knob.

Winner: **Version B** for common cases (retry an HTTP call, dead-letter a message). Winner: **Version A** for anything resembling a compensating transaction or a bespoke retry policy.

### 4. Human Interaction Pattern

This is where the two implementations diverge most. In Durable Functions the HITL pattern is a first-class primitive - `wait_for_external_event` raced against `create_timer` - and it is three lines of code in the orchestrator. The durable timer is provably reliable because it is backed by the task hub, not a sleeping worker.

In Logic Apps the equivalent took an `HttpWebhook` action, two helper Function endpoints (`request-approval` to send email, `approval-callback` to bridge GET→POST), and double-URL-encoded callback URLs. It works, the designer shows the pause clearly, the timeout field is a single ISO-8601 string - but getting it to work required writing just as much Python as Version A *and* the workflow JSON *and* the infra.

Winner: **Version A**, comfortably. The Human Interaction pattern is Durable Functions' home turf.

### 5. Observability

Logic Apps wins this one hands-down for a single run. The portal's run history shows every action's input, output, and duration, colour-coded by status, for every instance, with no setup. For the escalation scenario I can literally point at the `Wait_for_manager_decision` box and say "this is where the timer beat the event". Non-developers get this immediately.

Durable Functions' observability is in Application Insights: `customEvents`, `dependencies`, and the instance table in the default storage account. It is *more* powerful (correlated traces, custom queries, export to workbooks) but *less* approachable. You need to know KQL to extract the same facts Logic Apps shows on a default screen.

Winner: **Version B** for demos and ad-hoc debugging. Winner: **Version A** at scale, once you have invested in KQL workbooks.

### 6. Cost

Assumptions for both estimates: East US region, Consumption SKUs, average payload under 10 KB, Application Insights free tier, Service Bus Standard.

At **~100 expenses/day (3 000/month)**:

- *Version A*: ~30 000 Durable Functions executions/month (orchestrator replays included, ~10× multiplier), which fits inside the 1 M free grant on Consumption. Storage account transactions for the task hub: ~60 000, roughly **$0.05**. Practical cost: **~$0-1/month**, dominated by Application Insights ingestion above the 5 GB free tier.
- *Version B*: ~3 000 Logic App runs × ~10 actions each = 30 000 actions at **$0.000125/action** = **$3.75**. Service Bus Standard base = **$10/month**. Function App for validation = inside the 1 M free grant. Total: **~$14/month**.

At **~10 000 expenses/day (300 000/month)**:

- *Version A*: ~3 M DF executions. Consumption pricing: 2 M billable × $0.000016 = **~$32**. Storage transactions ~6 M × $0.0004/10 K = **~$0.24**. Total: **~$35-40/month** plus Application Insights at actual volume.
- *Version B*: 300 000 runs × 10 actions = 3 M actions × $0.000125 = **$375**. Service Bus Standard base **$10**. Function App inside or just over free grant. Total: **~$385-400/month**.

Winner: **Version A**, by roughly **10×** at 10 000/day, and the gap widens with scale because Logic Apps charges per action while Durable Functions charges per execution with the orchestrator overhead amortized.

---

## Recommendation

If a team asked me to build this expense pipeline for production today, I would choose **Version A - Durable Functions** and keep Service Bus only for queue-based intake. Three reasons carry the decision: the Human Interaction pattern is a single `wait_for_external_event` race against a durable timer rather than a four-component HTTP webhook handoff; the code is unit-testable and debuggable locally without ever touching Azure; and the cost curve is roughly an order of magnitude better at the 10 000-requests-per-day scale we estimated. The compensation-style error handling Durable Functions gives me through sub-orchestrations is also a better fit for a financial workflow where partial failures need to roll the whole transaction back.

That said, I would flip the recommendation in two situations. The first is an operations-heavy team where business analysts, not engineers, own the workflow. Logic Apps' designer and run-history view are genuinely better than any KQL workbook for a non-developer - being able to point at the exact action box that failed, in colour, with inputs and outputs, is a first-class debugging experience. The second is a fast-changing integration workflow that lives mostly at the connector layer - sending to Slack, pulling from SharePoint, calling Salesforce - where Logic Apps' 400+ managed connectors would replace weeks of custom SDK work with a few drag-and-drop actions. For the specific brief here (validate → branch → pause for human → notify), Durable Functions is the better tool; for a "shuffle data between five SaaS systems" brief with the same business rules, Logic Apps would win.

---

## References

- Microsoft Docs - *Azure Durable Functions overview*: https://learn.microsoft.com/azure/azure-functions/durable/durable-functions-overview
- Microsoft Docs - *Human interaction in Durable Functions*: https://learn.microsoft.com/azure/azure-functions/durable/durable-functions-phone-verification
- Microsoft Docs - *Durable Functions Python v2 programming model*: https://learn.microsoft.com/azure/azure-functions/durable/durable-functions-reference-python
- Microsoft Docs - *Logic Apps workflow definition language*: https://learn.microsoft.com/azure/logic-apps/logic-apps-workflow-definition-language
- Microsoft Docs - *Wait for response from external service (HttpWebhook action)*: https://learn.microsoft.com/azure/logic-apps/logic-apps-workflow-actions-triggers#httpwebhook-action
- Microsoft Docs - *Service Bus topics and subscriptions*: https://learn.microsoft.com/azure/service-bus-messaging/service-bus-queues-topics-subscriptions
- Microsoft Docs - *Service Bus message routing with SQL filters*: https://learn.microsoft.com/azure/service-bus-messaging/topic-filters
- Azure Pricing Calculator: https://azure.microsoft.com/pricing/calculator/
- Azure Functions Pricing: https://azure.microsoft.com/pricing/details/functions/
- Logic Apps Pricing: https://azure.microsoft.com/pricing/details/logic-apps/
- Service Bus Pricing: https://azure.microsoft.com/pricing/details/service-bus/
- CST8917 Labs 1-4 (course materials, Algonquin College, Winter 2026).

---

## AI Disclosure

AI tools were used during this project. **Cursor** (a VS Code fork) with the **Claude** model family assisted with:

- Scaffolding the repository layout and boilerplate for `function_app.py` in both versions.
- Drafting the initial Logic App workflow JSON (`workflow.json`, `notifier-workflow.json`) and the Service Bus Bicep file.
- Suggesting the HTTP-webhook + callback-bridge pattern for the Logic Apps human-interaction step.
- First drafts of this README, including the structure of the comparison analysis and cost estimates.

All code was read, modified, and validated by me before inclusion. Test scenarios were designed by me based on the six required cases. Cost assumptions and numeric estimates were derived from the Azure Pricing Calculator and cross-checked against the official pricing documentation cited above. The recommendation and lessons learned are my own conclusions drawn from implementing both versions. All figures, design decisions, and trade-off arguments reflect my own understanding of the material and my direct experience building the two implementations.
