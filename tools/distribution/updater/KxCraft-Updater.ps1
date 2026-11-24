[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackTomlUrl,
    [Parameter(Mandatory = $true)]
    [string]$MinecraftDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPackSha256,
    [Parameter(Mandatory = $true)]
    [int]$ExpectedModCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:BootstrapSha256 = 'a8fbb24dc604278e97f4688e82d3d91a318b98efc08d5dbfcbcbcab6443d116c'
$script:InstallerSha256 = 'c9f646908d340d84773948a9a7d98bc1dae250d35e1016dc6e2b8459760b5598'
$managedFilesScript = Join-Path $PSScriptRoot 'KxCraft-ManagedFiles.ps1'
if (!(Test-Path -LiteralPath $managedFilesScript -PathType Leaf)) { [Console]::Error.WriteLine('KxCraft update blocked: managed-file safety helper is missing.'); exit 12 }
. $managedFilesScript

function Stop-Launch([string]$Message) {
    [Console]::Error.WriteLine("KxCraft update blocked: $Message")
    exit 12
}

function Invoke-KxProcessAndCheckExitCode([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [string]$Description) {
    if (!(Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "$Description executable is missing: $FilePath" }
    if (!(Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw "$Description working directory is missing: $WorkingDirectory" }
    $quotedArguments = @()
    foreach ($argument in $Arguments) {
        if ($null -eq $argument -or $argument.Contains('"')) { throw "$Description contains an invalid process argument." }
        if ($argument -match '\s') { $quotedArguments += ('"' + $argument + '"') }
        else { $quotedArguments += $argument }
    }
    $process = $null
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList ($quotedArguments -join ' ') -WorkingDirectory $WorkingDirectory -Wait -PassThru -NoNewWindow -ErrorAction Stop
    }
    catch {
        throw "$Description could not be started: $($_.Exception.Message)"
    }
    if ($null -eq $process) { throw "$Description did not return a process result." }
    $exitCode = [int]$process.ExitCode
    if ($exitCode -ne 0) { throw "$Description exited with code $exitCode." }
    return $exitCode
}

try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
catch { Stop-Launch 'Windows HTTP support (System.Net.Http) could not be loaded.' }

function Get-TomlString([string]$Text, [string]$Name) {
    $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*=\s*"(?<value>(?:[^"\\]|\\.)*)"\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (!$match.Success) { throw "Missing TOML string '$Name'." }
    $value = $match.Groups['value'].Value
    if ($value -match '\\(?!["\\nrt])') { throw "Unsupported TOML escape in '$Name'." }
    return $value.Replace('\"', '"').Replace('\\', '\').Replace('\n', "`n").Replace('\r', "`r").Replace('\t', "`t")
}

function Get-TomlBlocks([string]$Text) {
    return @([regex]::Split($Text, '(?m)^\[\[files\]\]\s*$') | Select-Object -Skip 1)
}

function Get-RelativeUri([Uri]$Base, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [Uri]::IsWellFormedUriString($Relative, [UriKind]::Absolute) -or $Relative -match '(^|/)\.\.(/|$)' -or $Relative.Contains('\')) {
        throw "Unsafe relative Packwiz path: $Relative"
    }
    $uri = [Uri]::new($Base, $Relative)
    if ($uri.Scheme -ne 'https') { throw "Packwiz resource is not HTTPS: $uri" }
    return $uri
}

function Assert-KxCraftImmutableModUrl([string]$Url, [string]$Relative, [string]$Filename) {
    $downloadUrl = $null
    if (![Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$downloadUrl)) { throw "Invalid mod URL: $Relative" }
    if ($downloadUrl.Scheme -cne 'https' -or !$downloadUrl.IsDefaultPort -or
        ![string]::IsNullOrEmpty($downloadUrl.UserInfo) -or ![string]::IsNullOrEmpty($downloadUrl.Query) -or
        ![string]::IsNullOrEmpty($downloadUrl.Fragment)) {
        throw "Mod URL must be a clean HTTPS URL without credentials, query, or fragment: $Relative"
    }
    if ([IO.Path]::GetFileName($Filename) -cne $Filename -or $Filename -match '[<>:"/\\|?*]' -or
        $Filename -notmatch '\.jar$') {
        throw "Packwiz metadata contains an unsafe JAR filename: $Relative"
    }

    $path = [Uri]::UnescapeDataString($downloadUrl.AbsolutePath)
    switch ($downloadUrl.Host) {
        'raw.githubusercontent.com' {
            $pathMatch = [regex]::Match($path, '^/Francho2002/kxcraft/([0-9a-fA-F]{40})/binaries/mods/(?:((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)/)?([^/]+\.jar)$')
            if (!$pathMatch.Success -or $pathMatch.Groups[3].Value -cne $Filename) {
                throw "GitHub source must be a full-commit KxCraft raw URL whose filename matches the Packwiz record: $Relative"
            }
        }
        'cdn.modrinth.com' {
            if ($path -notmatch '^/data/[A-Za-z0-9_-]+/versions/[A-Za-z0-9_-]+/[^/]+\.jar$') {
                throw "Modrinth source must use a version-pinned direct CDN file URL: $Relative"
            }
        }
        'edge.forgecdn.net' {
            if ($path -notmatch '^/files/[0-9]{1,4}/[0-9]{1,4}/[^/]+\.jar$') {
                throw "CurseForge source must use a file-ID-pinned direct CDN URL: $Relative"
            }
        }
        'mediafilez.forgecdn.net' {
            $pathMatch = [regex]::Match($path, '^/files/[0-9]{1,4}/[0-9]{1,4}/([^/]+\.jar)$')
            if (!$pathMatch.Success -or $pathMatch.Groups[1].Value -cne $Filename) {
                throw "CurseForge mirror source must use a file-ID-pinned direct URL whose filename matches the Packwiz record: $Relative"
            }
        }
        default {
            throw "Mod source host is not allowed: $($downloadUrl.Host)"
        }
    }
}

function Get-LocalPath([string]$MinecraftDirectory, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('\') -or $Relative -match '(^|/)\.\.(/|$)') {
        throw "Unsafe installed path: $Relative"
    }
    $root = [IO.Path]::GetFullPath($MinecraftDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $root ($Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    if (!$path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Installed path escapes the Minecraft directory: $Relative" }
    return $path
}

function Get-RemoteBytes([Uri]$Uri) {
    if ($Uri.Scheme -ne 'https') { throw "Refusing non-HTTPS request: $Uri" }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(45)
    try {
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        try {
            if (!$response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) for $Uri" }
            if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw "HTTPS request redirected to a non-HTTPS URI: $Uri" }
            return $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        } finally { $response.Dispose() }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-KxJavaExecutable([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    try {
        $candidatePath = [IO.Path]::GetFullPath($Candidate.Trim())
        $fileName = [IO.Path]::GetFileName($candidatePath)
        if ($fileName -ine 'java.exe' -and $fileName -ine 'javaw.exe') { return $false }
        return (Test-Path -LiteralPath $candidatePath -PathType Leaf)
    }
    catch {
        return $false
    }
}

function Resolve-KxJavaExecutable([string]$MinecraftDirectory, [string]$EnvironmentValue) {
    if (Test-KxJavaExecutable $EnvironmentValue) {
        return [IO.Path]::GetFullPath($EnvironmentValue.Trim())
    }

    # Prism Launcher documents INST_JAVA as the selected Java binary. Some
    # launcher builds can nevertheless expose the data directory here. The
    # instance.cfg JavaPath is the local, instance-specific fallback.
    $instanceDirectory = Split-Path -Parent $MinecraftDirectory
    $instanceConfigPath = Join-Path $instanceDirectory 'instance.cfg'
    if (Test-Path -LiteralPath $instanceConfigPath -PathType Leaf) {
        $configuredJava = $null
        foreach ($line in [IO.File]::ReadAllLines($instanceConfigPath)) {
            if ($line.StartsWith('JavaPath=', [StringComparison]::Ordinal)) {
                $configuredJava = $line.Substring('JavaPath='.Length).Trim()
            }
        }
        if (Test-KxJavaExecutable $configuredJava) {
            [Console]::Error.WriteLine('KxCraft: Prism INST_JAVA was not an executable file; using this instance''s JavaPath.')
            return [IO.Path]::GetFullPath($configuredJava)
        }
    }

    # Prism 11 can expose its data root as INST_JAVA in some launch contexts.
    # Resolve the bundled Java 21 runtime from that root, APPDATA, or the
    # standard Prism instance layout without embedding an owner-specific path.
    $prismRoots = @()
    if (![string]::IsNullOrWhiteSpace($EnvironmentValue)) {
        try {
            $environmentRoot = [IO.Path]::GetFullPath($EnvironmentValue.Trim())
            if (Test-Path -LiteralPath $environmentRoot -PathType Container) { $prismRoots += $environmentRoot }
        } catch { }
    }
    if (![string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $prismRoots += (Join-Path $env:APPDATA 'PrismLauncher')
    }
    $instancesDirectory = Split-Path -Parent $instanceDirectory
    $layoutRoot = Split-Path -Parent $instancesDirectory
    if (![string]::IsNullOrWhiteSpace($layoutRoot)) { $prismRoots += $layoutRoot }
    $seenRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $prismRoots) {
        if (![string]::IsNullOrWhiteSpace($root)) {
            try { $root = [IO.Path]::GetFullPath($root) } catch { continue }
            if (!$seenRoots.Add($root)) { continue }
            $managedJava = Join-Path $root 'java\java-runtime-delta\bin\java.exe'
            if (Test-KxJavaExecutable $managedJava) {
                [Console]::Error.WriteLine('KxCraft: Prism did not supply an executable Java path; using Prism-managed Java 21 runtime-delta.')
                return [IO.Path]::GetFullPath($managedJava)
            }
        }
    }

    throw 'Prism did not provide a usable Java executable; instance.cfg has no valid JavaPath and the Prism-managed Java 21 runtime-delta was not found.'
}

function Get-Sha256File([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-StrictUtf8([byte[]]$Bytes) {
    return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
}

function Get-KxCraftReleaseGate([Uri]$PackUri) {
    $gateUri = [Uri]::new($PackUri, 'release.json')
    $gateBytes = Get-RemoteBytes $gateUri
    $gate = Get-StrictUtf8 $gateBytes | ConvertFrom-Json -ErrorAction Stop
    if ($gate.schemaVersion -ne 1 -or [string]$gate.state -cne 'PUBLISHED') {
        throw 'KxCraft release gate is absent, malformed, or not published.'
    }
    if ([string]$gate.packTomlUrl -cne $PackUri.AbsoluteUri) {
        throw 'KxCraft release gate points at a different Packwiz manifest.'
    }
    $expectedPackHash = ([string]$gate.packTomlSha256).ToLowerInvariant()
    if ($expectedPackHash -notmatch '^[0-9a-f]{64}$') {
        throw 'KxCraft release gate does not pin pack.toml with SHA-256.'
    }
    $expectedModCount = 0
    if (![int]::TryParse([string]$gate.modCount, [ref]$expectedModCount) -or $expectedModCount -lt 1 -or $expectedModCount -gt 512) {
        throw 'KxCraft release gate must declare a valid expected mod count.'
    }
    $packBytes = Get-RemoteBytes $PackUri
    if ((Get-Sha256Bytes $packBytes) -ne $expectedPackHash) {
        throw 'pack.toml SHA-256 does not match the published release gate.'
    }
    return [pscustomobject]@{ Uri = $gateUri; PackTomlSha256 = $expectedPackHash; ModCount = $expectedModCount }
}

function Test-KxCraftManifestDownloadUris([Uri]$PackUri) {
    $packBytes = Get-RemoteBytes $PackUri
    $packText = Get-StrictUtf8 $packBytes
    if ((Get-TomlString $packText 'pack-format') -ne 'packwiz:1.1.0' -or
        (Get-TomlString $packText 'minecraft') -ne '1.21.1' -or
        (Get-TomlString $packText 'neoforge') -ne '21.1.265') {
        throw 'Pack manifest format or Minecraft/NeoForge version is not supported by this KxCraft instance.'
    }
    $indexFile = Get-TomlString $packText 'file'
    $indexHash = Get-TomlString $packText 'hash'
    if ((Get-TomlString $packText 'hash-format') -ne 'sha256' -or $indexHash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Pack index lacks a SHA-256 pin.' }
    $indexUri = Get-RelativeUri $PackUri $indexFile
    $indexBytes = Get-RemoteBytes $indexUri
    if ((Get-Sha256Bytes $indexBytes) -ne $indexHash.ToLowerInvariant()) { throw 'Pack index SHA-256 does not match pack.toml.' }
    $indexText = Get-StrictUtf8 $indexBytes
    if ((Get-TomlString $indexText 'hash-format') -ne 'sha256') { throw 'Pack index hash-format is not sha256.' }
    $modCount = 0
    $seenModPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $managedFiles = @{}
    foreach ($block in (Get-TomlBlocks $indexText)) {
        $relative = Get-TomlString $block 'file'
        $hash = Get-TomlString $block 'hash'
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid Packwiz index hash: $relative" }
        if ($block -match '(?m)^metafile\s*=\s*true\s*$') {
            if ($relative -notmatch '^mods/[^/]+\.pw\.toml$') { throw "Non-mod metafile in client manifest: $relative" }
            if (!$seenModPaths.Add($relative)) { throw "Duplicate mod path in Packwiz index: $relative" }
            $metadataUri = Get-RelativeUri $indexUri $relative
            $metadataBytes = Get-RemoteBytes $metadataUri
            if ((Get-Sha256Bytes $metadataBytes) -ne $hash.ToLowerInvariant()) { throw "Mod metadata SHA-256 mismatch: $relative" }
            $metadataText = Get-StrictUtf8 $metadataBytes
            if ((Get-TomlString $metadataText 'side') -ne 'client' -or $metadataText -match '(?im)^\[update\]') { throw "Non-client or marketplace-backed mod metadata: $relative" }
            if ((Get-TomlString $metadataText 'hash-format') -ne 'sha256' -or (Get-TomlString $metadataText 'hash') -notmatch '^[0-9a-fA-F]{64}$') { throw "Mod metafile lacks a valid SHA-256: $relative" }
            $filename = Get-TomlString $metadataText 'filename'
            if ($relative -cne "mods/$filename.pw.toml") { throw "Mod metafile filename does not match its index path: $relative" }
            Assert-KxCraftImmutableModUrl (Get-TomlString $metadataText 'url') $relative $filename
            $installedRelative = "mods/$filename"
            if ($managedFiles.ContainsKey($installedRelative)) { throw "Duplicate managed client mod path: $installedRelative" }
            $managedFiles[$installedRelative] = (Get-TomlString $metadataText 'hash').ToLowerInvariant()
            $modCount++
        } else {
            if ($relative -notmatch '^mods/[^/]+\.jar$' -or $block -notmatch '(?m)^preserve\s*=\s*true\s*$') {
                throw "Only an explicitly preserved, locally seeded client JAR may omit a downloadable metafile: $relative"
            }
            if (!$seenModPaths.Add($relative)) { throw "Duplicate mod path in Packwiz index: $relative" }
            if ($managedFiles.ContainsKey($relative)) { throw "Duplicate managed client mod path: $relative" }
            $managedFiles[$relative] = $hash.ToLowerInvariant()
            $modCount++
        }
    }
    if ($modCount -lt 1 -or $modCount -gt 512) { throw "Packwiz client mod inventory has an invalid size: $modCount." }
    return [pscustomobject]@{ ModCount = $modCount; ModMetafiles = @((Get-TomlBlocks $indexText) | Where-Object { $_ -match '(?m)^metafile\s*=\s*true\s*$' }).Count; PackTomlSha256 = (Get-Sha256Bytes $packBytes); ManagedFiles = $managedFiles }
}

function Test-KxCraftPack([string]$MinecraftDirectory, [Uri]$PackUri) {
    $packBytes = Get-RemoteBytes $PackUri
    $packTomlSha256 = Get-Sha256Bytes $packBytes
    $packText = Get-StrictUtf8 $packBytes
    if ((Get-TomlString $packText 'pack-format') -ne 'packwiz:1.1.0') { throw 'Unsupported Packwiz format.' }
    if ((Get-TomlString $packText 'minecraft') -ne '1.21.1' -or (Get-TomlString $packText 'neoforge') -ne '21.1.265') {
        throw 'Remote Minecraft/NeoForge versions do not match KxCraft.'
    }
    $indexFile = Get-TomlString $packText 'file'
    $expectedIndexHash = Get-TomlString $packText 'hash'
    if ((Get-TomlString $packText 'hash-format') -ne 'sha256' -or $expectedIndexHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Remote index does not have a valid SHA-256 pin.'
    }
    $indexUri = Get-RelativeUri $PackUri $indexFile
    $indexBytes = Get-RemoteBytes $indexUri
    if ((Get-Sha256Bytes $indexBytes) -ne $expectedIndexHash.ToLowerInvariant()) { throw 'Remote index SHA-256 does not match pack.toml.' }
    $indexText = Get-StrictUtf8 $indexBytes
    if ((Get-TomlString $indexText 'hash-format') -ne 'sha256') { throw 'Remote index hash-format is not sha256.' }
    $entries = Get-TomlBlocks $indexText
    $expectedMods = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $managedFiles = @{}
    $seenModPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($block in $entries) {
        $relative = Get-TomlString $block 'file'
        $expectedHash = Get-TomlString $block 'hash'
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid index hash for $relative" }
        $isMeta = $block -match '(?m)^metafile\s*=\s*true\s*$'
        if ($isMeta) {
            if ($relative -notmatch '^mods/[^/]+\.pw\.toml$') { throw "Non-mod metafile in client manifest: $relative" }
            $metadataUri = Get-RelativeUri $indexUri $relative
            $metadataBytes = Get-RemoteBytes $metadataUri
            if ((Get-Sha256Bytes $metadataBytes) -ne $expectedHash.ToLowerInvariant()) { throw "Mod metadata hash mismatch: $relative" }
            $metadataText = Get-StrictUtf8 $metadataBytes
            if ((Get-TomlString $metadataText 'side') -ne 'client') { throw "Non-client mod side in client manifest: $relative" }
            if ($metadataText -match '(?im)^\[update\]') { throw "Marketplace update source found: $relative" }
            if ((Get-TomlString $metadataText 'hash-format') -ne 'sha256') { throw "Mod file lacks a SHA-256 hash: $relative" }
            $downloadHash = Get-TomlString $metadataText 'hash'
            if ($downloadHash -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid mod SHA-256: $relative" }
            $filename = Get-TomlString $metadataText 'filename'
            if ($relative -cne "mods/$filename.pw.toml") { throw "Mod metafile filename does not match its index path: $relative" }
            Assert-KxCraftImmutableModUrl (Get-TomlString $metadataText 'url') $relative $filename
            $folder = [IO.Path]::GetDirectoryName($relative).Replace('\', '/')
            $installedRelative = if ($folder) { "$folder/$filename" } else { $filename }
            if (!$seenModPaths.Add($installedRelative)) { throw "Duplicate managed client mod path: $installedRelative" }
            $installedPath = Get-LocalPath $MinecraftDirectory $installedRelative
            if (!(Test-Path -LiteralPath $installedPath -PathType Leaf)) { throw "Packwiz left required mod missing: $installedRelative" }
            $actualHash = Get-Sha256File $installedPath
            if ($actualHash -ne $downloadHash.ToLowerInvariant()) { throw "Installed mod failed SHA-256 verification: $installedRelative" }
            if ($managedFiles.ContainsKey($installedRelative)) { throw "Duplicate managed client mod path: $installedRelative" }
            $managedFiles[$installedRelative] = $downloadHash.ToLowerInvariant()
            [void]$expectedMods.Add([IO.Path]::GetFullPath($installedPath))
            continue
        }

        if ($relative -notmatch '^mods/[^/]+\.jar$' -or $block -notmatch '(?m)^preserve\s*=\s*true\s*$') {
            throw "Non-downloadable mod must be a locally seeded JAR marked preserve=true: $relative"
        }
        if (!$seenModPaths.Add($relative)) { throw "Duplicate managed client mod path: $relative" }
        $expectedMods.Add([IO.Path]::GetFullPath((Get-LocalPath $MinecraftDirectory $relative))) | Out-Null
        $localPath = Get-LocalPath $MinecraftDirectory $relative
        if (!(Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Locally seeded mod is missing; this JAR is not yet downloadable: $relative" }
        $actualHash = Get-Sha256File $localPath
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) { throw "Locally seeded mod failed SHA-256 verification: $relative" }
        $managedFiles[$relative] = $expectedHash.ToLowerInvariant()
    }

    if ($expectedMods.Count -lt 1 -or $expectedMods.Count -gt 512) { throw "Post-update client mod count is invalid: $($expectedMods.Count)." }
    return [pscustomobject]@{ ManagedFiles = $managedFiles; PackTomlSha256 = $packTomlSha256; ModCount = $expectedMods.Count }
}

$javaEnvironmentValue = $env:INST_JAVA
if ([string]::IsNullOrWhiteSpace($MinecraftDirectory)) { $MinecraftDirectory = $env:INST_MC_DIR }
if ([string]::IsNullOrWhiteSpace($MinecraftDirectory)) { Stop-Launch 'Prism did not provide INST_MC_DIR and the Bootstrap supplied no Minecraft directory.' }
$minecraftDirectory = [IO.Path]::GetFullPath($MinecraftDirectory)
try { $java = Resolve-KxJavaExecutable $minecraftDirectory $javaEnvironmentValue }
catch { Stop-Launch $_.Exception.Message }
$packUri = $null
if (![Uri]::TryCreate($PackTomlUrl, [UriKind]::Absolute, [ref]$packUri) -or
    $packUri.Scheme -cne 'https' -or $packUri.Host -cne 'francho2002.github.io' -or
    $packUri.AbsolutePath -cne '/kxcraft/pack/KxCraft/pack.toml' -or !$packUri.IsDefaultPort -or
    ![string]::IsNullOrEmpty($packUri.UserInfo) -or ![string]::IsNullOrEmpty($packUri.Query) -or
    ![string]::IsNullOrEmpty($packUri.Fragment) -or $packUri.AbsoluteUri -cne 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml') {
    Stop-Launch 'Only the permanent KxCraft Packwiz URL is accepted.'
}
$bootstrap = Join-Path $minecraftDirectory 'packwiz-installer-bootstrap.jar'
$installer = Join-Path $minecraftDirectory 'packwiz-installer.jar'
if (!(Test-Path -LiteralPath $bootstrap -PathType Leaf)) { Stop-Launch 'Official Packwiz bootstrap JAR is missing from the Prism instance.' }
$bootstrapHash = Get-Sha256File $bootstrap
if ($bootstrapHash -ne $script:BootstrapSha256) { Stop-Launch 'Packwiz bootstrap hash does not match the pinned official v0.0.3 artifact.' }
if (!(Test-Path -LiteralPath $installer -PathType Leaf)) { Stop-Launch 'Pinned official Packwiz installer JAR is missing from the Prism instance.' }
$installerHash = Get-Sha256File $installer
if ($installerHash -ne $script:InstallerSha256) { Stop-Launch 'Packwiz installer hash does not match the pinned official v0.5.14 artifact.' }

try {
    if ($ExpectedPackSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $ExpectedModCount -lt 1 -or $ExpectedModCount -gt 512) { throw 'Bootstrap supplied invalid signed pack pins.' }
    $releaseGate = Get-KxCraftReleaseGate $packUri
    if ($releaseGate.PackTomlSha256 -cne $ExpectedPackSha256.ToLowerInvariant() -or $releaseGate.ModCount -ne $ExpectedModCount) { throw 'Remote Packwiz release does not match the signed updater manifest.' }
    $preflight = Test-KxCraftManifestDownloadUris $packUri
    if ($preflight.PackTomlSha256 -ne $releaseGate.PackTomlSha256) { throw 'pack.toml changed during preflight; refusing to update.' }
    if ($preflight.ModCount -ne $releaseGate.ModCount) { throw 'Release gate modCount does not match the complete seeded mod inventory.' }
    Assert-KxManagedModsBeforePackwiz $minecraftDirectory $packUri.AbsoluteUri $preflight.ManagedFiles
    $bootstrapArguments = @('-jar', $bootstrap, '-g', '--bootstrap-no-update', '--bootstrap-main-jar', $installer, '-s', 'client', $packUri.AbsoluteUri)
    $null = Invoke-KxProcessAndCheckExitCode -FilePath $java -Arguments $bootstrapArguments -WorkingDirectory $minecraftDirectory -Description 'Java launcher for Packwiz bootstrap'

    $packState = [pscustomobject]@{ PackTomlSha256 = $preflight.PackTomlSha256; ModCount = $preflight.ModCount; ManagedFiles = $preflight.ManagedFiles }
    foreach ($relative in $packState.ManagedFiles.Keys) {
        $localPath = Get-LocalPath $minecraftDirectory $relative
        if (!(Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Packwiz left required mod missing: $relative" }
        if ((Get-Sha256File $localPath) -ne [string]$packState.ManagedFiles[$relative]) { throw "Installed mod failed SHA-256 verification: $relative" }
    }
    if ($packState.PackTomlSha256 -ne $releaseGate.PackTomlSha256) { throw 'pack.toml changed during the Packwiz update; refusing to launch.' }
    if ($packState.ModCount -ne $releaseGate.ModCount) { throw 'Installed mod count does not match the release gate; refusing to launch.' }
    $releaseGateAfter = Get-KxCraftReleaseGate $packUri
    if ($releaseGateAfter.PackTomlSha256 -ne $releaseGate.PackTomlSha256 -or $releaseGateAfter.ModCount -ne $releaseGate.ModCount) { throw 'KxCraft release changed during the Packwiz update; refusing to launch.' }
    Update-KxManagedFileState $minecraftDirectory $packUri.AbsoluteUri $packState.ManagedFiles

    $seedHelper = Join-Path $minecraftDirectory 'KxCraft-InitialClientState.ps1'
    $seedManifest = Join-Path $minecraftDirectory 'kxcraft-initial-seed\manifest.json'
    $hasSeedHelper = Test-Path -LiteralPath $seedHelper -PathType Leaf
    $hasSeedManifest = Test-Path -LiteralPath $seedManifest -PathType Leaf
    if ($hasSeedHelper -ne $hasSeedManifest) { throw 'Initial map/config seed is incomplete; restore the original Prism ZIP.' }
    if ($hasSeedManifest) { & $seedHelper -MinecraftDirectory $minecraftDirectory }

    Write-Output 'KxCraft mod SHA-256 checks passed; unchanged managed mods were retained, and obsolete unchanged managed mods were removed. Personal files outside the managed mod list were left untouched. Minecraft may start.'
} catch {
    Stop-Launch $_.Exception.Message
}
