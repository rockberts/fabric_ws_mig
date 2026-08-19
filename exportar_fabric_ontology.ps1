[CmdletBinding()]
<#
.SYNOPSIS
Exporta y decodifica la definición de una Ontology de Microsoft Fabric.

.EXAMPLE
.\exportar_fabric_ontology.ps1 `
    -WorkspaceId "<WORKSPACE_ID>" `
    -OntologyId "<ONTOLOGY_ID>" `
    -OutputDirectory "<OUTPUT_DIRECTORY>"

.EXAMPLE
.\exportar_fabric_ontology.ps1 `
    -WorkspaceId "<WORKSPACE_ID>" `
    -OntologyId "<ONTOLOGY_ID>" `
    -OutputDirectory "<OUTPUT_DIRECTORY>" `
    -SubscriptionId "<SUBSCRIPTION_ID>" `
    -ZipPath "<ZIP_PATH>" `
    -Force
#>
param(
    [Parameter(Mandatory)]
    [ValidatePattern(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )]
    [string]$WorkspaceId,

    [Parameter(Mandatory)]
    [ValidatePattern(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )]
    [string]$OntologyId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidatePattern(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ZipPath,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int]$PollingIntervalSeconds = 5,

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$fabricResource = "https://api.fabric.microsoft.com"
$fabricApiBase = "$fabricResource/v1"

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-HeaderValue {
    param(
        [Parameter(Mandatory)]$Headers,
        [Parameter(Mandatory)][string]$Name
    )

    $value = $Headers[$Name]
    if ($value -is [array]) {
        return $value[0]
    }

    return $value
}

function Wait-FabricOperation {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    do {
        Start-Sleep -Seconds $PollingIntervalSeconds

        $operation = Invoke-RestMethod `
            -Method Get `
            -Uri "$fabricApiBase/operations/$OperationId" `
            -Headers $Headers

        Write-Host "Estado de la operación: $($operation.status)"
    } while ($operation.status -notin @("Succeeded", "Failed", "Cancelled"))

    if ($operation.status -ne "Succeeded") {
        $errorDetails = $operation.error | ConvertTo-Json -Depth 20 -Compress
        throw "La operación $OperationId terminó con estado $($operation.status): $errorDetails"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI no está instalado o no se encuentra en PATH."
}

Write-Step "Validando autenticación de Azure CLI"
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "No existe una sesión activa de Azure CLI. Ejecuta 'az login' y vuelve a intentarlo."
}

if ($SubscriptionId) {
    Write-Step "Seleccionando la suscripción indicada"
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible seleccionar la suscripción $SubscriptionId."
    }
}

Write-Step "Obteniendo token para Microsoft Fabric"
$token = az account get-access-token `
    --resource $fabricResource `
    --query accessToken `
    --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "No fue posible obtener un token para Microsoft Fabric."
}

$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $resolvedOutput) {
    $existingItems = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existingItems.Count -gt 0 -and -not $Force) {
        throw "El directorio de salida no está vacío. Usa -Force o selecciona otro directorio: $resolvedOutput"
    }
}
else {
    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = "$resolvedOutput.zip"
}

$resolvedZip = [IO.Path]::GetFullPath($ZipPath)
if ((Test-Path -LiteralPath $resolvedZip) -and -not $Force) {
    throw "El archivo ZIP ya existe. Usa -Force o selecciona otro destino: $resolvedZip"
}

Write-Step "Solicitando la definición de la Ontology"
$definitionUrl = (
    "$fabricApiBase/workspaces/$WorkspaceId/ontologies/" +
    "$OntologyId/getDefinition"
)

$response = Invoke-WebRequest `
    -Method Post `
    -Uri $definitionUrl `
    -Headers $headers

if ($response.StatusCode -eq 202) {
    $operationId = Get-HeaderValue `
        -Headers $response.Headers `
        -Name "x-ms-operation-id"

    if ([string]::IsNullOrWhiteSpace($operationId)) {
        throw "Fabric devolvió HTTP 202 sin el encabezado x-ms-operation-id."
    }

    Write-Step "Esperando la operación asíncrona $operationId"
    Wait-FabricOperation -OperationId $operationId -Headers $headers

    $definition = Invoke-RestMethod `
        -Method Get `
        -Uri "$fabricApiBase/operations/$operationId/result" `
        -Headers $headers
}
elseif ($response.StatusCode -eq 200) {
    $definition = $response.Content | ConvertFrom-Json
}
else {
    throw "Fabric devolvió un estado inesperado: HTTP $($response.StatusCode)."
}

if (-not $definition.definition.parts) {
    throw "La respuesta no contiene definition.parts."
}

Write-Step "Guardando la respuesta original"
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
$rawDefinitionPath = Join-Path $resolvedOutput "raw-definition.json"
$rawDefinitionJson = $definition | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText(
    $rawDefinitionPath,
    $rawDefinitionJson,
    $utf8WithoutBom
)

Write-Step "Decodificando los archivos de la definición"
$outputPrefix = $resolvedOutput.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
) + [IO.Path]::DirectorySeparatorChar

foreach ($part in $definition.definition.parts) {
    if ([string]::IsNullOrWhiteSpace($part.path)) {
        throw "Se encontró una parte sin path."
    }

    if ($part.payloadType -ne "InlineBase64") {
        throw "Payload no soportado en '$($part.path)': $($part.payloadType)"
    }

    $relativePath = $part.path.Replace(
        [IO.Path]::AltDirectorySeparatorChar,
        [IO.Path]::DirectorySeparatorChar
    )
    $targetPath = [IO.Path]::GetFullPath(
        (Join-Path $resolvedOutput $relativePath)
    )

    if (-not $targetPath.StartsWith(
        $outputPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "La ruta de la parte sale del directorio permitido: $($part.path)"
    }

    $targetFolder = Split-Path -Path $targetPath -Parent
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null

    try {
        $decodedPayload = [Convert]::FromBase64String($part.payload)
    }
    catch {
        throw "El payload de '$($part.path)' no contiene Base64 válido."
    }

    [IO.File]::WriteAllBytes($targetPath, $decodedPayload)
    Write-Host "Exportado: $($part.path)"
}

Write-Step "Generando archivo ZIP"
if (Test-Path -LiteralPath $resolvedZip) {
    Remove-Item -LiteralPath $resolvedZip -Force
}

Compress-Archive `
    -Path (Join-Path $resolvedOutput "*") `
    -DestinationPath $resolvedZip `
    -Force

Write-Host "`nExportación completada." -ForegroundColor Green
Write-Host "Directorio: $resolvedOutput"
Write-Host "ZIP:        $resolvedZip"
