# VPN Deploy

## VPN Gateway

```bash
resourceGroup="dev"
az deployment group create --resource-group $resourceGroup --template-file vpngateway.bicep
```

## Local Network Gateway

```bash
resourceGroup="dev"
az deployment group create --resource-group $resourceGroup --template-file localnetworkgateway.bicep \
        --parameters projectPrefix="xmpp" vpnGatewayName="Azure-VPN-Gateway"
```
