
param administratorLogin string = 'moyaadmin'

@secure()
param administratorLoginPassword string
param location string = resourceGroup().location
//param serverName string
param serverEdition string = 'GeneralPurpose'
param skuSizeGB int = 32
param dbInstanceType string = 'Standard_D4ds_v4'
param haMode string = 'ZoneRedundant'
param availabilityZone string = '1'
param version string = '14'
param vnetName string = 'xmpp-vnet'
//param virtualNetworkExternalId string = ''
//param subnetName string = ''
//param privateDnsZoneArmResourceId string = ''

var serverName = 'xmpp-pg01'
var privateDnsZoneName = '${serverName}.private.postgres.database.azure.com'
var subnetName = '${vnetName}-PrivateSubnet2'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2019-11-01' existing = {
  name: vnetName
}

//resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-11-01' existing = {
//  name: subnetName
//}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource networkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: uniqueString(virtualNetwork.id)
  location: 'global'
  properties:{
    virtualNetwork:{
      id: virtualNetwork.id
    }
    registrationEnabled: false
  }
}

resource serverName_resource 'Microsoft.DBforPostgreSQL/flexibleServers@2021-06-01' = {
  name: serverName
  location: location
  sku: {
    name: dbInstanceType
    tier: serverEdition
  }
  properties: {
    version: version
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    network: {
      delegatedSubnetResourceId: resourceId('Microsoft.Network/VirtualNetworks/subnets', vnetName, subnetName) //(empty(subnet.id) ? null : subnet.id)
      privateDnsZoneArmResourceId: resourceId('Microsoft.Network/privateDnsZones', privateDnsZoneName) //(empty(virtualNetwork.id) ? null : privateDnsZone.id)
    }
    highAvailability: {
      mode: haMode
    }
    storage: {
      storageSizeGB: skuSizeGB
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    availabilityZone: availabilityZone
  }
}
