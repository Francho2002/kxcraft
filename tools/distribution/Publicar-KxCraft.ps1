[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$ConfigPath = '',
    [switch]$LibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
else { $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot) }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ProjectRoot 'data\distribution-update-manager.json'
}
else { $ConfigPath = [IO.Path]::GetFullPath($ConfigPath) }
$script:KxRoot = $ProjectRoot
$script:KxConfigPath = $ConfigPath
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-KxPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $script:KxRoot $Path))
}

function Read-KxJson([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Falta el archivo requerido: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-KxJsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = ConvertTo-Json -InputObject $Value -Depth 32
    [IO.File]::WriteAllText($temp, $json + "`n", (New-Object Text.UTF8Encoding($false)))
    $backup = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.bak'
    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temp, $Path, $backup)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        }
        else { [IO.File]::Move($temp, $Path) }
    }
    catch {
        if ((Test-Path -LiteralPath $backup) -and !(Test-Path -LiteralPath $Path)) { [IO.File]::Move($backup, $Path) }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        throw
    }
}

function Get-KxSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-KxTomlString([string]$Text, [string]$Name, [switch]$Optional) {
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*"(?<value>(?:[^"\\]|\\.)*)"\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (!$match.Success) {
        if ($Optional) { return $null }
        throw "No se encontró el campo TOML '$Name'."
    }
    $value = $match.Groups['value'].Value
    return $value.Replace('\"', '"').Replace('\\', '\').Replace('\n', [string][char]10).Replace('\r', [string][char]13).Replace('\t', [string][char]9)
}

function ConvertTo-KxTomlString([string]$Value) {
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') + '"'
}

function Get-KxTomlBlocks([string]$Text) {
    return @([regex]::Split($Text, '(?m)^\[\[files\]\]\s*$') | Select-Object -Skip 1)
}

function Get-KxIndexRecords([string]$IndexText) {
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($block in (Get-KxTomlBlocks $IndexText)) {
        $relative = Get-KxTomlString $block 'file'
        $hash = Get-KxTomlString $block 'hash'
        $meta = ([regex]::Match($block, '(?m)^metafile\s*=\s*true\s*$')).Success
        if ($relative -match '(^|/)\.\.?(/|$)' -or $relative.Contains(':') -or $relative.StartsWith('/')) { throw "Ruta insegura en index.toml: $relative" }
        if ($hash -notmatch '^[0-9a-f]{64}$') { throw "Hash inválido en index.toml: $relative" }
        $records.Add([pscustomobject]@{ path = $relative; hash = $hash; metafile = $meta })
    }
    return @($records.ToArray())
}

function Get-KxJarInfo([string]$Path) {
    $ids = New-Object System.Collections.Generic.List[string]
    $versions = New-Object System.Collections.Generic.List[string]
    $displayNames = New-Object System.Collections.Generic.List[string]
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entryName in @('META-INF/neoforge.mods.toml', 'META-INF/mods.toml')) {
            $entry = $zip.GetEntry($entryName)
            if ($null -eq $entry) { continue }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            foreach ($match in [regex]::Matches($text, '(?ms)^\[\[mods\]\]\s*(?<body>.*?)(?=^\[\[mods\]\]|\z)')) {
                $body = $match.Groups['body'].Value
                $idMatch = [regex]::Match($body, '(?m)^\s*modId\s*=\s*"(?<v>[^"]+)"')
                if (!$idMatch.Success) { continue }
                $ids.Add($idMatch.Groups['v'].Value)
                $versionMatch = [regex]::Match($body, '(?m)^\s*version\s*=\s*"(?<v>[^"]+)"')
                if ($versionMatch.Success -and $versionMatch.Groups['v'].Value -notmatch '^\$\{') { $versions.Add($versionMatch.Groups['v'].Value) }
                $nameMatch = [regex]::Match($body, '(?m)^\s*displayName\s*=\s*"(?<v>[^"]+)"')
                if ($nameMatch.Success) { $displayNames.Add($nameMatch.Groups['v'].Value) }
            }
            if ($ids.Count -gt 0) { break }
        }
        if ($ids.Count -eq 0) {
            $entry = $zip.GetEntry('fabric.mod.json')
            if ($null -ne $entry) {
                $reader = New-Object IO.StreamReader($entry.Open())
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $idMatch = [regex]::Match($text, '(?m)^\s*"id"\s*:\s*"(?<v>[^"]+)"')
                $versionMatch = [regex]::Match($text, '(?m)^\s*"version"\s*:\s*"(?<v>[^"]+)"')
                if ($idMatch.Success) { $ids.Add($idMatch.Groups['v'].Value) }
                if ($versionMatch.Success) { $versions.Add($versionMatch.Groups['v'].Value) }
            }
        }
    }
    finally { $zip.Dispose() }
    $filenameVersion = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($Path), '(?i)(?:^|[-_+])v?(\d+(?:\.\d+){1,4}(?:[-+][A-Za-z0-9.-]+)?)')
    $version = if ($versions.Count -gt 0) { $versions[0] } elseif ($filenameVersion.Success) { $filenameVersion.Groups[1].Value } else { 'versión no declarada' }
    $name = if ($displayNames.Count -gt 0) { $displayNames[0] } else { [IO.Path]::GetFileNameWithoutExtension($Path) }
    return [pscustomobject]@{ name = $name; filename = [IO.Path]::GetFileName($Path); version = $version; modIds = @($ids.ToArray()) }
}

function Get-KxProfileSnapshot([string]$ModsPath, [string]$ExclusionsPath) {
    if (!(Test-Path -LiteralPath $ModsPath -PathType Container)) { throw "No existe el perfil cliente: $ModsPath" }
    $decisions = Read-KxJson $ExclusionsPath
    $excluded = @{}
    foreach ($decision in $decisions.decisions) {
        if ($decision.installDestination -ceq 'SERVER_ONLY_CONFIRMED_EXCLUDED_FROM_CLIENT') {
            $excluded[[string]$decision.filename] = ([string]$decision.sha256).ToLowerInvariant()
        }
    }
    $sideByHash = @{}
    if ($script:Paths.ContainsKey('sideMetadata') -and (Test-Path -LiteralPath $script:Paths.sideMetadata -PathType Leaf)) {
        $sideData = Read-KxJson $script:Paths.sideMetadata
        foreach ($sideRow in $sideData.files) {
            $sideHash = [string]$sideRow.localSha256
            if ($sideHash -match '^[0-9a-fA-F]{64}$') { $sideByHash[$sideHash.ToLowerInvariant()] = $sideRow }
        }
    }
    $records = New-Object System.Collections.Generic.List[object]
    $excludedRows = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-ChildItem -LiteralPath $ModsPath -Filter '*.jar' -File)) {
        $hash = Get-KxSha256 $file.FullName
        if ($excluded.ContainsKey($file.Name)) {
            if ($excluded[$file.Name] -cne $hash) { throw "La exclusión server-only está ligada a otro SHA-256: $($file.Name). Revisar esta decisión antes de distribuir." }
            $excludedRows.Add([pscustomobject]@{ filename = $file.Name; sha256 = $hash; reason = 'SERVER_ONLY_CONFIRMED' })
            continue
        }
        $side = $sideByHash[$hash]
        if ($null -ne $side -and ((Get-KxMapValue $side.modrinth 'clientSide') -ceq 'unsupported' -or (Get-KxMapValue $side.modrinth 'environment') -ceq 'server_only')) {
            $excludedRows.Add([pscustomobject]@{ filename = $file.Name; sha256 = $hash; reason = 'OFFICIAL_SOURCE_METADATA_SERVER_ONLY' })
            continue
        }
        $info = Get-KxJarInfo $file.FullName
        $records.Add([pscustomobject]@{
            filename = $file.Name; path = $file.FullName; bytes = [long]$file.Length; sha256 = $hash
            name = $info.name; version = $info.version; modIds = @($info.modIds); side = 'client'
        })
    }
    return [pscustomobject]@{ records = @($records.ToArray() | Sort-Object filename); excluded = @($excludedRows.ToArray()); profilePath = [IO.Path]::GetFullPath($ModsPath) }
}

function Get-KxPublishedSnapshot([string]$PackRoot, [string]$InventoryPath) {
    $releasePath = Join-Path $PackRoot 'release.json'
    $packPath = Join-Path $PackRoot 'pack.toml'
    $indexPath = Join-Path $PackRoot 'index.toml'
    $release = Read-KxJson $releasePath
    $pack = [IO.File]::ReadAllText($packPath)
    $indexText = [IO.File]::ReadAllText($indexPath)
    if ($release.state -cne 'PUBLISHED') { throw "El baseline no está publicado: $($release.state)" }
    if ((Get-KxSha256 $packPath) -cne [string]$release.packTomlSha256) { throw 'El baseline pack.toml no coincide con release.json.' }
    $indexHash = Get-KxTomlString $pack 'hash'
    if ((Get-KxSha256 $indexPath) -cne $indexHash) { throw 'El baseline index.toml no coincide con pack.toml.' }
    $inventory = Read-KxJson $InventoryPath
    $versionByHash = @{}
    foreach ($row in $inventory.files) {
        if ((Get-KxMapValue $row 'selectedForClientPack') -eq $true -or (Get-KxMapValue $row 'selectedForClient') -eq $true) { $versionByHash[([string]$row.sha256).ToLowerInvariant()] = $row }
    }
    $mods = New-Object System.Collections.Generic.List[object]
    foreach ($entry in (Get-KxIndexRecords $indexText | Where-Object { $_.metafile -and $_.path -match '^mods/[^/]+\.jar\.pw\.toml$' })) {
        $metaPath = Join-Path (Join-Path $PackRoot 'mods') ([IO.Path]::GetFileName($entry.path))
        if (!(Test-Path -LiteralPath $metaPath -PathType Leaf)) { throw "Falta metafile del baseline: $($entry.path)" }
        if ((Get-KxSha256 $metaPath) -cne $entry.hash) { throw "Hash del metafile incorrecto: $($entry.path)" }
        $meta = [IO.File]::ReadAllText($metaPath)
        $filename = Get-KxTomlString $meta 'filename'
        $jarHash = (Get-KxTomlString $meta 'hash').ToLowerInvariant()
        $url = Get-KxTomlString $meta 'url'
        Assert-KxSourceUrl $url
        $known = $versionByHash[$jarHash]
        $name = if ($null -ne $known -and $known.projectName) { [string]$known.projectName } else { Get-KxTomlString $meta 'name' -Optional }
        $version = if ($null -ne $known -and $known.profileModVersion) { [string]$known.profileModVersion } else { Get-KxFilenameVersion $filename }
        $ids = if ($null -ne $known) { @($known.modIds) } else { @() }
        $mods.Add([pscustomobject]@{ filename = $filename; name = $name; version = $version; bytes = if ($null -ne $known) { [long]$known.bytes } else { 0L }; sha256 = $jarHash; modIds = $ids; side = 'client'; url = $url; provider = (Get-KxProvider $url); metafile = $metaPath })
    }
    return [pscustomobject]@{ version = [string]$release.releaseVersion; packRoot = [IO.Path]::GetFullPath($PackRoot); release = $release; packText = $pack; indexText = $indexText; indexRecords = (Get-KxIndexRecords $indexText); mods = @($mods.ToArray()) }
}

function Get-KxFilenameVersion([string]$Filename) {
    $match = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($Filename), '(?i)(?:^|[-_+])v?(\d+(?:\.\d+){1,4}(?:[-+][A-Za-z0-9.-]+)?)')
    if ($match.Success) { return $match.Groups[1].Value }
    return 'versión anterior no declarada'
}

function Get-KxProvider([string]$Url) {
    $uri = [Uri]$Url
    switch -CaseSensitive ($uri.Host.ToLowerInvariant()) {
        'raw.githubusercontent.com' { return 'GitHub' }
        'cdn.modrinth.com' { return 'Modrinth' }
        { $_ -in @('edge.forgecdn.net', 'mediafilez.forgecdn.net') } { return 'CurseForge' }
        default { throw "Origen no permitido: $($uri.Host)" }
    }
}

function Get-KxMapValue($Map, [string]$Key) {
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.Contains($Key)) { return $Map[$Key] }
        return $null
    }
    $property = $Map.PSObject.Properties[$Key]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-KxSourceUrl([string]$Url) {
    $uri = $null
    if (![Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw "URL de fuente inválida: $Url" }
    if ($uri.Scheme -cne 'https' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw "La fuente debe ser HTTPS sin credenciales, query ni fragment: $Url" }
    $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
    switch ($uri.Host.ToLowerInvariant()) {
        'raw.githubusercontent.com' { if ($path -notmatch '^/Francho2002/kxcraft/[0-9a-f]{40}/binaries/mods/[^/]+\.jar$') { throw "URL raw de KxCraft no inmutable: $Url" } }
        'cdn.modrinth.com' { if ($path -notmatch '^/data/[A-Za-z0-9_-]+/versions/[A-Za-z0-9_-]+/[^/]+\.jar$') { throw "URL Modrinth no fijada a versión: $Url" } }
        { $_ -in @('edge.forgecdn.net', 'mediafilez.forgecdn.net') } { if ($path -notmatch '^/files/[0-9]{1,4}/[0-9]{1,4}/[^/]+\.jar$') { throw "URL CurseForge no fijada a archivo: $Url" } }
        default { throw "Host de descarga no autorizado: $($uri.Host)" }
    }
}

function Get-KxNextVersion([string]$Version) {
    if ($Version -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') { throw "Solo se incrementa SemVer estable automáticamente: $Version" }
    return ('{0}.{1}.{2}' -f $Matches.major, $Matches.minor, ([int]$Matches.patch + 1))
}

function Get-KxChangeSet($Baseline, $Current) {
    $oldByName = @{}; foreach ($row in $Baseline.mods) { $oldByName[[string]$row.filename] = $row }
    $newByName = @{}; foreach ($row in $Current.records) { $newByName[[string]$row.filename] = $row }
    $unchanged = New-Object System.Collections.Generic.List[object]
    $updated = New-Object System.Collections.Generic.List[object]
    $added = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($old in $Baseline.mods) {
        if ($newByName.ContainsKey([string]$old.filename)) {
            $new = $newByName[[string]$old.filename]
            if ($old.sha256 -ceq $new.sha256) { $unchanged.Add([pscustomobject]@{ old = $old; current = $new }) }
            else { $updated.Add([pscustomobject]@{ old = $old; current = $new; reason = 'SHA-256 cambió' }) }
            $newByName.Remove([string]$old.filename)
        }
        else { $removed.Add($old) }
    }
    foreach ($new in $newByName.Values) { $added.Add($new) }
    # Pair a renamed file as an update only when its mod ID identifies one unique old JAR.
    foreach ($new in @($added.ToArray())) {
        if (@($new.modIds).Count -eq 0) { continue }
        $matches = @($removed.ToArray() | Where-Object { @($_.modIds | Where-Object { $new.modIds -contains $_ }).Count -gt 0 })
        if ($matches.Count -eq 1) {
            $old = $matches[0]
            $updated.Add([pscustomobject]@{ old = $old; current = $new; reason = 'nombre de archivo cambió; modId coincide' })
            [void]$removed.Remove($old); [void]$added.Remove($new)
        }
    }
    return [pscustomobject]@{ added = @($added.ToArray() | Sort-Object filename); updated = @($updated.ToArray() | Sort-Object { $_.current.filename }); removed = @($removed.ToArray() | Sort-Object filename); unchanged = @($unchanged.ToArray() | Sort-Object { $_.current.filename }); excluded = @($Current.excluded) }
}

function Test-KxDownloadedHash([string]$Path, [string]$ExpectedSha256) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$') { return $false }
    return ((Get-KxSha256 $Path) -ceq $ExpectedSha256.ToLowerInvariant())
}

function Invoke-KxWebRequestWithRetry([string]$Uri, [string]$OutFile, [int]$TimeoutSec, [hashtable]$Headers, [int]$MaxAttempts = 5, [int]$InitialDelaySeconds = 2) {
    if ($MaxAttempts -lt 1 -or $MaxAttempts -gt 8 -or $InitialDelaySeconds -lt 0 -or $InitialDelaySeconds -gt 10) { throw 'Parámetros de reintento fuera de los límites permitidos.' }
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $Headers
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            if (!$status) { try { $status = [int]$_.Exception.Response.StatusCode.value__ } catch {} }
            if (!$status) { try { $status = [int]$_.Exception.Data['HttpStatusCode'] } catch {} }
            $transient = $status -in @(408, 429, 500, 502, 503, 504)
            if (!$transient -or $attempt -ge $MaxAttempts) { throw }
            $delay = [Math]::Min(16, [int]($InitialDelaySeconds * [Math]::Pow(2, ($attempt - 1))))
            Write-Host ("HTTP {0} al consultar {1}; reintento {2}/{3} en {4}s." -f $status, $Uri, $attempt, ($MaxAttempts - 1), $delay) -ForegroundColor DarkYellow
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
    throw "No se pudo obtener $Uri tras $MaxAttempts intentos."
}

function Confirm-KxRemoteSource([string]$Url, [string]$ExpectedSha256, [string]$TempRoot) {
    Assert-KxSourceUrl $Url
    [IO.Directory]::CreateDirectory($TempRoot) | Out-Null
    $temp = Join-Path $TempRoot ([Guid]::NewGuid().ToString('N') + '.download')
    try {
        $null = Invoke-KxWebRequestWithRetry $Url $temp 120 @{ 'User-Agent' = 'KxCraft-Updater-Manager/1.0' }
        if (!(Test-KxDownloadedHash $temp $ExpectedSha256)) { throw "La descarga no coincide con el SHA-256 completo esperado: $Url" }
        return [long](Get-Item -LiteralPath $temp).Length
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-KxAuthorizedUpload($Record, [string]$AuthorizationPath) {
    if (!(Test-Path -LiteralPath $AuthorizationPath -PathType Leaf)) { return $false }
    $authorization = Read-KxJson $AuthorizationPath
    foreach ($item in $authorization.files) {
        if ($item.filename -ceq $Record.filename -and ([string]$item.sha256).ToLowerInvariant() -ceq $Record.sha256 -and $item.authorized -eq $true -and $item.publishToRepository -eq $true) { return $item }
    }
    return $false
}

function Get-KxClientSideEvidence($Record, [string]$AuthorizationPath) {
    $hash = ([string]$Record.sha256).ToLowerInvariant()
    if ($script:Paths.ContainsKey('sideMetadata') -and (Test-Path -LiteralPath $script:Paths.sideMetadata -PathType Leaf)) {
        $sideData = Read-KxJson $script:Paths.sideMetadata
        foreach ($row in $sideData.files) {
            if (([string]$row.localSha256).ToLowerInvariant() -cne $hash -or $null -eq $row.modrinth) { continue }
            $clientSide = [string](Get-KxMapValue $row.modrinth 'clientSide')
            $environment = [string](Get-KxMapValue $row.modrinth 'environment')
            if ($clientSide -ceq 'unsupported' -or $environment -ceq 'server_only') {
                return [pscustomobject]@{ verified = $false; serverOnly = $true; evidence = 'La metadata oficial exacta del SHA-256 declara que el archivo no admite cliente.' }
            }
            if ($clientSide -in @('required', 'optional')) {
                return [pscustomobject]@{ verified = $true; serverOnly = $false; evidence = 'Metadata oficial de Modrinth para el SHA-256 exacto declara compatibilidad de cliente.' }
            }
        }
    }
    if ($script:Paths.ContainsKey('inventory') -and (Test-Path -LiteralPath $script:Paths.inventory -PathType Leaf)) {
        $inventory = Read-KxJson $script:Paths.inventory
        foreach ($row in $inventory.files) {
            if (([string]$row.sha256).ToLowerInvariant() -ceq $hash -and (Get-KxMapValue $row 'selectedForClientPack') -eq $true -and (Get-KxMapValue $row 'installDestination') -cne 'SERVER_ONLY_CONFIRMED_EXCLUDED_FROM_CLIENT') {
                return [pscustomobject]@{ verified = $true; serverOnly = $false; evidence = 'Coincide byte por byte con un archivo seleccionado para el perfil cliente en el inventario reconciliado.' }
            }
        }
    }
    if ($script:Paths.ContainsKey('clientSideEvidence') -and (Test-Path -LiteralPath $script:Paths.clientSideEvidence -PathType Leaf)) {
        $evidenceData = Read-KxJson $script:Paths.clientSideEvidence
        foreach ($row in $evidenceData.files) {
            if (([string]$row.filename) -cne [string]$Record.filename -or ([string]$row.sha256).ToLowerInvariant() -cne $hash) { continue }
            $provider = [string](Get-KxMapValue $row 'provider')
            $gameVersion = [string](Get-KxMapValue $row 'minecraft')
            $loader = [string](Get-KxMapValue $row 'loader')
            $evidenceUrl = [string](Get-KxMapValue $row 'evidenceUrl')
            $evidence = [string](Get-KxMapValue $row 'evidence')
            if ((Get-KxMapValue $row 'serverOnlyConfirmed') -eq $true) {
                return [pscustomobject]@{ verified = $false; serverOnly = $true; evidence = ('Hash-bound official side metadata marks this file server-only: ' + $evidence) }
            }
            if ((Get-KxMapValue $row 'clientSideConfirmed') -eq $true -and $gameVersion -ceq '1.21.1' -and $loader -ceq 'NeoForge' -and $provider -in @('Modrinth', 'CurseForge') -and $evidenceUrl -match '^https://(modrinth\.com|www\.curseforge\.com)/' -and ![string]::IsNullOrWhiteSpace($evidence)) {
                return [pscustomobject]@{ verified = $true; serverOnly = $false; evidence = ('Metadata oficial ligada al filename y SHA-256 exactos (' + $provider + '): ' + $evidence) }
            }
        }
    }
    $authorization = Get-KxAuthorizedUpload $Record $AuthorizationPath
    $sideConfirmed = Get-KxMapValue $authorization 'clientSideConfirmed'
    $sideEvidence = [string](Get-KxMapValue $authorization 'clientSideEvidence')
    if ($authorization -and $sideConfirmed -eq $true -and ![string]::IsNullOrWhiteSpace($sideEvidence)) {
        return [pscustomobject]@{ verified = $true; serverOnly = $false; evidence = $sideEvidence }
    }
    return [pscustomobject]@{ verified = $false; serverOnly = $false; evidence = 'No existe evidencia exacta del lado cliente para este SHA-256; confirmar el proyecto/versionado en metadata oficial o agregar una decisión explícita ligada al hash.' }
}

function Find-KxModrinthSource($Record, [string]$TempRoot) {
    $sha = [Security.Cryptography.SHA512]::Create()
    try {
        $stream = [IO.File]::OpenRead($Record.path)
        try { $sha512 = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
    $url = 'https://api.modrinth.com/v2/version_file/' + $sha512 + '?algorithm=sha512'
    try {
        $version = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -Headers @{ 'User-Agent' = 'KxCraft/1.0 (distribution update manager)' }
        if ($version.game_versions -notcontains '1.21.1') { return $null }
        if ($version.loaders -notcontains 'neoforge') { return $null }
        if ($version.files.Count -lt 1) { return $null }
        $project = Invoke-RestMethod -Uri ('https://api.modrinth.com/v2/project/' + [Uri]::EscapeDataString([string]$version.project_id)) -TimeoutSec 30 -Headers @{ 'User-Agent' = 'KxCraft/1.0 (distribution update manager)' }
        if ($project.client_side -ceq 'unsupported' -or (Get-KxMapValue $version 'environment') -ceq 'server_only') { return [pscustomobject]@{ serverOnly = $true; clientSideVerified = $false; verified = $false; sourceEvidence = 'La metadata oficial de Modrinth marca el proyecto/versionado como no apto para cliente.' } }
        if ($project.client_side -notin @('required', 'optional')) { return [pscustomobject]@{ url = $null; provider = 'Modrinth'; bytes = 0; verified = $true; uploadPending = $false; serverOnly = $false; clientSideVerified = $false; sourceEvidence = 'Hash, versión Minecraft y loader coinciden, pero Modrinth no acredita client_side=required/optional.' } }
        foreach ($file in $version.files) {
            if (!$file.url) { continue }
            $candidateUrl = [string]$file.url
            try { $length = Confirm-KxRemoteSource $candidateUrl $Record.sha256 $TempRoot }
            catch { continue }
            return [pscustomobject]@{ url = $candidateUrl; provider = 'Modrinth'; bytes = $length; verified = $true; uploadPending = $false; serverOnly = $false; clientSideVerified = $true; sourceEvidence = 'Modrinth exact SHA-512 lookup; full downloaded SHA-256 matched; Minecraft 1.21.1, NeoForge, and client-side metadata matched.' }
        }
    }
    catch { return $null }
    return $null
}

function Find-KxCurseForgeSource($Record, [string]$TempRoot) {
    $apiKey = [Environment]::GetEnvironmentVariable('KXCRAFT_CURSEFORGE_API_KEY')
    if ([string]::IsNullOrWhiteSpace($apiKey)) { return $null }
    $name = [IO.Path]::GetFileNameWithoutExtension($Record.filename)
    $filter = [Uri]::EscapeDataString($name)
    $headers = @{ 'x-api-key' = $apiKey; 'User-Agent' = 'KxCraft/1.0 distribution manager' }
    try {
        $search = Invoke-RestMethod -Uri "https://api.curseforge.com/v1/mods/search?gameId=432&searchFilter=$filter&gameVersion=1.21.1&modLoaderType=6&pageSize=25" -Headers $headers -TimeoutSec 30
        $localSha1 = (Get-FileHash -LiteralPath $Record.path -Algorithm SHA1).Hash.ToLowerInvariant()
        foreach ($mod in $search.data) {
            $index = 0
            while ($index -lt 10000) {
                $files = Invoke-RestMethod -Uri "https://api.curseforge.com/v1/mods/$($mod.id)/files?gameVersion=1.21.1&modLoaderType=6&index=$index&pageSize=50" -Headers $headers -TimeoutSec 30
                $page = @($files.data)
                foreach ($file in $page) {
                    if ($file.fileName -cne $Record.filename) { continue }
                    $sha1 = $null
                    foreach ($hash in $file.hashes) { if ([int]$hash.algo -eq 1) { $sha1 = ([string]$hash.value).ToLowerInvariant() } }
                    if ($sha1 -cne $localSha1 -or !$file.downloadUrl) { continue }
                    $candidateUrl = [string]$file.downloadUrl
                    try { $length = Confirm-KxRemoteSource $candidateUrl $Record.sha256 $TempRoot }
                    catch { continue }
                    $side = Get-KxClientSideEvidence $Record $script:Paths.binaryAuthorization
                    return [pscustomobject]@{ url = $candidateUrl; provider = 'CurseForge'; bytes = $length; verified = $true; uploadPending = $false; serverOnly = [bool]$side.serverOnly; clientSideVerified = [bool]$side.verified; sourceEvidence = ('CurseForge files API filtrada a Minecraft 1.21.1/NeoForge (loader 6), SHA-1 exacto del archivo y SHA-256 completo; ' + $side.evidence) }
                }
                if ($page.Count -lt 50) { break }
                $index += $page.Count
            }
        }
    }
    catch { return $null }
    return $null
}

function Get-KxSourceForRecord($Record, $Baseline, $SourceRows, [string]$TempRoot, [string]$AuthorizationPath, [string]$BinaryStage) {
    $same = @($Baseline.mods | Where-Object { $_.sha256 -ceq $Record.sha256 }) | Select-Object -First 1
    if ($null -ne $same) { return [pscustomobject]@{ url = $same.url; provider = $same.provider; bytes = [long]$Record.bytes; verified = $true; uploadPending = $false; serverOnly = $false; clientSideVerified = $true; sourceEvidence = 'Reutilizada desde el snapshot publicado: SHA-256 idéntico y previamente incluido como cliente.' } }
    $side = Get-KxClientSideEvidence $Record $AuthorizationPath
    if ($side.serverOnly) { return [pscustomobject]@{ url = $null; provider = $null; bytes = [long]$Record.bytes; verified = $false; uploadPending = $false; serverOnly = $true; clientSideVerified = $false; sourceEvidence = $side.evidence } }
    $exact = @($SourceRows | Where-Object { ([string]$_.sha256).ToLowerInvariant() -ceq $Record.sha256 -and $_.status -ceq 'DIRECT_SOURCE_VERIFIED' }) | Select-Object -First 1
    if ($null -ne $exact) {
        Assert-KxSourceUrl ([string]$exact.url)
        return [pscustomobject]@{ url = [string]$exact.url; provider = (Get-KxProvider ([string]$exact.url)); bytes = [long]$Record.bytes; verified = $true; uploadPending = $false; serverOnly = $false; clientSideVerified = [bool]$side.verified; sourceEvidence = ('Reutilizada desde fuente previa verificada para el SHA-256 exacto; ' + $side.evidence) }
    }
    $source = Find-KxModrinthSource $Record $TempRoot
    if ($null -eq $source) { $source = Find-KxCurseForgeSource $Record $TempRoot }
    if ($null -ne $source) {
        if ($null -eq $source.PSObject.Properties['clientSideVerified']) { $source | Add-Member -NotePropertyName clientSideVerified -NotePropertyValue ([bool]$side.verified) }
        if ($null -eq $source.PSObject.Properties['serverOnly']) { $source | Add-Member -NotePropertyName serverOnly -NotePropertyValue ([bool]$side.serverOnly) }
        if (!$source.clientSideVerified -and [string]::IsNullOrWhiteSpace([string]$source.sourceEvidence)) { $source.sourceEvidence = $side.evidence }
        return $source
    }
    $uploadAuthorization = Get-KxAuthorizedUpload $Record $AuthorizationPath
    if ($uploadAuthorization) {
        [IO.Directory]::CreateDirectory($BinaryStage) | Out-Null
        $dest = Join-Path $BinaryStage $Record.filename
        Copy-Item -LiteralPath $Record.path -Destination $dest -Force
        if ((Get-KxSha256 $dest) -cne $Record.sha256) { throw "La copia de staging binario no conserva el SHA-256: $($Record.filename)" }
        return [pscustomobject]@{ url = $null; provider = 'GitHub'; bytes = [long]$Record.bytes; verified = $true; uploadPending = $true; serverOnly = $false; clientSideVerified = [bool]$side.verified; stagedPath = $dest; sourceEvidence = ('Autorización exacta local; ' + $side.evidence + ' Pendiente de commit binario inmutable.') }
    }
    return $null
}

function Write-KxMeta([string]$Path, $Record, $Source) {
    if ($Source.uploadPending) { throw "No se puede emitir un metafile Packwiz antes de conocer el SHA del commit binario: $($Record.filename)" }
    Assert-KxSourceUrl ([string]$Source.url)
    $text = 'name = ' + (ConvertTo-KxTomlString ([string]$Record.name)) + "`n" +
        'filename = ' + (ConvertTo-KxTomlString ([string]$Record.filename)) + "`n" +
        'side = "client"' + "`n`n[download]`n" +
        'url = ' + (ConvertTo-KxTomlString ([string]$Source.url)) + "`n" +
        'hash-format = "sha256"' + "`n" +
        'hash = ' + (ConvertTo-KxTomlString ([string]$Record.sha256)) + "`n"
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Update-KxIndexAndPack($PackRoot, $Baseline, $Records, $Sources, [string]$Version) {
    $oldStatic = @($Baseline.indexRecords | Where-Object { $_.path -notmatch '^mods/[^/]+\.jar\.pw\.toml$' })
    $indexLines = New-Object System.Collections.Generic.List[string]
    $indexLines.Add('hash-format = "sha256"'); $indexLines.Add('')
    foreach ($record in @($Records | Sort-Object filename)) {
        $metaPath = Join-Path (Join-Path $PackRoot 'mods') ($record.filename + '.pw.toml')
        $hash = Get-KxSha256 $metaPath
        $relative = 'mods/' + $record.filename + '.pw.toml'
        $indexLines.Add('[[files]]'); $indexLines.Add('file = ' + (ConvertTo-KxTomlString $relative)); $indexLines.Add('hash = ' + (ConvertTo-KxTomlString $hash)); $indexLines.Add('metafile = true'); $indexLines.Add('')
    }
    foreach ($entry in $oldStatic) {
        $relativePath = Join-Path $PackRoot ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (!(Test-Path -LiteralPath $relativePath -PathType Leaf)) { throw "Falta payload estático preexistente en el snapshot: $($entry.path)" }
        $actualHash = Get-KxSha256 $relativePath
        if ($actualHash -cne $entry.hash) { throw "Cambió un archivo estático fuera del alcance: $($entry.path)" }
        $indexLines.Add('[[files]]'); $indexLines.Add('file = ' + (ConvertTo-KxTomlString $entry.path)); $indexLines.Add('hash = ' + (ConvertTo-KxTomlString $entry.hash)); if ($entry.metafile) { $indexLines.Add('metafile = true') } else { $indexLines.Add('metafile = false') }; $indexLines.Add('')
    }
    $indexPath = Join-Path $PackRoot 'index.toml'
    [IO.File]::WriteAllText($indexPath, ($indexLines -join "`n").TrimEnd() + "`n", (New-Object Text.UTF8Encoding($false)))
    $packPath = Join-Path $PackRoot 'pack.toml'
    $packText = [IO.File]::ReadAllText($packPath)
    $packText = [regex]::Replace($packText, '(?m)^version\s*=\s*"[^"]*"\s*$', ('version = ' + (ConvertTo-KxTomlString $Version)))
    $packText = [regex]::Replace($packText, '(?m)^hash\s*=\s*"[0-9a-f]+"\s*$', ('hash = ' + (ConvertTo-KxTomlString (Get-KxSha256 $indexPath))))
    [IO.File]::WriteAllText($packPath, $packText, (New-Object Text.UTF8Encoding($false)))
}

function Update-KxRelease($PackRoot, $Baseline, $Records, $Sources, [string]$Version, [string]$State, [string]$SourceMapPath, [string]$RawCommit) {
    $packPath = Join-Path $PackRoot 'pack.toml'; $indexPath = Join-Path $PackRoot 'index.toml'
    $providers = @{ GitHub = 0; Modrinth = 0; CurseForge = 0 }
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Records | Sort-Object filename)) {
        $source = Get-KxMapValue $Sources ([string]$record.filename)
        if ($null -eq $source -or $source.uploadPending -or !$source.url) { throw "Fuente no completada para $($record.filename)." }
        $provider = [string]$source.provider
        if (!$providers.ContainsKey($provider)) { throw "Proveedor desconocido para $($record.filename): $provider" }
        $providers[$provider]++
        $files.Add([pscustomobject]@{ filename = $record.filename; bytes = [long]$record.bytes; sha256 = $record.sha256; status = 'DIRECT_SOURCE_VERIFIED'; provider = $provider; url = $source.url; sourceEvidence = $source.sourceEvidence })
    }
    $sourceMap = [pscustomobject]@{ schemaVersion = 1; releaseVersion = $Version; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); files = @($files.ToArray()) }
    Write-KxJsonAtomic $SourceMapPath $sourceMap
    $entryCount = (Get-KxIndexRecords ([IO.File]::ReadAllText($indexPath))).Count
    $release = [ordered]@{
        schemaVersion = 1; state = $State; releaseVersion = $Version
        packTomlUrl = 'https://francho2002.github.io/kxcraft/pack/managed-3players/pack.toml'
        packTomlSha256 = Get-KxSha256 $packPath; modCount = $Records.Count; indexEntryCount = $entryCount
        downloadableGitHubModCount = $providers.GitHub; downloadableModrinthModCount = $providers.Modrinth
        downloadableCurseForgeModCount = $providers.CurseForge; zipSeededPreservedModCount = 0
        rawBinaryCommit = $RawCommit; exactSourceBlockerCount = 0; sourceMapSha256 = Get-KxSha256 $SourceMapPath
    }
    Write-KxJsonAtomic (Join-Path $PackRoot 'release.json') ([pscustomobject]$release)
    return [pscustomobject]@{ release = [pscustomobject]$release; sourceMap = $sourceMap }
}

function Sync-KxPackCompatibilityChannels([string]$SiteRoot) {
    # Keep player-facing and legacy URLs stable forever. Older Prism profiles pin
    # private-3players; new direct Packwiz profiles use KxCraft. Both mirror the
    # currently published managed snapshot so directory naming can never strand a client.
    $managedRoot = Join-Path $SiteRoot 'pack\managed-3players'
    foreach ($channel in @('KxCraft', 'private-3players')) {
        $aliasRoot = Join-Path $SiteRoot ("pack\{0}" -f $channel)
        if (Test-Path -LiteralPath $aliasRoot) { Remove-Item -LiteralPath $aliasRoot -Recurse -Force }
        Copy-Item -LiteralPath $managedRoot -Destination $aliasRoot -Recurse

        $packPath = Join-Path $aliasRoot 'pack.toml'
        $packText = [IO.File]::ReadAllText($packPath)
        $packText = [regex]::new('(?m)^name\s*=\s*"[^"]*"\s*$').Replace($packText, 'name = "KxCraft"', 1)
        [IO.File]::WriteAllText($packPath, $packText, (New-Object Text.UTF8Encoding($false)))

        $releasePath = Join-Path $aliasRoot 'release.json'
        $release = Read-KxJson $releasePath
        $release.packTomlUrl = "https://francho2002.github.io/kxcraft/pack/$channel/pack.toml"
        $release.packTomlSha256 = Get-KxSha256 $packPath
        Write-KxJsonAtomic $releasePath $release
    }
}

function Assert-KxSnapshot($Snapshot) {
    $packRoot = [string]$Snapshot.packRoot
    $pack = [IO.File]::ReadAllText((Join-Path $packRoot 'pack.toml'))
    $indexPath = Join-Path $packRoot 'index.toml'
    $release = Read-KxJson (Join-Path $packRoot 'release.json')
    if ((Get-KxTomlString $pack 'version') -cne [string]$release.releaseVersion) { throw 'La versión Packwiz y release.json no coinciden.' }
    if ((Get-KxTomlString $pack 'minecraft') -cne '1.21.1' -or (Get-KxTomlString $pack 'neoforge') -cne '21.1.265') { throw 'Minecraft/NeoForge del paquete cambiaron sin autorización.' }
    if ((Get-KxSha256 $indexPath) -cne (Get-KxTomlString $pack 'hash')) { throw 'El hash del índice no coincide con pack.toml.' }
    if ((Get-KxSha256 (Join-Path $packRoot 'pack.toml')) -cne [string]$release.packTomlSha256) { throw 'El hash de pack.toml no coincide con release.json.' }
    $entries = Get-KxIndexRecords ([IO.File]::ReadAllText($indexPath))
    $mods = @($entries | Where-Object { $_.metafile -and $_.path -match '^mods/[^/]+\.jar\.pw\.toml$' })
    if ($mods.Count -ne [int]$release.modCount) { throw "Recuento de mods indexados ($($mods.Count)) no coincide con release.json ($($release.modCount))." }
    foreach ($entry in $entries) {
        $path = [IO.Path]::GetFullPath((Join-Path $packRoot ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        $prefix = [IO.Path]::GetFullPath($packRoot).TrimEnd('\') + '\'
        if (!$path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Archivo indexado ausente o inseguro: $($entry.path)" }
        if ((Get-KxSha256 $path) -cne $entry.hash) { throw "Hash de entrada Packwiz incorrecto: $($entry.path)" }
        if ($entry.metafile -and $entry.path -match '^mods/') {
            $meta = [IO.File]::ReadAllText($path)
            if ((Get-KxTomlString $meta 'side') -cne 'client') { throw "Metafile no marcado client: $($entry.path)" }
            if ($meta -match '(?im)^\[update\]\s*$') { throw "No se admite update block de marketplace: $($entry.path)" }
            $url = Get-KxTomlString $meta 'url'; Assert-KxSourceUrl $url
        }
    }
    if ($release.state -cne 'PUBLISHED' -and $release.state -cne 'CANDIDATE') { throw "Estado de release inválido: $($release.state)" }
    if ($release.rawBinaryCommit -notmatch '^[0-9a-f]{40}$') { throw 'Commit binario inválido.' }
    return [pscustomobject]@{ release = $release; entries = $entries; mods = $mods }
}

function Write-KxManagerConfigDefaults {
    if (!(Test-Path -LiteralPath $script:KxConfigPath -PathType Leaf)) { throw "No existe config de distribución: $script:KxConfigPath" }
    $script:KxConfig = Read-KxJson $script:KxConfigPath
    $script:Paths = @{}
    foreach ($name in @('clientMods', 'exclusions', 'inventory', 'sideMetadata', 'sourceMap', 'seedPackRoot', 'seedSiteRoot', 'statePath', 'candidateRoot', 'binaryAuthorization')) {
        $script:Paths[$name] = Resolve-KxPath ([string]$script:KxConfig.paths.$name)
    }
    if ($null -ne $script:KxConfig.paths.PSObject.Properties['clientSideEvidence'] -and ![string]::IsNullOrWhiteSpace([string]$script:KxConfig.paths.clientSideEvidence)) {
        $script:Paths.clientSideEvidence = Resolve-KxPath ([string]$script:KxConfig.paths.clientSideEvidence)
    }
    return $script:KxConfig
}

function Get-KxSourceRows {
    $data = Read-KxJson $script:Paths.sourceMap
    return @($data.files)
}

function Get-KxBaseline {
    $statePath = $script:Paths.statePath
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Read-KxJson $statePath
        $packRoot = Resolve-KxPath ([string]$state.publishedPackRoot)
        $inventoryPath = Resolve-KxPath ([string]$state.inventoryPath)
    }
    else {
        $packRoot = $script:Paths.seedPackRoot
        $inventoryPath = $script:Paths.inventory
    }
    $snapshot = Get-KxPublishedSnapshot $packRoot $inventoryPath
    if (!(Test-KxRemoteBaseline $snapshot)) { throw 'El canal publicado no coincide con el baseline local de última versión. No se preparó nada; primero sincronizar el baseline de forma controlada.' }
    return $snapshot
}

function Test-KxRemoteBaseline($Snapshot) {
    $releaseUrl = [string]$script:KxConfig.urls.release
    $packUrl = [string]$script:KxConfig.urls.pack
    try {
        $releaseRemote = Invoke-RestMethod -Uri $releaseUrl -TimeoutSec 25 -Headers @{ 'Cache-Control' = 'no-cache'; 'User-Agent' = 'KxCraft-Updater-Manager/1.0' }
        if ($releaseRemote.state -cne 'PUBLISHED' -or $releaseRemote.releaseVersion -cne $Snapshot.version) { return $false }
        if ([string]$releaseRemote.packTomlSha256 -cne (Get-KxSha256 (Join-Path $Snapshot.packRoot 'pack.toml'))) { return $false }
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('kx-pack-' + [Guid]::NewGuid().ToString('N') + '.toml')
        try {
            Invoke-WebRequest -Uri $packUrl -OutFile $temp -UseBasicParsing -TimeoutSec 25 -Headers @{ 'Cache-Control' = 'no-cache'; 'User-Agent' = 'KxCraft-Updater-Manager/1.0' }
            if ((Get-KxSha256 $temp) -cne [string]$releaseRemote.packTomlSha256) { return $false }
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        return $true
    }
    catch { throw "No se pudo comprobar el canal remoto actual en $releaseUrl. $($_.Exception.Message)" }
}

function Get-KxChangesAndSources($Baseline, $Profile, [string]$WorkRoot) {
    $changes = Get-KxChangeSet $Baseline $Profile
    $sourceRows = Get-KxSourceRows
    $sourceMap = @{}
    $binaryStage = Join-Path $WorkRoot 'binary-assets'
    $tempRoot = Join-Path $WorkRoot 'downloads'
    foreach ($record in @($changes.unchanged | ForEach-Object { $_.current }) + @($changes.added) + @($changes.updated | ForEach-Object { $_.current })) {
        $source = Get-KxSourceForRecord $record $Baseline $sourceRows $tempRoot $script:Paths.binaryAuthorization $binaryStage
        if ($null -eq $source) {
            $sourceMap[$record.filename] = [pscustomobject]@{ uploadPending = $false; url = $null; provider = $null; verified = $false; intervention = 'No apareció fuente directa exacta en el catálogo publicado, en la fuente previa ni en la API oficial de Modrinth/CurseForge.' }
        }
        else { $sourceMap[$record.filename] = $source }
    }
    return [pscustomobject]@{ changes = $changes; sources = $sourceMap; workRoot = $WorkRoot; binaryStage = $binaryStage }
}

function New-KxPackCandidate($Baseline, $Profile, $Prepared, [string]$CandidateRoot, [string]$Version) {
    $siteRoot = Join-Path $CandidateRoot 'site'
    if (Test-Path -LiteralPath $siteRoot) { throw "El candidato ya existe; no se sobrescribe: $siteRoot" }
    Copy-Item -LiteralPath $script:Paths.seedSiteRoot -Destination $siteRoot -Recurse
    $packRoot = Join-Path $siteRoot 'pack\managed-3players'
    if (Test-Path -LiteralPath $packRoot) { Remove-Item -LiteralPath $packRoot -Recurse -Force }
    Copy-Item -LiteralPath $Baseline.packRoot -Destination $packRoot -Recurse
    $modsPath = Join-Path $packRoot 'mods'
    [IO.Directory]::CreateDirectory($modsPath) | Out-Null
    foreach ($oldMeta in (Get-ChildItem -LiteralPath $modsPath -Filter '*.jar.pw.toml' -File)) { Remove-Item -LiteralPath $oldMeta.FullName -Force }
    foreach ($record in $Profile.records) {
        $source = Get-KxMapValue $Prepared.sources ([string]$record.filename)
        if ($null -eq $source -or !$source.verified -or $source.uploadPending -or !$source.url) { throw "Candidato bloqueado: fuente exacta pendiente para $($record.filename)." }
        Write-KxMeta (Join-Path $modsPath ($record.filename + '.pw.toml')) $record $source
    }
    Update-KxIndexAndPack $packRoot $Baseline $Profile.records $Prepared.sources $Version
    $sourceMapPath = Join-Path $CandidateRoot 'source-map.json'
    $rawCommit = [string]$Baseline.release.rawBinaryCommit
    $release = Update-KxRelease $packRoot $Baseline $Profile.records $Prepared.sources $Version 'CANDIDATE' $sourceMapPath $rawCommit
    Sync-KxPackCompatibilityChannels $siteRoot
    return [pscustomobject]@{ root = $CandidateRoot; siteRoot = $siteRoot; packRoot = $packRoot; sourceMapPath = $sourceMapPath; version = $Version; changes = $Prepared.changes; profile = $Profile; sources = $Prepared.sources; binaryStage = $Prepared.binaryStage; release = $release.release }
}

function Show-KxChanges($Changes) {
    foreach ($label in @('added', 'updated', 'removed', 'unchanged', 'excluded')) {
        $rows = @($Changes.$label)
        Write-Host ("`n{0} ({1}):" -f $label.ToUpperInvariant(), $rows.Count)
        foreach ($row in $rows) {
            if ($label -ceq 'updated') { $old = $row.old; $cur = $row.current; Write-Host ("  {0} {1} v{2} -> {3} v{4}" -f $cur.name, $old.filename, $old.version, $cur.filename, $cur.version) }
            elseif ($label -ceq 'unchanged') { $cur = $row.current; Write-Host ("  {0} v{1} — sin cambios" -f $cur.name, $cur.version) }
            elseif ($label -ceq 'excluded') { Write-Host ("  {0} — server-only confirmado" -f $row.filename) }
            elseif ($label -ceq 'removed') { Write-Host ("  {0} v{1}" -f $row.name, $row.version) }
            else { Write-Host ("  {0} v{1}" -f $row.name, $row.version) }
        }
    }
}

function Invoke-KxPrepareUpdate {
    $baseline = Get-KxBaseline
    $profile = Get-KxProfileSnapshot $script:Paths.clientMods $script:Paths.exclusions
    $changes = Get-KxChangeSet $baseline $profile
    Show-KxChanges $changes
    $changeCount = $changes.added.Count + $changes.updated.Count + $changes.removed.Count
    if ($changeCount -eq 0) { Write-Host 'No hay cambios respecto a la última versión publicada. No se creó un candidato.'; return }
    $nextVersion = Get-KxNextVersion $baseline.version
    $candidateName = $nextVersion + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $candidateRoot = Join-Path $script:Paths.candidateRoot $candidateName
    [IO.Directory]::CreateDirectory($candidateRoot) | Out-Null
    $tempRoot = Join-Path $candidateRoot 'source-checks'
    $prepared = Get-KxChangesAndSources $baseline $profile $candidateRoot
    $blockers = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($profile.records | Where-Object { $null -eq (Get-KxMapValue $prepared.sources ([string]$_.filename)) -or !(Get-KxMapValue $prepared.sources ([string]$_.filename)).verified -or !(Get-KxMapValue $prepared.sources ([string]$_.filename)).clientSideVerified -or (Get-KxMapValue $prepared.sources ([string]$_.filename)).serverOnly })) {
        $source = Get-KxMapValue $prepared.sources ([string]$row.filename)
        $why = if ($null -eq $source) { 'sin fuente exacta verificada ni autorización de binario propio' } elseif ($source.serverOnly) { 'metadata oficial declara que no admite cliente; retirarlo del perfil o resolver la selección antes de preparar' } elseif (!$source.clientSideVerified) { 'no se pudo acreditar el lado cliente en metadata oficial' } else { [string]$source.intervention }
        $blockers.Add(("{0} v{1} SHA-256 {2}: {3}" -f $row.filename, $row.version, $row.sha256, $why))
    }
    $uploads = @($prepared.sources.Values | Where-Object { $_.uploadPending })
    if ($blockers.Count -gt 0) {
        $report = [pscustomobject]@{ schemaVersion = 1; status = 'BLOCKED'; version = $nextVersion; blockers = @($blockers.ToArray()); changes = $changes; excluded = $profile.excluded; createdAtUtc = [DateTime]::UtcNow.ToString('o') }
        Write-KxJsonAtomic (Join-Path $candidateRoot 'review.json') $report
        Write-Host "Preparación bloqueada únicamente por estos archivos:" -ForegroundColor Yellow
        foreach ($blocker in $blockers) { Write-Host ("  - {0}" -f $blocker) }
        return
    }
    $siteRoot = $null
    if ($uploads.Count -eq 0) {
        $candidate = New-KxPackCandidate $baseline $profile $prepared $candidateRoot $nextVersion
        $siteRoot = $candidate.siteRoot
        $validator = Join-Path $script:KxRoot '.github\scripts\Validate-GitHubPagesPackwizSnapshot.ps1'
        if (!(Test-Path -LiteralPath $validator -PathType Leaf)) { throw 'Falta el validador local dinámico de GitHub Pages.' }
        & $validator -SiteRoot $siteRoot -AllowCandidate
        $snapshotCheck = Assert-KxSnapshot ([pscustomobject]@{ packRoot = $candidate.packRoot })
    }
    $review = [pscustomobject]@{
        schemaVersion = 1; status = if ($uploads.Count -gt 0) { 'READY_PENDING_AUTHORIZED_BINARY_COMMIT' } else { 'READY' }
        version = $nextVersion; candidateRoot = $candidateRoot; siteRoot = $siteRoot
        baselineVersion = $baseline.version; baselinePackRoot = $baseline.packRoot
        profilePath = $profile.profilePath; profileRecords = @($profile.records); excluded = @($profile.excluded)
        sources = $prepared.sources; changes = $changes; uploadCount = $uploads.Count
        releaseCommit = $baseline.release.rawBinaryCommit; createdAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-KxJsonAtomic (Join-Path $candidateRoot 'candidate.json') $review
    Write-KxJsonAtomic (Join-Path (Split-Path -Parent $script:Paths.candidateRoot) 'active-candidate.json') ([pscustomobject]@{ candidate = $candidateRoot; version = $nextVersion })
    Write-Host ("Candidato {0}: {1}; uploads autorizados pendientes: {2}." -f $nextVersion, $review.status, $uploads.Count) -ForegroundColor Green
    if ($siteRoot) { Write-Host ("Validación local: PASS; sitio candidato: {0}" -f $siteRoot) }
}

function Invoke-KxGhApi([string]$Method, [string]$Endpoint, $Body = $null) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) { throw 'No se encontró GitHub CLI (gh). Instalalo y ejecutá gh auth login.' }
    $args = @('api', '--hostname', 'github.com', '--method', $Method)
    $temp = $null
    if ($null -ne $Body) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('kx-gh-api-' + [Guid]::NewGuid().ToString('N') + '.json')
        Write-KxJsonAtomic $temp $Body
        $args += @('--input', $temp)
    }
    $args += $Endpoint
    try {
        $response = & $gh.Source @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("GitHub API {0} {1} falló: {2}" -f $Method, $Endpoint, (($response | Out-String).Trim())) }
        $text = ($response | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    }
    finally { if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-KxRemoteHead {
    $repo = '{0}/{1}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository
    $response = Invoke-KxGhApi 'GET' ("repos/{0}/git/ref/heads/{1}" -f $repo, $script:KxConfig.github.branch)
    return [string]$response.object.sha
}

function New-KxRemoteCommit([string]$Message, $FileMap) {
    $repo = '{0}/{1}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository
    $head = Get-KxRemoteHead
    $commitInfo = Invoke-KxGhApi 'GET' ("repos/{0}/git/commits/{1}" -f $repo, $head)
    $treeItems = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $FileMap) {
        $localPath = [string]$entry.localPath
        $relative = [string]$entry.repositoryPath
        if ($relative.StartsWith('/') -or $relative -match '(^|/)\.\.?(/|$)' -or $relative.Contains(':')) { throw "Ruta insegura para el commit: $relative" }
        if (!(Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Archivo a publicar inexistente: $localPath" }
        $bytes = [IO.File]::ReadAllBytes($localPath)
        if ($entry.binary -and $bytes.Length -gt [int]$script:KxConfig.github.maxRestBinaryBytes) { throw "$relative supera el límite seguro de carga REST configurado. Requiere intervención para un método de carga autorizado; no se intentó publicar." }
        $body = [pscustomobject]@{ content = [Convert]::ToBase64String($bytes); encoding = 'base64' }
        $blob = Invoke-KxGhApi 'POST' ("repos/{0}/git/blobs" -f $repo) $body
        $treeItems.Add([pscustomobject]@{ path = $relative; mode = '100644'; type = 'blob'; sha = [string]$blob.sha })
    }
    $tree = Invoke-KxGhApi 'POST' ("repos/{0}/git/trees" -f $repo) ([pscustomobject]@{ base_tree = [string]$commitInfo.tree.sha; tree = @($treeItems.ToArray()) })
    if ($tree.truncated) { throw 'GitHub devolvió un árbol truncado; se cancela la publicación.' }
    $commit = Invoke-KxGhApi 'POST' ("repos/{0}/git/commits" -f $repo) ([pscustomobject]@{ message = $Message; tree = [string]$tree.sha; parents = @($head) })
    # force=false: GitHub rejects a non-fast-forward update and preserves a concurrent commit.
    $null = Invoke-KxGhApi 'PATCH' ("repos/{0}/git/refs/heads/{1}" -f $repo, $script:KxConfig.github.branch) ([pscustomobject]@{ sha = [string]$commit.sha; force = $false })
    return [string]$commit.sha
}

function Get-KxRemoteTree([string]$Head) {
    $repo = '{0}/{1}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository
    $commit = Invoke-KxGhApi 'GET' ("repos/{0}/git/commits/{1}" -f $repo, $Head)
    return Invoke-KxGhApi 'GET' ("repos/{0}/git/trees/{1}?recursive=1" -f $repo, $commit.tree.sha)
}

function Get-KxPackFileMap([string]$PackRoot, [switch]$IncludeDeletes) {
    $prefix = [string]$script:KxConfig.github.repositoryPackPrefix
    $desired = New-Object System.Collections.Generic.List[object]
    $siteRoot = Split-Path -Parent (Split-Path -Parent $PackRoot)
    $sourceRoots = New-Object System.Collections.Generic.List[object]
    $sourceRoots.Add([pscustomobject]@{ path=$PackRoot; prefix=$prefix })
    foreach ($channel in @('KxCraft', 'private-3players')) {
        $sourceRoots.Add([pscustomobject]@{ path=(Join-Path $siteRoot ("pack\{0}" -f $channel)); prefix=("site/pack/{0}" -f $channel) })
    }
    foreach ($source in $sourceRoots) {
        if (!(Test-Path -LiteralPath $source.path -PathType Container)) { throw "Falta el alias permanente de Packwiz: $($source.path)" }
        foreach ($file in (Get-ChildItem -LiteralPath $source.path -Recurse -File -Force)) {
            $baseFull = [IO.Path]::GetFullPath($source.path).TrimEnd('\') + '\'
            $full = [IO.Path]::GetFullPath($file.FullName)
            if (!$full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Archivo fuera del pack root: $($file.FullName)" }
            $relative = $full.Substring($baseFull.Length).Replace('\', '/')
            if ($relative -match '(^|/)\.\.?(/|$)' -or $relative -match '(?i)(^|/)(.env|.*.key|.*.p12|.*.pem)$' -or $relative -match '(?i)\.(jar|zip|mca|nbt)$') { throw "Archivo no permitido en Packwiz candidato: $relative" }
            $desired.Add([pscustomobject]@{ localPath = $file.FullName; repositoryPath = ($source.prefix + '/' + $relative); binary = $false })
        }
    }
    if (!$IncludeDeletes) { return @($desired.ToArray()) }
    $head = Get-KxRemoteHead
    $tree = Get-KxRemoteTree $head
    $desiredSet = @{}; foreach ($item in $desired) { $desiredSet[$item.repositoryPath] = $true }
    $prefixes = @($prefix, 'site/pack/KxCraft', 'site/pack/private-3players')
    $deletes = New-Object System.Collections.Generic.List[object]
    foreach ($item in $tree.tree) {
        $underPackPrefix = $false
        foreach ($candidatePrefix in $prefixes) { if ($item.path.StartsWith($candidatePrefix + '/', [StringComparison]::OrdinalIgnoreCase)) { $underPackPrefix = $true; break } }
        if ($item.type -ceq 'blob' -and $underPackPrefix -and !$desiredSet.ContainsKey([string]$item.path)) {
            $deletes.Add([pscustomobject]@{ path = [string]$item.path; mode = '100644'; type = 'blob'; sha = $null })
        }
    }
    return [pscustomobject]@{ files = @($desired.ToArray()); deletes = @($deletes.ToArray()) }
}
function Publish-KxPackSnapshot([string]$PackRoot, [string]$Message, [object[]]$AdditionalFileMap = @()) {
    $repo = '{0}/{1}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository
    $head = Get-KxRemoteHead
    $commitInfo = Invoke-KxGhApi 'GET' ("repos/{0}/git/commits/{1}" -f $repo, $head)
    $tree = Invoke-KxGhApi 'GET' ("repos/{0}/git/trees/{1}?recursive=1" -f $repo, $commitInfo.tree.sha)
    if ($tree.truncated) { throw 'No se publican manifiestos con un árbol GitHub incompleto/truncado.' }
    $fileMap = Get-KxPackFileMap $PackRoot
    $desired = @{}; foreach ($file in $fileMap) { $desired[$file.repositoryPath] = $true }
    $treeItems = New-Object System.Collections.Generic.List[object]
    $blobCache = @{}
    foreach ($item in $fileMap) {
        $contentHash = Get-KxSha256 $item.localPath
        if (!$blobCache.ContainsKey($contentHash)) {
            $bytes = [IO.File]::ReadAllBytes($item.localPath)
            $blob = Invoke-KxGhApi 'POST' ("repos/{0}/git/blobs" -f $repo) ([pscustomobject]@{ content = [Convert]::ToBase64String($bytes); encoding = 'base64' })
            $blobCache[$contentHash] = [string]$blob.sha
        }
        $treeItems.Add([pscustomobject]@{ path = $item.repositoryPath; mode = '100644'; type = 'blob'; sha = [string]$blobCache[$contentHash] })
    }
    foreach ($item in $AdditionalFileMap) {
        $relative = [string]$item.repositoryPath
        if (!$relative.StartsWith('site/', [StringComparison]::Ordinal) -or $relative -match '(^|/)\.\.?(/|$)' -or $relative -match '(?i)(^|/)(\.env|.*\.key|.*\.p12|.*\.pem)$') { throw "Invalid additional public release path: $relative" }
        $localPath = [string]$item.localPath
        if (!(Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Additional public release file is missing: $localPath" }
        $bytes = [IO.File]::ReadAllBytes($localPath)
        if ($item.binary -and $bytes.Length -gt [int]$script:KxConfig.github.maxRestBinaryBytes) { throw "$relative exceeds the configured binary upload limit." }
        $blob = Invoke-KxGhApi 'POST' ("repos/{0}/git/blobs" -f $repo) ([pscustomobject]@{ content = [Convert]::ToBase64String($bytes); encoding = 'base64' })
        $treeItems.Add([pscustomobject]@{ path = $relative; mode = '100644'; type = 'blob'; sha = [string]$blob.sha })
    }
    $prefixes = @([string]$script:KxConfig.github.repositoryPackPrefix, 'site/pack/KxCraft', 'site/pack/private-3players')
    foreach ($item in $tree.tree) {
        $underPackPrefix = $false
        foreach ($candidatePrefix in $prefixes) { if ($item.path.StartsWith($candidatePrefix + '/', [StringComparison]::OrdinalIgnoreCase)) { $underPackPrefix = $true; break } }
        if ($item.type -ceq 'blob' -and $underPackPrefix -and !$desired.ContainsKey([string]$item.path)) {
            $treeItems.Add([pscustomobject]@{ path = [string]$item.path; mode = '100644'; type = 'blob'; sha = $null })
        }
    }
    $newTree = Invoke-KxGhApi 'POST' ("repos/{0}/git/trees" -f $repo) ([pscustomobject]@{ base_tree = [string]$commitInfo.tree.sha; tree = @($treeItems.ToArray()) })
    if ($newTree.truncated) { throw 'GitHub devolvió un árbol truncado para manifiestos.' }
    $newCommit = Invoke-KxGhApi 'POST' ("repos/{0}/git/commits" -f $repo) ([pscustomobject]@{ message = $Message; tree = [string]$newTree.sha; parents = @($head) })
    $null = Invoke-KxGhApi 'PATCH' ("repos/{0}/git/refs/heads/{1}" -f $repo, $script:KxConfig.github.branch) ([pscustomobject]@{ sha = [string]$newCommit.sha; force = $false })
    return [string]$newCommit.sha
}

function Get-KxRemoteRepoFile([string]$RepositoryPath, [string]$Ref) {
    $repo = '{0}/{1}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository
    $encoded = [Uri]::EscapeDataString($RepositoryPath).Replace('%2F', '/')
    try { return Invoke-KxGhApi 'GET' ("repos/{0}/contents/{1}?ref={2}" -f $repo, $encoded, $Ref) }
    catch { return $null }
}

function Ensure-KxDynamicValidatorPublished {
    $head = Get-KxRemoteHead
    $path = [string]$script:KxConfig.github.validatorPath
    $local = Join-Path $script:KxRoot $path.Replace('/', '\')
    if (!(Test-Path -LiteralPath $local -PathType Leaf)) { throw 'No existe el validador dinámico en el checkout.' }
    $remote = Get-KxRemoteRepoFile $path $head
    $localHash = Get-KxSha256 $local
    if ($null -ne $remote -and $remote.encoding -ceq 'base64') {
        $remoteBytes = [Convert]::FromBase64String(($remote.content -replace '\s', ''))
        $remoteHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($remoteBytes))).Replace('-', '').ToLowerInvariant()
        if ($remoteHash -ceq $localHash) { return $null }
    }
    $commit = New-KxRemoteCommit ('Make Packwiz Pages validation release-version agnostic') @([pscustomobject]@{ localPath = $local; repositoryPath = $path; binary = $false })
    return $commit
}

function Wait-KxPagesDeployment([string]$Commit, [int]$TimeoutSeconds) {
    $repo = '{0}/{1}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $runs = Invoke-KxGhApi 'GET' ("repos/{0}/actions/workflows/{1}/runs?head_sha={2}&per_page=5" -f $repo, [Uri]::EscapeDataString([string]$script:KxConfig.github.pagesWorkflow), $Commit)
        $run = @($runs.workflow_runs | Where-Object { $_.head_sha -ceq $Commit }) | Select-Object -First 1
        if ($null -ne $run -and $run.status -ceq 'completed') {
            if ($run.conclusion -cne 'success') { throw "GitHub Pages falló: $($run.html_url) (conclusion=$($run.conclusion))." }
            return [string]$run.html_url
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout esperando el workflow Pages para $Commit. El último manifiesto publicado no debe considerarse verificado."
}

function Verify-KxRemoteSnapshot($Candidate, [string]$Commit, [bool]$VerifyAllJars) {
    $base = [string]$script:KxConfig.urls.packDirectory
    $headers = @{ 'Cache-Control' = 'no-cache'; 'User-Agent' = 'KxCraft-Updater-Manager/1.0' }
    $releaseTemp = Join-Path ([IO.Path]::GetTempPath()) ('kx-release-' + [Guid]::NewGuid().ToString('N'))
    try {
        $null = Invoke-KxWebRequestWithRetry ($base + 'release.json') $releaseTemp 45 $headers
        $releaseRemote = [IO.File]::ReadAllText($releaseTemp) | ConvertFrom-Json
    }
    finally { if (Test-Path -LiteralPath $releaseTemp) { Remove-Item -LiteralPath $releaseTemp -Force } }
    if ($releaseRemote.state -cne 'PUBLISHED' -or $releaseRemote.releaseVersion -cne $Candidate.version) { throw 'release.json remoto no refleja la versión publicada.' }
    foreach ($relative in @('pack.toml', 'index.toml', 'release.json')) {
        $remotePath = Join-Path $Candidate.packRoot $relative
        $uri = $base + $relative
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('kx-verify-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = Invoke-KxWebRequestWithRetry $uri $temp 45 $headers
            if ((Get-KxSha256 $temp) -cne (Get-KxSha256 $remotePath)) { throw "Hash remoto distinto para $relative." }
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    }
    $entries = Get-KxIndexRecords ([IO.File]::ReadAllText((Join-Path $Candidate.packRoot 'index.toml')))
    foreach ($entry in $entries) {
        $local = Join-Path $Candidate.packRoot ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('kx-meta-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = Invoke-KxWebRequestWithRetry ($base + $entry.path) $temp 45 $headers
            if ((Get-KxSha256 $temp) -cne $entry.hash -or (Get-KxSha256 $local) -cne $entry.hash) { throw "Hash remoto/local distinto para $($entry.path)." }
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    }
    $siteRoot = Split-Path -Parent (Split-Path -Parent $Candidate.packRoot)
    foreach ($channel in @('KxCraft', 'private-3players')) {
        $aliasRoot = Join-Path $siteRoot ("pack\{0}" -f $channel)
        $aliasBase = "https://francho2002.github.io/kxcraft/pack/$channel/"
        $aliasGate = Read-KxJson (Join-Path $aliasRoot 'release.json')
        if ($aliasGate.state -cne 'PUBLISHED' -or $aliasGate.releaseVersion -cne $Candidate.version -or $aliasGate.packTomlUrl -cne ($aliasBase + 'pack.toml')) { throw "El alias permanente $channel no publica la versión correcta." }
        foreach ($relative in @('pack.toml', 'index.toml', 'release.json')) {
            $localPath = Join-Path $aliasRoot $relative
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('kx-alias-' + [Guid]::NewGuid().ToString('N'))
            try {
                $null = Invoke-KxWebRequestWithRetry ($aliasBase + $relative) $temp 45 $headers
                if ((Get-KxSha256 $temp) -cne (Get-KxSha256 $localPath)) { throw "Hash remoto distinto para el alias $channel/$relative." }
            }
            finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        }
        foreach ($entry in $entries) {
            $relative = [string]$entry.path
            $localPath = Join-Path $aliasRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('kx-alias-meta-' + [Guid]::NewGuid().ToString('N'))
            try {
                $null = Invoke-KxWebRequestWithRetry ($aliasBase + $relative) $temp 45 $headers
                if ((Get-KxSha256 $temp) -cne $entry.hash -or (Get-KxSha256 $localPath) -cne $entry.hash) { throw "Hash remoto/local distinto para el alias $channel/$relative." }
            }
            finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        }
    }
    $changedNames = @{}
    foreach ($row in $Candidate.changes.added) { $changedNames[[string]$row.filename] = $true }
    foreach ($row in $Candidate.changes.updated) { $changedNames[[string]$row.current.filename] = $true }
    foreach ($record in $Candidate.profileRecords) {
        $source = Get-KxMapValue $Candidate.sources ([string]$record.filename)
        if ($VerifyAllJars -or $changedNames.ContainsKey([string]$record.filename)) {
            $null = Confirm-KxRemoteSource ([string]$source.url) ([string]$record.sha256) (Join-Path ([IO.Path]::GetTempPath()) 'KxCraft-RemoteVerify')
        }
    }
    return [pscustomobject]@{ release = $releaseRemote; indexEntries = $entries.Count; changedJarsVerified = $Candidate.changes.added.Count + $Candidate.changes.updated.Count }
}

function Invoke-KxPublicationSequence([scriptblock]$PublishAssets, [scriptblock]$VerifyAssets, [scriptblock]$PublishManifest, [scriptblock]$WaitAndVerify, [scriptblock]$RollbackManifest) {
    $assets = & $PublishAssets
    if ($null -ne $assets) { $null = & $VerifyAssets $assets }
    $manifest = & $PublishManifest $assets
    $manifestPublished = $true
    # Verification helpers may return diagnostic objects/URLs. Keep them out of
    # this function's success value so callers always receive one sequence object.
    try { $null = & $WaitAndVerify $manifest }
    catch {
        $original = $_
        if ($manifestPublished) {
            try { $null = & $RollbackManifest $manifest }
            catch { throw "Falló el despliegue y también falló el rollback del manifest; intervención urgente. Error despliegue: $($original.Exception.Message); rollback: $($_.Exception.Message)" }
        }
        throw $original
    }
    return [pscustomobject]@{ assets = $assets; manifest = $manifest }
}

function Invoke-KxPublishUpdate {
    $activePath = Join-Path (Split-Path -Parent $script:Paths.candidateRoot) 'active-candidate.json'
    if (!(Test-Path -LiteralPath $activePath -PathType Leaf)) { throw 'No hay candidato preparado. Usá primero «Preparar actualización».' }
    $active = Read-KxJson $activePath
    $candidateRoot = [IO.Path]::GetFullPath([string]$active.candidate)
    $candidatePrefix = [IO.Path]::GetFullPath($script:Paths.candidateRoot).TrimEnd('\') + '\'
    if (!$candidateRoot.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'La ruta del candidato sale del directorio privado permitido.' }
    $review = Read-KxJson (Join-Path $candidateRoot 'candidate.json')
    if ($review.status -ceq 'BLOCKED') { throw 'El candidato tiene bloqueos de fuentes; resolver exactamente esos archivos y volver a prepararlo.' }
    $baseline = Get-KxBaseline
    if ($baseline.version -cne [string]$review.baselineVersion) { throw 'El canal cambió desde la preparación. Revisá y prepará nuevamente.' }
    $profile = Get-KxProfileSnapshot $script:Paths.clientMods $script:Paths.exclusions
    $candidateHashMap = @{}; foreach ($row in $review.profileRecords) { $candidateHashMap[[string]$row.filename] = [string]$row.sha256 }
    if ($candidateHashMap.Count -ne $profile.records.Count) { throw 'El perfil cambió desde la preparación. Revisá y prepará nuevamente.' }
    foreach ($row in $profile.records) { if (!$candidateHashMap.ContainsKey($row.filename) -or $candidateHashMap[$row.filename] -cne $row.sha256) { throw "Cambió el perfil desde la preparación: $($row.filename)." } }
    $workflowPath = [string]$script:KxConfig.github.pagesWorkflowPath
    $workflowId = [string]$script:KxConfig.github.pagesWorkflow
    if ($workflowPath -notmatch '^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$' -or [IO.Path]::GetFileName($workflowPath) -cne $workflowId) { throw 'La ruta e identidad del workflow Pages no son coherentes.' }
    $workflow = Get-KxRemoteRepoFile $workflowPath (Get-KxRemoteHead)
    if ($null -eq $workflow -or $workflow.encoding -cne 'base64') { throw 'No se verificó el workflow Pages remoto. No se modificó el manifiesto.' }
    $workflowText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($workflow.content -replace '\s', '')))
    if ($workflowText -notmatch '(?m)^\s*path:\s*site/\s*$' -or $workflowText -notmatch 'Validate-GitHubPagesPackwizSnapshot' -or $workflowText -notmatch 'actions/deploy-pages@') { throw 'El workflow remoto no confirma despliegue exclusivo de site/, validación Packwiz y GitHub Pages. No se publica.' }
    $hasUploads = [int]$review.uploadCount -gt 0
    $checked = $null
    if (!$hasUploads) {
        $validation = Join-Path $script:KxRoot '.github\scripts\Validate-GitHubPagesPackwizSnapshot.ps1'
        & $validation -SiteRoot $review.siteRoot -AllowCandidate
        $candidatePack = Join-Path $review.siteRoot 'pack\managed-3players'
        $checked = Assert-KxSnapshot ([pscustomobject]@{ packRoot = $candidatePack })
        $summaryEntryCount = $checked.entries.Count
    }
    else {
        $checked = [pscustomobject]@{ release = [pscustomobject]@{ modCount = $profile.records.Count } }
        $summaryEntryCount = $baseline.indexRecords.Count - $baseline.mods.Count + $profile.records.Count
    }
    $summary = "Versión $($review.version); mods=$($checked.release.modCount); entradas=$summaryEntryCount; cambios: +$($review.changes.added.Count), actualizados $($review.changes.updated.Count), -$($review.changes.removed.Count); uploads autorizados=$($review.uploadCount); excluidos server-only=$($review.excluded.Count)."
    Write-Host "`nRESUMEN FINAL`n$summary" -ForegroundColor Yellow
    $confirm = Read-Host ("Para publicar escribí exactamente PUBLICAR {0}" -f $review.version)
    if ($confirm -cne ("PUBLICAR {0}" -f $review.version)) { Write-Host 'Publicación cancelada; el canal permanece igual.'; return }

    $validatorCommit = Ensure-KxDynamicValidatorPublished
    if ($validatorCommit) {
        Write-Host "Actualizando validador dinámico (commit $validatorCommit)..."
        $null = Wait-KxPagesDeployment $validatorCommit ([int]$script:KxConfig.github.pagesTimeoutSeconds)
    }
    $assetCommit = $null
    if ($hasUploads) {
        $uploads = @($review.sources.PSObject.Properties | Where-Object { $_.Value.uploadPending })
        if ($uploads.Count -eq 0) { throw 'uploadCount no coincide con los registros del candidato.' }
        $binaryMap = foreach ($property in $uploads) {
            $source = $property.Value
            $record = @($review.profileRecords | Where-Object { $_.filename -ceq $property.Name }) | Select-Object -First 1
            if ($null -eq $record -or !(Test-KxDownloadedHash $source.stagedPath $record.sha256)) { throw "El binario autorizado cambió antes de publicar: $($property.Name)" }
            [pscustomobject]@{ localPath = [string]$source.stagedPath; repositoryPath = ('binaries/mods/' + $record.filename); binary = $true }
        }
        $assetCommit = New-KxRemoteCommit ("KxCraft authorized binary assets for {0}" -f $review.version) @($binaryMap)
        foreach ($property in $uploads) {
            $record = @($review.profileRecords | Where-Object { $_.filename -ceq $property.Name }) | Select-Object -First 1
            $url = 'https://raw.githubusercontent.com/{0}/{1}/{2}/binaries/mods/{3}' -f $script:KxConfig.github.owner, $script:KxConfig.github.repository, $assetCommit, $record.filename
            $length = Confirm-KxRemoteSource $url $record.sha256 (Join-Path ([IO.Path]::GetTempPath()) 'KxCraft-BinaryUploadVerify')
            if ($length -ne [long]$record.bytes) { throw "Tamaño remoto distinto tras publicar $($record.filename). Manifiesto sin cambios; binario huérfano retenido en GitHub." }
            $property.Value.url = $url; $property.Value.provider = 'GitHub'; $property.Value.verified = $true; $property.Value.uploadPending = $false; $property.Value.bytes = [long]$record.bytes
            $property.Value.sourceEvidence = "Binario propio/exactamente autorizado publicado en commit $assetCommit y descargado de vuelta con SHA-256 completo coincidente."
        }
        $profileForBuild = [pscustomobject]@{ records = @($review.profileRecords); excluded = @($review.excluded); profilePath = [string]$review.profilePath }
        $preparedForBuild = [pscustomobject]@{ changes = $review.changes; sources = $review.sources; binaryStage = Join-Path $candidateRoot 'binary-assets' }
        $candidateBuilt = New-KxPackCandidate $baseline $profileForBuild $preparedForBuild $candidateRoot $review.version
        $review.siteRoot = $candidateBuilt.siteRoot
        $review.uploadCount = 0
        Write-KxJsonAtomic (Join-Path $candidateRoot 'candidate.json') $review
    }
    $packRoot = Join-Path $review.siteRoot 'pack\managed-3players'
    $releasePath = Join-Path $packRoot 'release.json'
    $release = Read-KxJson $releasePath
    if ($assetCommit) { $release.rawBinaryCommit = $assetCommit }
    if ($release.state -cne 'PUBLISHED') { $release.state = 'PUBLISHED' }
    Write-KxJsonAtomic $releasePath $release
    if ($assetCommit) {
        # Regenerate the source map and pin in release.json after the immutable commit is known.
        $sourceMapPath = Join-Path $candidateRoot 'source-map.json'
        $release.packTomlSha256 = Get-KxSha256 (Join-Path $packRoot 'pack.toml')
        $release.sourceMapSha256 = Get-KxSha256 $sourceMapPath
        Write-KxJsonAtomic $releasePath $release
    }
    Sync-KxPackCompatibilityChannels $review.siteRoot
    $null = Assert-KxSnapshot ([pscustomobject]@{ packRoot = $packRoot })
    $remoteCandidate = [pscustomobject]@{ version = $review.version; packRoot = $packRoot; sources = $review.sources; changes = $review.changes; profileRecords = @($review.profileRecords) }
    $script:currentPublishCandidate = $remoteCandidate
    $publishFiles = @(
        [pscustomobject]@{ localPath = (Join-Path $review.siteRoot 'index.html'); repositoryPath = 'site/index.html'; binary = $false },
        [pscustomobject]@{ localPath = (Join-Path $review.siteRoot 'updater\manifest.json'); repositoryPath = 'site/updater/manifest.json'; binary = $false },
        [pscustomobject]@{ localPath = (Join-Path $review.siteRoot 'updater\manifest.sig'); repositoryPath = 'site/updater/manifest.sig'; binary = $false }
    )
    $sequence = Invoke-KxPublicationSequence `
        { return $assetCommit } `
        { param($x) } `
        { param($x) Publish-KxPackSnapshot $packRoot ("KxCraft modpack {0}" -f $review.version) $publishFiles } `
        { param($commit) $url = Wait-KxPagesDeployment $commit ([int]$script:KxConfig.github.pagesTimeoutSeconds); Verify-KxRemoteSnapshot $script:currentPublishCandidate $commit $false } `
        { param($commit)
            $rollbackRoot = Join-Path $review.candidateRoot 'rollback-site'
            $rollbackPack = Join-Path $rollbackRoot 'pack\managed-3players'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $rollbackPack)) | Out-Null
            Copy-Item -LiteralPath $baseline.packRoot -Destination $rollbackPack -Recurse -Force
            $oldRelease = Read-KxJson (Join-Path $rollbackPack 'release.json')
            if ($oldRelease.state -cne 'PUBLISHED') { throw 'El snapshot de rollback no está PUBLISHED.' }
            Sync-KxPackCompatibilityChannels $rollbackRoot
            $rollbackFiles = @(
                [pscustomobject]@{localPath=(Join-Path $rollbackRoot 'index.html');repositoryPath='site/index.html';binary=$false},
                [pscustomobject]@{localPath=(Join-Path $rollbackRoot 'updater\manifest.json');repositoryPath='site/updater/manifest.json';binary=$false},
                [pscustomobject]@{localPath=(Join-Path $rollbackRoot 'updater\manifest.sig');repositoryPath='site/updater/manifest.sig';binary=$false}
            )
            $rollbackCommit = Publish-KxPackSnapshot $rollbackPack 'KxCraft automatic rollback to last published Packwiz snapshot' $rollbackFiles
            $null = Wait-KxPagesDeployment $rollbackCommit ([int]$script:KxConfig.github.pagesTimeoutSeconds)
            $rollbackCommit
        }
    $newPackRoot = Join-Path $candidateRoot 'site\pack\managed-3players'
    $inventoryOutput = Join-Path $candidateRoot 'published-inventory.json'
    $inventoryFiles = foreach ($row in $profile.records) { [pscustomobject]@{ filename = $row.filename; bytes = $row.bytes; sha256 = $row.sha256; modIds = @($row.modIds); projectName = $row.name; profileModVersion = $row.version; selectedForClient = $true } }
    Write-KxJsonAtomic $inventoryOutput ([pscustomobject]@{ schemaVersion = 1; files = @($inventoryFiles); source = 'profile scan verified at publication'; publishedVersion = $review.version })
    Write-KxJsonAtomic $script:Paths.statePath ([pscustomobject]@{ schemaVersion = 1; releaseVersion = $review.version; publishedPackRoot = $newPackRoot; inventoryPath = $inventoryOutput; lastCommit = $sequence.manifest })
    Write-Host ("Publicado KxCraft {0}; commit {1}. Manifiestos remotos verificados." -f $review.version, $sequence.manifest) -ForegroundColor Green
}

function Start-KxManager {
    $null = Write-KxManagerConfigDefaults
    while ($true) {
        Write-Host "`nKxCraft — administrador de actualizaciones" -ForegroundColor Cyan
        Write-Host '1. Revisar cambios'
        Write-Host '2. Preparar actualización'
        Write-Host '3. Publicar actualización'
        Write-Host '4. Salir'
        $choice = Read-Host 'Elegí una opción'
        try {
            switch ($choice) {
                '1' {
                    $baseline = Get-KxBaseline
                    $profile = Get-KxProfileSnapshot $script:Paths.clientMods $script:Paths.exclusions
                    $changes = Get-KxChangeSet $baseline $profile
                    Write-Host ("Canal publicado: {0}; cliente: {1} JAR; exclusiones server-only: {2}" -f $baseline.version, $profile.records.Count, $profile.excluded.Count)
                    Show-KxChanges $changes
                }
                '2' { Invoke-KxPrepareUpdate }
                '3' { Invoke-KxPublishUpdate }
                '4' { return }
                default { Write-Warning 'Opción inválida.' }
            }
        }
        catch { Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    }
}

if (!$LibraryOnly) { Start-KxManager }
