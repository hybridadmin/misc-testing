
param location string = resourceGroup().location
param enableAcceleratedNetworking bool = true
//param publicIpAddressType string = 'Static'
//param publicIpAddressSku string = 'Standard'
param vmList array = [
  {
    name: 'postgres-01'
    size: 'Standard_A2_v2'
  },{
    name: 'postgres-02'
    size: 'Standard_A2_v2'
  },{
    name: 'haproxy-01'
    size: 'Standard_A2_v2'
  },{
    name: 'ejabberd-01'
    size: 'Standard_A2_v2'
  },{
    name: 'ejabberd-02'
    size: 'Standard_A2_v2'
  }
]

@description('Security Type of the Virtual Machine.')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param securityType string = 'TrustedLaunch'

param osDiskType string = 'StandardSSD_LRS'
param adminUsername string = 'moyaadmin'
@secure()
param adminPublicKey string
//@secure()
//param customData string
//param userData string

param vnetName string = 'xmpp-vnet'

var securityProfileJson = {
  uefiSettings: {
    secureBootEnabled: true
    vTpmEnabled: true
  }
  securityType: securityType
}

var maaTenantName = 'GuestAttestation'
var maaEndpoint = substring('emptystring', 0, 0)

var image = {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-minimal-jammy'
  sku: 'minimal-22_04-lts-gen2'
  version: 'latest'
}

var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${adminUsername}/.ssh/authorized_keys'
        keyData: adminPublicKey
      }
    ]
  }
}

// https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-bicep?toc=%2Fazure%2Fazure-resource-manager%2Fbicep%2Ftoc.json&tabs=CLI
// https://github.com/Azure/bicep/discussions/4953
// https://github.com/Azure/bicep/discussions/5326 - loop index

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2019-11-01' existing = [for (vm, i) in vmList: {
  name: '${vnetName}-StaticIp${i+1}'
}]

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-11-01' existing = {
  name: '${vnetName}-PrivateSubnet1'
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2019-11-01' = [for (vm, i) in vmList: {
  name: '${vm.name}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'SSH'
        properties: {
          description: 'Allow SSH In access'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
    ]
  }
}]

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-11-01' = [for (vm, i) in vmList: {
  name: vm.name
  //dependsOn: [
  //  publicIPAddress
  //  networkSecurityGroup
  //]
  location: location
  properties: {
    ipConfigurations: [
      {
        name: '${vm.name}-ipConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnet.id
          }
          publicIPAddress: publicIPAddress[i]
        }
      }
    ]
    enableAcceleratedNetworking: enableAcceleratedNetworking
    networkSecurityGroup:{
      id: networkSecurityGroup[i].id
    }
  }
}]

resource virtualMachine 'Microsoft.Compute/virtualMachines@2020-12-01' = [for (vm, i) in vmList: {
  name: vm.name
  //dependsOn:[
  //  networkInterface
  //]
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vm.size
    }
    osProfile: {
      computerName: vm.name
      adminUsername: adminUsername
      adminPassword: adminPublicKey
      linuxConfiguration: linuxConfiguration
    }
    storageProfile: {
      imageReference: image
      osDisk: {
        //name: '${vm.name}-osDisk'
        //caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk:{
          storageAccountType: osDiskType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface[i].id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        //storageUri: 'storageUri'
      }
    }
    securityProfile: ((securityType == 'TrustedLaunch') ? securityProfileJson : null)
  }
}]

resource linuxGuestConfigExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = [for (vm, i) in vmList: {
  parent: virtualMachine[i]
  name: 'SecureBootConfig'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security.LinuxAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: maaEndpoint
          maaTenantName: maaTenantName
        }
      }
    }
    protectedSettings: {}
  }
}]

resource linuxVMExtensions 'Microsoft.Compute/virtualMachines/extensions@2022-03-01' = [for (vm, i) in vmList: {
  parent: virtualMachine[i]
  name: 'ConfigScript'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      //fileUris: [
      //  'fileUris'
      //]
    }
    protectedSettings: {
      //commandToExecute: 'sh customScript.sh'
    }
  }
}]
