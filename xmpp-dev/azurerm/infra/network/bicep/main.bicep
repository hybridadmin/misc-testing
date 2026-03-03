//https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/loops

param location string = resourceGroup().location
param projectPrefix string

@description('Cidr for the virtual network')
param vnet_cidr string = '10.13.0.0/16'
param vnet_name string = '${projectPrefix}-vnet'

@description('The properties of the public ip addresses')
param ipProperties object = {
  count: 5
  publicIpAddressSku: 'Standard'
  publicIpAddressType: 'Static'
}

var network = split(vnet_cidr, '/')[0]
var subnetPrefix = '${split(network, '.')[0]}.${split(network, '.')[1]}'

var subnets = [
  {
    name: '${vnet_name}-PrivateSubnet1'
    subnetPrefix: '${subnetPrefix}.50.0/24'
  }
  {
    name: '${vnet_name}-PrivateSubnet2'
    subnetPrefix: '${subnetPrefix}.60.0/24'
  }
  {
    name: '${vnet_name}-PrivateSubnet3'
    subnetPrefix: '${subnetPrefix}.70.0/24'
  }
  {
    name: '${vnet_name}-PrivateSubnet4'
    subnetPrefix: '${subnetPrefix}.80.0/24'
    delegations: [
      {
        name: 'Microsoft.DBforPostgreSQL.flexibleServers'
        properties:{
          serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
        }
      }
    ]
  }
  {
    name: 'GatewaySubnet'
    subnetPrefix: '${subnetPrefix}.100.0/24'
  }
]

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2019-11-01' = {
  name: vnet_name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnet_cidr
      ]
    }
    subnets: [for subnet in subnets: {
      name: subnet.name
      properties:{
        addressPrefix: subnet.subnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
        delegations: subnet.name == '${vnet_name}-PrivateSubnet4' ? subnet.delegations : null
      }
    }]
  }
}

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2019-11-01' = [for i in range(0,ipProperties.count): {
  name: '${vnet_name}-static-ip${i+1}'
  location: location
  sku: {
    name: ipProperties.publicIpAddressSku
  }
  properties: {
    publicIPAllocationMethod: ipProperties.publicIpAddressType
  }
  //zones: [
  //  '1'
  //  '2'
  //  '3'
  //]
}]

output vnetName string = virtualNetwork.name
