# scripts/New-BootstrapBackend.ps1

param(
    [Parameter(Mandatory)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$PrivateEndpointSubnetId,

    [Parameter(Mandatory)]
    [string]$PrivateDnsZoneId,

    [Parameter(Mandatory)]
    [string]$PlatformPlanPrincipalId,

    [Parameter(Mandatory)]
    [string]$PlatformApplyPrincipalId
)

$ErrorActionPreference = "Stop"

Set-AzContext -SubscriptionId $ManagementSubscriptionId

# ----------------------------------------------------------
# Resource Group
# ----------------------------------------------------------

$rg = Get-AzResourceGroup `
    -Name $ResourceGroupName `
    -ErrorAction SilentlyContinue

if (-not $rg) {
    $rg = New-AzResourceGroup `
        -Name $ResourceGroupName `
        -Location $Location
}

# ----------------------------------------------------------
# Private Storage Account
# ----------------------------------------------------------

$storage = Get-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -ErrorAction SilentlyContinue

if (-not $storage) {

    $storage = New-AzStorageAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -Location $Location `
        -SkuName Standard_GRS `
        -Kind StorageV2 `
        -MinimumTlsVersion TLS1_2 `
        -AllowBlobPublicAccess $false `
        -AllowSharedKeyAccess $false `
        -PublicNetworkAccess Disabled
}

Set-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -SkuName Standard_GRS `
    -AllowSharedKeyAccess $false

# ==========================================================
# Enable Container Soft Delete
# ==========================================================

Write-Host "Enabling container soft delete..."

Enable-AzStorageContainerDeleteRetentionPolicy `
    -ResourceGroupName $ResourceGroupName `
    -StorageAccountName $StorageAccountName `
    -RetentionDays 7


# ----------------------------------------------------------
# Blob container
#
# Deliberately created through ARM rather than the Blob
# data plane because our laptop cannot reach the PE.
# ----------------------------------------------------------

$containerResourceId =
    "$($storage.Id)/blobServices/default/containers/tfstate"

$existingContainer = Get-AzResource `
    -ResourceId $containerResourceId `
    -ErrorAction SilentlyContinue

if (-not $existingContainer) {

    New-AzResource `
        -ResourceId $containerResourceId `
        -ApiVersion "2023-05-01" `
        -Properties @{
            publicAccess = "None"
        } `
        -Force
}

# ----------------------------------------------------------
# Private Endpoint
# ----------------------------------------------------------

$peName = "pe-$StorageAccountName-blob"

$existingPe = Get-AzPrivateEndpoint `
    -ResourceGroupName $ResourceGroupName `
    -Name $peName `
    -ErrorAction SilentlyContinue

if (-not $existingPe) {

    $subnetResource = Get-AzResource `
        -ResourceId $PrivateEndpointSubnetId

    $subnetParts = $PrivateEndpointSubnetId -split "/"

    $vnetName = $subnetParts[
        [Array]::IndexOf($subnetParts, "virtualNetworks") + 1
    ]

    $subnetName = $subnetParts[
        [Array]::IndexOf($subnetParts, "subnets") + 1
    ]

    $vnetRg = $subnetParts[
        [Array]::IndexOf($subnetParts, "resourceGroups") + 1
    ]

    $vnet = Get-AzVirtualNetwork `
        -ResourceGroupName $vnetRg `
        -Name $vnetName

    $subnet = Get-AzVirtualNetworkSubnetConfig `
        -VirtualNetwork $vnet `
        -Name $subnetName

    $connection = New-AzPrivateLinkServiceConnection `
        -Name "$peName-connection" `
        -PrivateLinkServiceId $storage.Id `
        -GroupId "blob"

    New-AzPrivateEndpoint `
        -Name $peName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -Subnet $subnet `
        -PrivateLinkServiceConnection $connection
}

# ----------------------------------------------------------
# Private DNS Zone Group
# ----------------------------------------------------------

$dnsZoneConfig = New-AzPrivateDnsZoneConfig `
    -Name "blob" `
    -PrivateDnsZoneId $PrivateDnsZoneId

$existingDnsGroup = Get-AzPrivateDnsZoneGroup `
    -ResourceGroupName $ResourceGroupName `
    -PrivateEndpointName $peName `
    -Name "default" `
    -ErrorAction SilentlyContinue

if (-not $existingDnsGroup) {

    New-AzPrivateDnsZoneGroup `
        -ResourceGroupName $ResourceGroupName `
        -PrivateEndpointName $peName `
        -Name "default" `
        -PrivateDnsZoneConfig $dnsZoneConfig
}

# ----------------------------------------------------------
# Bootstrap RBAC
# ----------------------------------------------------------

$roleName = "Storage Blob Data Contributor"

foreach ($principalId in @(
    $PlatformPlanPrincipalId,
    $PlatformApplyPrincipalId
)) {

    $existing = Get-AzRoleAssignment `
        -ObjectId $principalId `
        -Scope $containerResourceId `
        -RoleDefinitionName $roleName `
        -ErrorAction SilentlyContinue

    if (-not $existing) {
        New-AzRoleAssignment `
            -ObjectId $principalId `
            -Scope $containerResourceId `
            -RoleDefinitionName $roleName
    }
}

# ==========================================================
# Apply ARM CanNotDelete Lock
# ==========================================================

$lockName = "lock-$StorageAccountName-delete"

Write-Host "Checking ARM delete lock '$lockName'..."

$existingLock = Get-AzResourceLock `
    -ResourceGroupName $ResourceGroupName `
    -ResourceName $StorageAccountName `
    -ResourceType "Microsoft.Storage/storageAccounts" `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -eq $lockName
    }

if (-not $existingLock) {

    Write-Host "Creating CanNotDelete lock on storage account..."

    New-AzResourceLock `
        -LockName $lockName `
        -LockLevel CanNotDelete `
        -ResourceGroupName $ResourceGroupName `
        -ResourceName $StorageAccountName `
        -ResourceType "Microsoft.Storage/storageAccounts" `
        -Force | Out-Null

    Write-Host "Storage account delete lock created."
}
else {
    Write-Host "Storage account delete lock already exists."
}

Write-Host ""
Write-Host "Application Terraform bootstrap backend is ready."
Write-Host "Storage account : $StorageAccountName"
Write-Host "Container       : tfstate"
Write-Host "State key       : app-bootstrap.tfstate"