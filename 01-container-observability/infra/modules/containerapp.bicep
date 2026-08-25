param environmentId string
param acrLoginServer string
param acrPullIdentityId string
param postgresAuthIdentityId string
param redisAuthIdentityId string
param postgresAuthIdentityClientId string
param redisAuthIdentityClientId string
param dbHost string
param redisHost string
@secure()
param appInsightsConnectionString string
param labApiImageTag string = 'v13'
param pgbouncerImageTag string = 'v5'

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'lab-api'
  location: resourceGroup().location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentityId}': {}
      '${postgresAuthIdentityId}': {}
      '${redisAuthIdentityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Multiple'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acrLoginServer
          identity: acrPullIdentityId
        }
      ]
      secrets: [
        {
          name: 'appinsights-connection-string'
          value: appInsightsConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'lab-api'
          image: '${acrLoginServer}/lab-api:${labApiImageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'DB_HOST', value: dbHost }
            { name: 'DB_NAME', value: 'postgres' }
            { name: 'DB_USER', value: 'id-postgres-auth' }
            { name: 'PG_IDENTITY_CLIENT_ID', value: postgresAuthIdentityClientId }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'REDIS_IDENTITY_CLIENT_ID', value: redisAuthIdentityClientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
          ]
        }
        {
          name: 'pgbouncer'
          image: '${acrLoginServer}/pgbouncer-sidecar:${pgbouncerImageTag}'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'PG_IDENTITY_CLIENT_ID', value: postgresAuthIdentityClientId }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
