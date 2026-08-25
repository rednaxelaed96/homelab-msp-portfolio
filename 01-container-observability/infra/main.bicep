targetScope = 'subscription'

param resourceGroupName string = 'rg-homelab-msp'
param location string = 'eastus'
param acrName string = 'acrhomelabakd'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module foundation 'modules/foundation.bicep' = {
  name: 'foundation-deployment'
  scope: rg
  params: {
    location: location
    acrName: acrName
  }
}

module identities 'modules/identities.bicep' = {
  name: 'identities-deployment'
  scope: rg
  params: {
    acrName: acrName
  }
}

module containerapps 'modules/containerapps-env.bicep' = {
  name: 'containerapps-deployment'
  scope: rg
  params: {
    subnetId: foundation.outputs.subnetId
  }
}

output acrPullIdentityClientId string = identities.outputs.acrPullIdentityClientId
output postgresAuthIdentityClientId string = identities.outputs.postgresAuthIdentityClientId
output redisAuthIdentityClientId string = identities.outputs.redisAuthIdentityClientId
output containerAppsEnvironmentId string = containerapps.outputs.environmentId
output logAnalyticsWorkspaceId string = containerapps.outputs.logAnalyticsWorkspaceId
