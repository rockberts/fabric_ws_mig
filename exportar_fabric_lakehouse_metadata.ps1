<#
.SYNOPSIS
Exporta la definición pública, inventario, columnas y DDL Spark/Delta
de un Lakehouse de Microsoft Fabric.

.EXAMPLE
.\exportar_fabric_lakehouse_metadata.ps1 `
    -WorkspaceId "<WORKSPACE_ID>" `
    -LakehouseId "<LAKEHOUSE_ID>" `
    -OutputDirectory "<OUTPUT_DIRECTORY>"

.EXAMPLE
.\exportar_fabric_lakehouse_metadata.ps1 `
    -WorkspaceId "<WORKSPACE_ID>" `
    -LakehouseId "<LAKEHOUSE_ID>" `
    -OutputDirectory "<OUTPUT_DIRECTORY>" `
    -SubscriptionId "<SUBSCRIPTION_ID>" `
    -SqlEndpoint "<SQL_ENDPOINT>" `
    -SqlDatabase "<SQL_DATABASE>" `
    -ZipPath "<ZIP_PATH>" `
    -Force

.DESCRIPTION
La definición pública del Lakehouse contiene configuración, shortcuts, roles
y ALM, pero no contiene el esquema de columnas de las tablas administradas.

El script siempre exporta:
- Información del item Lakehouse.
- Definición pública y parts Base64 decodificados.
- Inventario paginado de tablas administradas y externas.
- Una consulta INFORMATION_SCHEMA lista para ejecutar.

El script autodetecta SqlEndpoint y SqlDatabase desde el Lakehouse. También
pueden proporcionarse explícitamente para sobrescribir los valores detectados.
Si Invoke-Sqlcmd está disponible, consulta INFORMATION_SCHEMA y genera:
- columns.csv y columns.json.
- ddl\spark\<schema>.<table>.sql.
- ddl\spark\all-tables.sql.

El DDL reconstruye tablas Delta vacías. La API no exporta filas ni sentencias
INSERT/MERGE; para copiar datos se requiere OneLake, Spark o un pipeline.
#>
[CmdletBinding()]
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
    [string]$LakehouseId,

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
    [string]$SqlEndpoint,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SqlDatabase,

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

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 100
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $json, $utf8WithoutBom)
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
        $details = $operation.error | ConvertTo-Json -Depth 20 -Compress
        throw "La operación $OperationId terminó con estado $($operation.status): $details"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI no está instalado o no se encuentra en PATH."
}

Write-Step "Validando autenticación de Azure CLI"
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "No existe una sesión activa. Ejecuta 'az login' y vuelve a intentarlo."
}

if ($SubscriptionId) {
    Write-Step "Seleccionando la suscripción indicada"
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible seleccionar la suscripción $SubscriptionId."
    }
}

Write-Step "Preparando directorio de salida"
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $resolvedOutput) {
    $existingItems = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existingItems.Count -gt 0 -and -not $Force) {
        throw "El directorio no está vacío. Usa -Force o selecciona otro: $resolvedOutput"
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
    throw "El ZIP ya existe. Usa -Force o selecciona otro destino: $resolvedZip"
}

Write-Step "Obteniendo token para Microsoft Fabric"
$fabricToken = az account get-access-token `
    --resource $fabricResource `
    --query accessToken `
    --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fabricToken)) {
    throw "No fue posible obtener un token para Microsoft Fabric."
}

$headers = @{
    Authorization = "Bearer $fabricToken"
    "Content-Type" = "application/json"
}

Write-Step "Exportando información del Lakehouse"
$lakehouse = Invoke-RestMethod `
    -Method Get `
    -Uri "$fabricApiBase/workspaces/$WorkspaceId/lakehouses/$LakehouseId" `
    -Headers $headers

Write-JsonFile `
    -Value $lakehouse `
    -Path (Join-Path $resolvedOutput "lakehouse-item.json")

if ([string]::IsNullOrWhiteSpace($SqlEndpoint)) {
    $SqlEndpoint = $lakehouse.properties.sqlEndpointProperties.connectionString
}

if ([string]::IsNullOrWhiteSpace($SqlDatabase)) {
    $SqlDatabase = $lakehouse.displayName
}

Write-Step "Solicitando definición pública del Lakehouse"
$definitionUrl = (
    "$fabricApiBase/workspaces/$WorkspaceId/lakehouses/" +
    "$LakehouseId/getDefinition"
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
        throw "Fabric devolvió HTTP 202 sin x-ms-operation-id."
    }

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

Write-JsonFile `
    -Value $definition `
    -Path (Join-Path $resolvedOutput "raw-definition.json")

$definitionDirectory = Join-Path $resolvedOutput "definition"
New-Item -ItemType Directory -Path $definitionDirectory -Force | Out-Null
$definitionPrefix = $definitionDirectory.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
) + [IO.Path]::DirectorySeparatorChar

Write-Step "Decodificando parts de la definición"
foreach ($part in $definition.definition.parts) {
    if ($part.payloadType -ne "InlineBase64") {
        throw "Payload no soportado en '$($part.path)': $($part.payloadType)"
    }

    $relativePath = $part.path.Replace(
        [IO.Path]::AltDirectorySeparatorChar,
        [IO.Path]::DirectorySeparatorChar
    )
    $targetPath = [IO.Path]::GetFullPath(
        (Join-Path $definitionDirectory $relativePath)
    )

    if (-not $targetPath.StartsWith(
        $definitionPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Ruta inválida en la definición: $($part.path)"
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

Write-Step "Obteniendo inventario paginado de tablas"
$tables = @()
$tablesUrl = (
    "$fabricApiBase/workspaces/$WorkspaceId/lakehouses/" +
    "$LakehouseId/tables?maxResults=100"
)

do {
    $tablePage = Invoke-RestMethod `
        -Method Get `
        -Uri $tablesUrl `
        -Headers $headers

    if ($tablePage.data) {
        $tables += $tablePage.data
    }

    $tablesUrl = $tablePage.continuationUri
} while (-not [string]::IsNullOrWhiteSpace($tablesUrl))

Write-JsonFile `
    -Value $tables `
    -Path (Join-Path $resolvedOutput "tables.json")

$tables |
    Select-Object name, type, format, location |
    Export-Csv `
        -Path (Join-Path $resolvedOutput "tables.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$informationSchemaQuery = @'
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME,
    ORDINAL_POSITION,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    NUMERIC_PRECISION,
    NUMERIC_SCALE,
    DATETIME_PRECISION,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;
'@

$informationSchemaPath = Join-Path $resolvedOutput "information-schema.sql"
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
    $informationSchemaPath,
    $informationSchemaQuery,
    $utf8WithoutBom
)

function ConvertTo-SparkIdentifier {
    param([Parameter(Mandatory)][string]$Name)

    return '`' + $Name.Replace('`', '``') + '`'
}

function ConvertTo-SparkDataType {
    param([Parameter(Mandatory)]$Column)

    $dataType = ([string]$Column.DATA_TYPE).ToLowerInvariant()
    switch ($dataType) {
        "bigint" { return "BIGINT" }
        "binary" { return "BINARY" }
        "bit" { return "BOOLEAN" }
        "char" { return "STRING" }
        "date" { return "DATE" }
        "datetime" { return "TIMESTAMP" }
        "datetime2" { return "TIMESTAMP" }
        "datetimeoffset" { return "TIMESTAMP" }
        "decimal" {
            return "DECIMAL($($Column.NUMERIC_PRECISION),$($Column.NUMERIC_SCALE))"
        }
        "float" { return "DOUBLE" }
        "image" { return "BINARY" }
        "int" { return "INT" }
        "money" { return "DECIMAL(19,4)" }
        "nchar" { return "STRING" }
        "ntext" { return "STRING" }
        "numeric" {
            return "DECIMAL($($Column.NUMERIC_PRECISION),$($Column.NUMERIC_SCALE))"
        }
        "nvarchar" { return "STRING" }
        "real" { return "FLOAT" }
        "smalldatetime" { return "TIMESTAMP" }
        "smallint" { return "SMALLINT" }
        "smallmoney" { return "DECIMAL(10,4)" }
        "text" { return "STRING" }
        "time" { return "STRING" }
        "timestamp" { return "BINARY" }
        "tinyint" { return "TINYINT" }
        "uniqueidentifier" { return "STRING" }
        "varbinary" { return "BINARY" }
        "varchar" { return "STRING" }
        "xml" { return "STRING" }
        default {
            throw (
                "Tipo SQL no soportado para DDL Spark: '$dataType' " +
                "en $($Column.TABLE_SCHEMA).$($Column.TABLE_NAME)." +
                "$($Column.COLUMN_NAME)"
            )
        }
    }
}

function Export-SparkDdl {
    param(
        [Parameter(Mandatory)][array]$Columns,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    $ddlDirectory = Join-Path $OutputDirectory "ddl\spark"
    New-Item -ItemType Directory -Path $ddlDirectory -Force | Out-Null
    $allStatements = [Collections.Generic.List[string]]::new()
    $tableGroups = @(
        $Columns |
            Group-Object {
                "$($_.TABLE_SCHEMA)`u{001F}$($_.TABLE_NAME)"
            } |
            Sort-Object Name
    )

    foreach ($tableGroup in $tableGroups) {
        $orderedColumns = @(
            $tableGroup.Group | Sort-Object {[int]$_.ORDINAL_POSITION}
        )
        $firstColumn = $orderedColumns[0]
        $schemaName = [string]$firstColumn.TABLE_SCHEMA
        $tableName = [string]$firstColumn.TABLE_NAME
        $columnLines = foreach ($column in $orderedColumns) {
            $columnName = ConvertTo-SparkIdentifier `
                -Name ([string]$column.COLUMN_NAME)
            $sparkType = ConvertTo-SparkDataType -Column $column
            $nullableSuffix = if ($column.IS_NULLABLE -eq "NO") {
                " NOT NULL"
            }
            else {
                ""
            }

            "    $columnName $sparkType$nullableSuffix"
        }

        $qualifiedName = if ($schemaName -eq "dbo") {
            ConvertTo-SparkIdentifier -Name $tableName
        }
        else {
            (
                (ConvertTo-SparkIdentifier -Name $schemaName) + "." +
                (ConvertTo-SparkIdentifier -Name $tableName)
            )
        }
        $statement = (
            "CREATE TABLE IF NOT EXISTS $qualifiedName (`n" +
            ($columnLines -join ",`n") +
            "`n) USING DELTA;`n"
        )
        $safeFileName = (
            ($schemaName + "." + $tableName) -replace '[<>:"/\\|?*]', '_'
        ) + ".sql"
        [IO.File]::WriteAllText(
            (Join-Path $ddlDirectory $safeFileName),
            $statement,
            $utf8WithoutBom
        )
        $null = $allStatements.Add($statement)
    }

    [IO.File]::WriteAllText(
        (Join-Path $ddlDirectory "all-tables.sql"),
        ($allStatements -join "`n"),
        $utf8WithoutBom
    )

    return $tableGroups.Count
}

$ddlTableCount = 0
if ($SqlEndpoint -and $SqlDatabase) {
    Write-Step "Consultando INFORMATION_SCHEMA en el SQL endpoint"

    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Warning (
            "Invoke-Sqlcmd no está disponible. Instala el módulo SqlServer " +
            "o ejecuta manualmente information-schema.sql."
        )
    }
    else {
        $sqlToken = az account get-access-token `
            --resource https://database.windows.net/ `
            --query accessToken `
            --output tsv

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sqlToken)) {
            throw "No fue posible obtener un token para el SQL endpoint."
        }

        $columns = Invoke-Sqlcmd `
            -ServerInstance $SqlEndpoint `
            -Database $SqlDatabase `
            -AccessToken $sqlToken `
            -Query $informationSchemaQuery `
            -TrustServerCertificate:$false `
            -ErrorAction Stop

        $columns |
            Export-Csv `
                -Path (Join-Path $resolvedOutput "columns.csv") `
                -NoTypeInformation `
                -Encoding UTF8

        Write-JsonFile `
            -Value @($columns) `
            -Path (Join-Path $resolvedOutput "columns.json")

        Write-Step "Generando DDL Spark/Delta por tabla"
        $ddlTableCount = Export-SparkDdl `
            -Columns @($columns) `
            -OutputDirectory $resolvedOutput
    }
}
else {
    Write-Warning (
        "El Lakehouse no expone un SQL analytics endpoint. " +
        "Se exportó information-schema.sql para ejecución manual."
    )
}

$summary = [ordered]@{
    workspaceId = $WorkspaceId
    lakehouseId = $LakehouseId
    displayName = $lakehouse.displayName
    exportedAtUtc = [DateTime]::UtcNow.ToString("o")
    definitionParts = @($definition.definition.parts).Count
    tableCount = $tables.Count
    managedTables = @($tables | Where-Object type -eq "Managed").Count
    externalTables = @($tables | Where-Object type -eq "External").Count
    columnsExported = Test-Path (Join-Path $resolvedOutput "columns.csv")
    ddlTablesExported = $ddlTableCount
    ddlFormat = if ($ddlTableCount -gt 0) { "SparkSqlDelta" } else { $null }
    dataExported = $false
}

Write-JsonFile `
    -Value $summary `
    -Path (Join-Path $resolvedOutput "export-summary.json") `
    -Depth 10

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
Write-Host "Tablas:     $($tables.Count)"
Write-Host "DDL:        $ddlTableCount tablas"

if (-not (Test-Path (Join-Path $resolvedOutput "columns.csv"))) {
    Write-Host (
        "Columnas:   ejecutar information-schema.sql en el SQL endpoint"
    ) -ForegroundColor Yellow
}
