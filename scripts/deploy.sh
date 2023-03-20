location="australiaeast"
resourceGroup="aspnet-todo-rg"
dnsResourceGroup="external-dns-zones-rg"
randomIdentifier=`echo $resourceGroup | md5sum | cut -d ' ' -f 1 | cut -b-10`
tag="serverless-sql-cosmosdb"
account="aspnetcore-todo-cosmos-$randomIdentifier"
database="aspnetcore-todo-cosmos-$randomIdentifier"
registry="aspnetcoretodoacr$randomIdentifier"
umid="aspnetcore-todo-umid-$randomIdentifier"
asp="aspnetcore-todo-asp-$randomIdentifier"
app="aspnetcore-todo-app-$randomIdentifier"
load="aspnetcore-todo-loadtest-$randomIdentifier"
vnet="aspnetcore-todo-vnet-$randomIdentifier"
pip="aspnetcore-todo-pip-$randomIdentifier"
appgwy="aspnetcore-todo-appgwy-$randomIdentifier"
dns="aspnetcore-todo-$randomIdentifier"
tag='aspnetcore-todo:v0.1.0'
container="todos"
partitionKey="/id"
zone='kainiindustries.net'
host='todoapp'
certPath='../certs/star.kainiindustries.net.pfx'
certName='kainiindustries-tls-cert'

source ./.env

# Create a resource group
echo "Creating $resourceGroup in $location..."
az group create --name $resourceGroup --location "$location" --tags $tag

# create vnet
az network vnet create --resource-group $resourceGroup -n $vnet --address-prefix 10.0.0.0/16 --subnet-name ApplicationGatewaySubnet --subnet-prefixes 10.0.0.0/24
az network vnet subnet create --resource-group $resourceGroup --vnet-name $vnet -n AspVnetIntegrationSubnet --address-prefixes 10.0.1.0/24

# create Azure load test
az load create \
--name $load \
--resource-group $resourceGroup \
--location $location

# Create a Cosmos account for SQL API
az cosmosdb create --name $account \
--resource-group $resourceGroup \
--default-consistency-level Eventual \
--locations regionName="$location" failoverPriority=0 isZoneRedundant=False \
--capabilities EnableServerless

# Create a SQL API database
echo "Creating $database"
az cosmosdb sql database create --account-name $account --resource-group $resourceGroup --name $database

# Create a SQL API container
echo "Creating $container with $partitionKey"
az cosmosdb sql container create --account-name $account --resource-group $resourceGroup --database-name $database --name $container --partition-key-path $partitionKey

cosmosDbKey=`az cosmosdb keys list --name $account --resource-group $resourceGroup --query primaryMasterKey -o tsv`

# create ACR
az acr create --name $registry --resource-group $resourceGroup --sku Basic --admin-enabled true

# Create user managed Identity & assign 'acrPull' role
az identity create --name $umid --resource-group $resourceGroup

sleep -s 30

principalId=$(az identity show --resource-group $resourceGroup --name $umid --query principalId --output tsv)
registryId=$(az acr show --resource-group $resourceGroup --name $registry --query id --output tsv)
az role assignment create --assignee $principalId --scope $registryId --role "AcrPull"

# Build container
az acr build -r "$registry.azurecr.io" -t $tag -f ../Dockerfile .

# Create App Service plan 
az appservice plan create --name $asp --resource-group $resourceGroup --is-linux --sku S1 # P1V3

# Create web app & pull container image
az webapp create \
--resource-group $resourceGroup \
--plan $asp \--name $app \
--deployment-container-image-name "$registry.azurecr.io/$tag"

# update application settings
az webapp config appsettings set \
--resource-group $resourceGroup \
--name $app \
--settings CosmosDb.DatabaseName=$database CosmodDb.Key=$cosmosDbKey CosmosDb.ContainerName=$container CosmosDb.Account=$account

# Create PIP
az network public-ip create --name $pip --resource-group $resourceGroup --sku Standard --dns-name $dns
publicIpAddress=`az network public-ip show --resource-group $resourceGroup --name $pip --query ipAddress -o tsv`

# Create App Gateway
az network application-gateway create \
--name $appgwy \
--resource-group $resourceGroup \
--vnet-name $vnet \
--subnet ApplicationGatewaySubnet \
--min-capacity 0 \
--http-settings-port 443 \
--max-capacity 2 \
--public-ip-address $pip \
--private-ip-address 10.0.0.4 \
--http-settings-protocol Https \
--servers $app.azurewebsites.net \
--priority 1000 \
--ssl-certificate-name $certName \
--cert-file $certPath \
--cert-password $certPassword \
--frontend-port 443 \
--sku Standard_v2

# Create health probe
az network application-gateway probe create \
--resource-group $resourceGroup \
--gateway-name $appgwy \
--name probe-01 \
--protocol https \
--host $app.azurewebsites.net \
--path /

# Update Http Settings
az network application-gateway http-settings update \
--resource-group $resourceGroup \
--gateway-name $appgwy \
--name appGatewayBackendHttpSettings \
--probe probe-01 \
--host-name-from-backend-pool true

# create A record mapped to App Gateway Public IP
az network dns record-set a add-record -g $dnsResourceGroup --zone $zone --record-set-name $host -a $publicIpAddress
