# AzureRM Templates

Ensure that the resource group to be used for resource creation is set using the variable `AZURE_RG`

## Deploy

### To deploy the infra:

```bash
az deployment group create --resource-group $AZURE_RG --template-file main.bicep
```

### To deploy the stack:

```bash
az deployment group create --resource-group $AZURE_RG --template-file main.bicep \
        --parameters adminPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

### Assign additional secondary IP's to network adapter:

```bash
index=0
for (( i=100; i<=114; i++ )); do
        ((index = index + 2))
        az network nic ip-config create \
          --resource-group dev \
          --name ipconfig${index} \
          --nic-name xmpp-ejabberd-01VMNic \
          --private-ip-address 10.12.1.$i \
          --private-ip-address-version IPv4 \
          --vnet-name xmpp-vnet \
          --subnet xmpp-vnet-subnet1
done
```

