targetScope = 'subscription'

param resourceGroupName string = 'rg-homelab-msp'
param location string = 'eastus'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module foundation 'modules/foundation.bicep' = {
  name: 'foundation-deployment'
  scope: rg
  params: {
    location: location
  }
}
