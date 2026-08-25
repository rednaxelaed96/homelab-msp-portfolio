targetScope = 'subscription'

param resourceGroupName string = 'rg-homelab-msp'
param location string = 'eastus'
param acrName string = 'acrhomelabakd'
param dbHost string
param redisHost string
@secure()
param appInsightsConnectionString string
param labApiImageTag string = 'v13'
param pgbouncerImageTag string = 'v5'

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
  name: 'containerapps-env-deployment'
  scope: rg
  params: {
    subnetId: foundation.outputs.subnetId
  }
}

module containerapp 'modules/containerapp.bicep' = {
  name: 'containerapp-deployment'
  scope: rg
  params: {
    environmentId: containerapps.outputs.environmentId
    acrLoginServer: foundation.outputs.acrLoginServer
    acrPullIdentityId: identities.outputs.acrPullIdentityId
    postgresAuthIdentityId: identities.outputs.postgresAuthIdentityId
    redisAuthIdentityId: identities.outputs.redisAuthIdentityId
    postgresAuthIdentityClientId: identities.outputs.postgresAuthIdentityClientId
    redisAuthIdentityClientId: identities.outputs.redisAuthIdentityClientId
    dbHost: dbHost
    redisHost: redisHost
    appInsightsConnectionString: appInsightsConnectionString
    labApiImageTag: labApiImageTag
    pgbouncerImageTag: pgbouncerImageTag
  }
}

output acrPullIdentityClientId string = identities.outputs.acrPullIdentityClientId
output postgresAuthIdentityClientId string = identities.outputs.postgresAuthIdentityClientId
output redisAuthIdentityClientId string = identities.outputs.redisAuthIdentityClientId
output containerAppsEnvironmentId string = containerapps.outputs.environmentId
output logAnalyticsWorkspaceId string = containerapps.outputs.logAnalyticsWorkspaceId
output containerAppFqdn string = containerapp.outputs.containerAppFqdn
