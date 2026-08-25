targetScope = 'resourceGroup'

param acrName string = 'acrhomelabakd'
param dbHost string
param redisHost string
@secure()
param appInsightsConnectionString string
param labApiImageTag string = 'v13'
param pgbouncerImageTag string = 'v5'

module foundation 'modules/foundation.bicep' = {
  name: 'foundation-deployment'
  params: {
    location: resourceGroup().location
    acrName: acrName
  }
}

module identities 'modules/identities.bicep' = {
  name: 'identities-deployment'
  params: {
    acrName: acrName
  }
}

module containerapps 'modules/containerapps-env.bicep' = {
  name: 'containerapps-env-deployment'
  params: {
    subnetId: foundation.outputs.subnetId
  }
}

module containerapp 'modules/containerapp.bicep' = {
  name: 'containerapp-deployment'
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

output containerAppFqdn string = containerapp.outputs.containerAppFqdn
