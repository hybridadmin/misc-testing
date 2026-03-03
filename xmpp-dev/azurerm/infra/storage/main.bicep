param  location string = resourceGroup().location

param storageNamePrefix string = 'storage'
param accountType string = 'Standard_LRS'
param kind string = 'StorageV2'
param accessTier string = 'Hot'
param minimumTlsVersion string = 'TLS1_0'
param supportsHttpsTrafficOnly bool = true
param allowBlobPublicAccess bool = true
param networkAclsBypass string = 'AzureServices'
param networkAclsDefaultAction string = 'Allow'

var storageAccountName = '${storageNamePrefix}${uniqueString(resourceGroup().id)}'

resource storageaccount 'Microsoft.Storage/storageAccounts@2021-02-01' = {
  name: storageAccountName
  location: location
  kind: kind
  sku: {
    name: accountType
  }
  properties:{
    accessTier: accessTier
    minimumTlsVersion: minimumTlsVersion
    allowBlobPublicAccess: allowBlobPublicAccess
    networkAcls:{
      bypass: networkAclsBypass
      defaultAction: networkAclsDefaultAction
    }
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    encryption:{
      services:{
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob:{
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Keyvault'
    }
  }
}

resource storageBlob 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  parent: storageaccount
  name: 'default'
  properties:{
    cors:{
      corsRules: []
    }
    deleteRetentionPolicy:{
      allowPermanentDelete: false
      enabled: false
    }
  }
}

resource storageFileservices 'Microsoft.Storage/storageAccounts/fileServices@2022-09-01' = {
  parent: storageaccount
  name: 'default'
  properties:{
    protocolSettings:{
      smb: {}
    }
    cors:{
      corsRules: []
    }
    shareDeleteRetentionPolicy:{
      enabled: true
      days: 7
    }
  }
}
