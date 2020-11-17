################
# SCRIPT HEADER
################

<#
    .SYNOPSIS
        This script can be used for brownfield deployments of the Application Gateway Ingress Controller for Azure Kubernetes Service.

    .DESCRIPTIONv
            Prompts for information needed to idenetify your subscription, resource group, and AKS cluster.
            This script also creates a new Managed Identity.
            This script does not deploy any ingress into your AKS cluster. That will need to be done in addition to this script as you need. 
            To change between running this for an RBAC-enabled AKS cluster or a non-RBAC AKS cluster view lines 59 and 62. You will also need to comment out line 109 if this is non-RBAC.
            This script is a combination of PowerShell, Azure CLI, sed, and Helm syntax. 
        
        ***NOTE***
        It is recommended to run this script from Azure Cloud shell - PowerShell. 
        If you run this locally make sure you have Azure Command Line Interfacre installed.
    
    .PARAMETER azsubscriptionname
        Name of the Azure Subscription you want to use
    .PARAMETER ResourceGroupName
        Name of the Resource Group that contains the AKS Cluster
    .PARAMETER AKSClusterName
        Name of the AKS Cluster
    .PARAMETER MgmtName
        Name of the new Managed Identity that will be deployed

    .EXAMPLE
      azsubscriptionname: Sub1
      ResourceGroupName: AKSRG1
      AKSClusterName: AKS1
      MgmtName: MgmtID1

      ./AGICDeployment.ps1 -verbose
    
    .NOTES
        Name: AGIDeployment.ps1  
        Version:       1.3
        Author:        Microsoft MVP - Steve Buchanan (www.buchatech.com)
        Creation Date: 10-10-2020
        Edits:   
        
        # Trouble Shooting 
         # Show logs for the MIC (AAD Identity Pod Leader)
          # kubectl logs --tail=50 -f mic-56dd8c67dc-f6t4w

         # To list all roles assigned to the managed identity
          # az role assignment list --all --assignee $identityClientId -o table

        10-13-2020: Added code to work with managed identity. 

    .PREREQUISITES
        PowerShell version: 7, Azure CLI
        Modules:         
#>

# Prompt for variables
$azsubscriptionname = Read-Host 'Enter the name of the Azure Subscription you want to use.'
$ResourceGroupName = Read-Host 'Enter the name of the Resource Group that contains the AKS Cluster.'
$AKSClusterName = Read-Host 'Enter the name of the AKS Cluster you want to use.'
$MgmtName = Read-Host 'Enter the name of the new Managed Identity.'

# Set the current Azure subscription
az account set --subscription "$azsubscriptionname"

# Connect to the AKS Cluster 
az aks get-credentials --resource-group $ResourceGroupName --name $AKSClusterName --admin

# Create a managed identity 
az identity create -g $ResourceGroupName -n $MgmtName

# Wait time for ID to be fully created.
Start-Sleep -Seconds 50

# Obtain clientID for the new managed identity
$identityClientId = (az identity show -g $ResourceGroupName -n $MgmtName --query 'clientId' -o tsv)

# Obtain ResourceID for the new managed identity
$identityResourceId = (az identity show -g $ResourceGroupName -n $MgmtName --query 'id' -o tsv)

# Obtain the Subscription ID
$subscriptionId = (az account show --query 'id' -o tsv)

# Get Application Gateway Name
$applicationGatewayName = (az network application-gateway list --resource-group $ResourceGroupName --query '[].name' -o tsv)

# Get the App Gateway ID 
$AppgwID = az network application-gateway list --query "[?name=='$applicationGatewayName']" | jq -r ".[].id"

# Obtain the AKS Node Pool Name
$AKSNodePoolName = (az aks nodepool list --cluster-name $AKSClusterName --resource-group $ResourceGroupName --query '[].name' -o tsv)

# Obtain the AKS Node Pool ID
$AKSNodePoolID = (az aks nodepool show --cluster-name $AKSClusterName --name $AKSNodePoolName --resource-group $ResourceGroupName --query 'id' -o tsv)

# Obtain the AKS Kubelet Identity ObjectId
$kubeletidentityobjectId = (az aks show -g $ResourceGroupName -n $AKSClusterName --query 'identityProfile.kubeletidentity.objectId' -o tsv)

# Obtain ResourceID for the Kubelet Identity
$kubeletidentityResourceID = (az aks show -g $ResourceGroupName -n $AKSClusterName --query 'identityProfile.kubeletidentity.resourceId' -o tsv)

# Obtain ClientID for the Kubelet Identity
$kubeletidentityClientID = (az aks show -g $ResourceGroupName -n $AKSClusterName --query 'identityProfile.kubeletidentity.clientId' -o tsv)

# Obtain the AKS Node Resource Group
$AKSNodeRG = (az aks list --resource-group $ResourceGroupName --subscription H365 --query '[].nodeResourceGroup' -o tsv)

# Give the identity Contributor access to the Application Gateway
az role assignment create --role Contributor --assignee $identityClientId --scope $AppgwID

# Get the Application Gateway resource group ID
$ResourceGroupID = az group list --query "[?name=='$ResourceGroupName']" | jq -r ".[0].id"

# Give the identity Reader access to the Application Gateway resource group
az role assignment create --role Contributor --assignee $identityClientId --scope $ResourceGroupID

# Give the identity Contributor access to the Resource Group
az role assignment create --assignee $identityClientId --role "Contributor" --scope $ResourceGroupID

# Give the identity Contributor access to the AKSNodePool
az role assignment create --assignee $identityClientId --role "Contributor" --scope $AKSNodePoolID

# Assign the Kubelet Identity objectId contributor access to the AKS Node RG
az role assignment create --assignee $kubeletidentityobjectId  --role "Contributor" --scope /subscriptions/$subscriptionId/resourceGroups/$AKSNodeRG

# Assign the Kubelet Identity the Managed Identity Operator role on the new managed identity
az role assignment create --assignee $kubeletidentityobjectId  --role "Managed Identity Operator" --scope $identityResourceId

# Deploy an AAD pod identity in an RBAC-enabled cluster (comment line 62 if not using an RBAC-enabled cluster.)
kubectl create -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml

# Deploy AAD pod identity in non-RBAC cluster (un-comment line 64 if using a non-RBAC cluster.)
# kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment.yaml

# Downloads and renames the sample-helm-config.yaml file to helm-agic-config.yaml.
wget https://raw.githubusercontent.com/Azure/application-gateway-kubernetes-ingress/master/docs/examples/sample-helm-config.yaml -O helm-agic-config.yaml

# Link for reference to content of the sample-helm-config.yaml file
#https://azure.github.io/application-gateway-kubernetes-ingress/examples/sample-helm-config.yaml

# Updates the helm-agic-config.yaml and sets RBAC enabled to true using Sed.
sed -i "" "s|<subscriptionId>|${subscriptionId}|g" helm-agic-config.yaml
sed -i "" "s|<resourceGroupName>|${ResourceGroupName}|g" helm-agic-config.yaml
sed -i "" "s|<applicationGatewayName>|${applicationGatewayName}|g" helm-agic-config.yaml
sed -i "" "s|<identityResourceId>|${identityResourceId}|g" helm-agic-config.yaml
sed -i "" "s|<identityClientId>|${identityClientId}|g" helm-agic-config.yaml
sed -i -e "" "s|enabled: false # true/false|enabled: true # true/false|" helm-agic-config.yaml

# Adds the Application Gateway Ingress Controller helm chart repo and updates the repo on the AKS cluster.
helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

# Installs the Application Gateway Ingress Controller using helm and helm-agic-config.yaml
helm upgrade --install appgw-ingress-azure -f helm-agic-config.yaml application-gateway-kubernetes-ingress/ingress-azure
