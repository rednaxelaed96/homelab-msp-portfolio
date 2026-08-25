param acrName string

resource idAcrPull 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-acr-pull'
  location: resourceGroup().location
}

resource idPostgresAuth 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-postgres-auth'
  location: resourceGroup().location
}

resource idRedisAuth 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-redis-auth'
  location: resourceGroup().location
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: '2f826ae1-1728-4c63-bbb7-a8a150a5a52d'
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: idAcrPull.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output acrPullIdentityId string = idAcrPull.id
output acrPullIdentityClientId string = idAcrPull.properties.clientId
output postgresAuthIdentityId string = idPostgresAuth.id
output postgresAuthIdentityClientId string = idPostgresAuth.properties.clientId
output redisAuthIdentityId string = idRedisAuth.id
output redisAuthIdentityClientId string = idRedisAuth.properties.clientId
