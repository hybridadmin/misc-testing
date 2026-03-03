param location string = resourceGroup().location

param projectPrefix string
param vpnGatewayName string // Azure-VPN-Gateway
param localGatewayNamePrefix string = '${projectPrefix}-LocalNetworkGW'

// 10.103.0.0/16 - xmpp cidr
param localNetGatewaySettings array = [
  {
    virtualPrivateGateway: '52.30.31.161'
    remoteNetworkPrefixes: ['10.137.0.0/16','10.103.0.0/16','10.85.0.0/16','10.109.0.0/16']
    preSharedKey: 'xxxxxxxxx'
  }
  {
    virtualPrivateGateway: '54.194.51.239'
    remoteNetworkPrefixes: ['10.137.0.0/16','10.103.0.0/16','10.85.0.0/16','10.109.0.0/16']
    preSharedKey: 'xxxxxxxxxx'
  }
]

resource virtualNetworkGateway 'Microsoft.Network/virtualNetworkGateways@2020-11-01' existing = {
  name: vpnGatewayName
}

resource localNetworkGateways 'Microsoft.Network/localNetworkGateways@2019-11-01' = [for (gatewaySettings, i) in localNetGatewaySettings: {
  name: '${localGatewayNamePrefix}${i+1}'
  location: location
  properties: {
    localNetworkAddressSpace: {
      addressPrefixes: gatewaySettings.remoteNetworkPrefixes

    }
    gatewayIpAddress: gatewaySettings.virtualPrivateGateway
  }
}]

resource vpnVnetConnection 'Microsoft.Network/connections@2020-11-01' = [for (gatewaySettings, i) in localNetGatewaySettings: {
  name: '${projectPrefix}-VpnConnection${i+1}'
  location: location
  properties: {
    virtualNetworkGateway1: {
      id: virtualNetworkGateway.id
      properties:{}
    }
    localNetworkGateway2: {
      id: localNetworkGateways[i].id
      properties:{}
    }
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
    enableBgp: false
    useLocalAzureIpAddress: false
    usePolicyBasedTrafficSelectors: false
    expressRouteGatewayBypass: false
    connectionMode: 'Default'
    routingWeight: 0
    sharedKey: gatewaySettings.preSharedKey
  }
}]
