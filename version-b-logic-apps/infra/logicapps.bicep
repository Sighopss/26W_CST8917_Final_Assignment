// Deploys:
//   - Microsoft.Web/connections for Service Bus (shared-access-key auth)
//   - Main Logic App consuming the expense-requests queue
//   - Three notifier Logic Apps, one per outcomes topic subscription
//
// Requires the Service Bus namespace + queue + topic + subscriptions from
// servicebus.bicep, and an Azure Function App with the validate-expense,
// request-approval, approval-callback, and send-notification endpoints.

@description('Azure region.')
param location string = resourceGroup().location

@description('Service Bus primary connection string (e.g. RootManageSharedAccessKey).')
@secure()
param serviceBusConnectionString string

@description('Full URL incl. ?code=... for the validate-expense Azure Function.')
@secure()
param validateFunctionUrl string

@description('Full URL incl. ?code=... for the request-approval Azure Function.')
@secure()
param requestApprovalUrl string

@description('Full URL incl. ?code=... for the send-notification Azure Function.')
@secure()
param sendNotificationUrl string

@description('Timeout for manager approval (ISO 8601 duration, e.g. PT10M).')
param approvalTimeout string = 'PT10M'

var topicName = 'expense-outcomes'
var subscriptions = [
  { name: 'sub-approved',  workflow: 'logic-cst8917-notify-approved'  }
  { name: 'sub-rejected',  workflow: 'logic-cst8917-notify-rejected'  }
  { name: 'sub-escalated', workflow: 'logic-cst8917-notify-escalated' }
]

var serviceBusApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'servicebus')

resource sbConnection 'Microsoft.Web/connections@2016-06-01' = {
  name:     'servicebus-conn'
  location: location
  properties: {
    displayName: 'Service Bus (cst8917 final)'
    api:         { id: serviceBusApiId }
    parameterValues: {
      connectionString: serviceBusConnectionString
    }
  }
}

resource mainWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name:     'logic-cst8917-main'
  location: location
  properties: {
    state:      'Enabled'
    definition: loadJsonContent('workflow.json')
    parameters: {
      '$connections': {
        value: {
          servicebus: {
            connectionId:   sbConnection.id
            connectionName: sbConnection.name
            id:             serviceBusApiId
          }
        }
      }
      validateFunctionUrl: { value: validateFunctionUrl  }
      requestApprovalUrl:  { value: requestApprovalUrl   }
      approvalTimeout:     { value: approvalTimeout      }
      outcomesTopic:       { value: topicName            }
    }
  }
}

resource notifiers 'Microsoft.Logic/workflows@2019-05-01' = [for sub in subscriptions: {
  name:     sub.workflow
  location: location
  properties: {
    state:      'Enabled'
    definition: loadJsonContent('notifier-workflow.json')
    parameters: {
      '$connections': {
        value: {
          servicebus: {
            connectionId:   sbConnection.id
            connectionName: sbConnection.name
            id:             serviceBusApiId
          }
        }
      }
      topicName:        { value: topicName           }
      subscriptionName: { value: sub.name            }
      notificationUrl:  { value: sendNotificationUrl }
    }
  }
}]

output mainWorkflowId string   = mainWorkflow.id
output sbConnectionId string   = sbConnection.id
output notifierIds    array    = [for (s, i) in subscriptions: notifiers[i].id]
