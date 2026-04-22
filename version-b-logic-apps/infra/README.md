# Version B - Infrastructure

## Files

| File                    | Purpose                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------- |
| `servicebus.bicep`      | Service Bus namespace + `expense-requests` queue + `expense-outcomes` topic + 3 filtered subscriptions (`sub-approved`, `sub-rejected`, `sub-escalated`). |
| `workflow.json`         | Main Logic App workflow definition. Triggers on the queue, calls the validation Function, branches auto-approve / manager-decision / escalated, and publishes outcome messages to the topic. |
| `notifier-workflow.json`| Reusable notifier Logic App. Deploy three instances, one per subscription, each parameterized with `subscriptionName` so the correct employee email is sent. |

## Deployment outline

```bash
# 1. Resource group + Service Bus
az group create -n rg-expense-approval -l eastus
az deployment group create \
  -g rg-expense-approval \
  --template-file servicebus.bicep \
  --parameters namespaceName=sb-expense-<unique>

# 2. Azure Function (validation + approval helpers)
func azure functionapp publish <your-funcapp>

# 3. Logic App connections (portal): servicebus + office365
#    Then import workflow.json via "Logic app code view"
#    Parameters to set:
#      validateFunctionUrl = https://<funcapp>.azurewebsites.net/api/validate-expense?code=...
#      requestApprovalUrl  = https://<funcapp>.azurewebsites.net/api/request-approval?code=...
#      approvalTimeout     = PT2M  (or longer for production)

# 4. Deploy 3x notifier-workflow.json, set subscriptionName per instance:
#      sub-approved   -> emailSubjectPrefix = "Your expense was"
#      sub-rejected   -> emailSubjectPrefix = "Your expense was"
#      sub-escalated  -> emailSubjectPrefix = "Your expense was auto-approved (escalated):"
```

## Required Function App settings

```
APPROVAL_CALLBACK_BASE_URL   = https://<funcapp>.azurewebsites.net
APPROVAL_CALLBACK_FUNCTION_KEY = <host key of the function app>   (optional, if callback is FUNCTION-level auth)
SENDGRID_API_KEY             = <optional; falls back to log-only email>
EMAIL_FROM                   = noreply@<your-domain>
AUTO_APPROVE_THRESHOLD       = 100
```

## Screenshot checklist for the report

- [ ] `rg-expense-approval` resources overview
- [ ] Service Bus `expense-requests` queue with messages
- [ ] Service Bus `expense-outcomes` topic and all 3 subscriptions
- [ ] Subscription filter rules (`outcome = '...'`)
- [ ] Logic App run history: each of the 6 test scenarios
- [ ] Logic App run detail showing the HTTP Webhook `Wait_for_manager_decision` in each branch (succeeded, timed-out)
- [ ] Email received for auto-approve, approve, reject, escalated cases
- [ ] Subscription incoming message counts (proving filters routed correctly)
