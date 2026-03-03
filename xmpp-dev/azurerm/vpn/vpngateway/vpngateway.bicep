param location string = resourceGroup().location
param projectPrefix string = 'Azure'
param vnetName string = 'xmpp-vnet'

var pubIpAddressCount = 1
var vpnGatewayName = '${projectPrefix}-VPN-Gateway'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2019-11-01' existing = {
  name: vnetName
}

resource vpnGatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2022-11-01' existing = {
  parent: virtualNetwork
  name: 'GatewaySubnet'
}

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2019-11-01' = [ for ipIndex in range(1, pubIpAddressCount): {
  name: toLower('${projectPrefix}-vpngateway-ip${ipIndex}')
  location: location
  properties: {
    publicIPAllocationMethod: 'Dynamic'
    dnsSettings: {
      domainNameLabel: toLower('${projectPrefix}-vpngateway-ip${ipIndex}')
      fqdn: toLower('${projectPrefix}-vpngateway-ip${ipIndex}.${location}.cloudapp.azure.com')
    }
  }
}]

resource virtualNetworkGateway 'Microsoft.Network/virtualNetworkGateways@2020-11-01' = {
  name: vpnGatewayName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'IpConfigPrimary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vpnGatewaySubnet.id
          }
          publicIPAddress: {
            id: publicIPAddress[0].id
          }
        }
      }
//      {
//        name: 'IpConfigSecondary'
//        properties: {
//          privateIPAllocationMethod: 'Dynamic'
//          subnet: {
//            id: vpnGatewaySubnet.id
//          }
//          publicIPAddress: {
//            id: publicIPAddress[1].id
//          }
//        }
//      }
    ]
    sku: {
      name: 'VpnGw2'
      tier: 'VpnGw2'
    }
    vpnGatewayGeneration: 'Generation2'
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    enableBgp: false
    activeActive: false
  }
}
