// Service Bus namespace + queue + topic with filtered subscriptions
// for the Expense Approval pipeline (Version B).
//
// Deploy with:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file servicebus.bicep \
//     --parameters namespaceName=<sb-ns>
//
// Outputs the three subscription resource IDs so downstream notifier
// Logic Apps can bind their triggers.

@description('Service Bus namespace name (globally unique).')
param namespaceName string

@description('SKU tier. Standard is required for topics/subscriptions.')
@allowed(['Standard', 'Premium'])
param skuName string = 'Standard'

@description('Azure region.')
param location string = resourceGroup().location

var queueName = 'expense-requests'
var topicName = 'expense-outcomes'

resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name:     namespaceName
  location: location
  sku:      { name: skuName, tier: skuName }
}

resource expenseRequests 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name:   queueName
  properties: {
    lockDuration:                     'PT5M'
    maxDeliveryCount:                 10
    defaultMessageTimeToLive:         'P14D'
    deadLetteringOnMessageExpiration: true
    requiresDuplicateDetection:       false
  }
}

resource outcomesTopic 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  parent: sbNamespace
  name:   topicName
  properties: {
    defaultMessageTimeToLive:     'P14D'
    enableBatchedOperations:      true
    supportOrdering:              false
  }
}

var subscriptions = [
  { name: 'sub-approved',  filter: 'outcome = \'approved\''  }
  { name: 'sub-rejected',  filter: 'outcome = \'rejected\''  }
  { name: 'sub-escalated', filter: 'outcome = \'escalated\'' }
]

resource topicSubs 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = [for sub in subscriptions: {
  parent: outcomesTopic
  name:   sub.name
  properties: {
    maxDeliveryCount:                 10
    lockDuration:                     'PT5M'
    deadLetteringOnMessageExpiration: true
  }
}]

resource subRules 'Microsoft.ServiceBus/namespaces/topics/subscriptions/rules@2022-10-01-preview' = [for (sub, i) in subscriptions: {
  parent: topicSubs[i]
  name:   'filter-outcome'
  properties: {
    filterType: 'SqlFilter'
    sqlFilter:  { sqlExpression: sub.filter }
  }
}]

output namespaceId string   = sbNamespace.id
output queueName    string  = queueName
output topicName    string  = topicName
output subscriptionNames array = [for sub in subscriptions: sub.name]
