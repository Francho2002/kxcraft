# KxCraft Pages release gate for the temporary seq3 bridge and permanent seq4 channel.
[CmdletBinding()]
param(
    [string]$SiteRoot = 'site',
    [switch]$AllowCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($SiteRoot)
$preManifestPath = Join-Path $root 'updater\manifest.json'
if (!(Test-Path -LiteralPath $preManifestPath -PathType Leaf)) { throw 'Updater manifest is missing.' }
$preManifest = Get-Content -LiteralPath $preManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$preChannelNames = @($preManifest.channels.PSObject.Properties | ForEach-Object { $_.Name })
if ($preManifest.schemaVersion -ne 1 -or $preManifest.state -cne 'PUBLISHED') { throw 'Only a PUBLISHED updater manifest can be deployed.' }
if ([int]$preManifest.sequence -eq 3 -and $preChannelNames.Count -eq 1 -and $preChannelNames[0] -ceq 'managed-3players') {
    $deploymentPhase = 'Bridge'
    $channels = @('managed-3players', 'KxCraft', 'private-3players')
    $primaryChannel = 'managed-3players'
} elseif ([int]$preManifest.sequence -eq 4 -and $preChannelNames.Count -eq 1 -and $preChannelNames[0] -ceq 'KxCraft') {
    $deploymentPhase = 'Final'
    $channels = @('KxCraft')
    $primaryChannel = 'KxCraft'
} else {
    throw 'Pages accepts only the approved seq3 compatibility bridge or seq4 KxCraft-only release.'
}
$publicWebFiles = @(
    'index.html',
    'mods.html',
    'schematics.html',
    'tienda.html',
    'assets/app.js',
    'assets/createmod-previews.js',
    'assets/site.css',
    'assets/schematics.js',
    'assets/store-expiry.js',
    'assets/tienda.js',
    'assets/kxcraft-airship-fortress.jpg',
    'assets/kxcraft-hero-airship.jpg',
    'assets/kxcraft-island-workshop.jpg',
    'assets/kxcraft-jumbo-green-airplane.png',
    'assets/kxcraft-landkreuzer-ratte.png',
    'assets/kxcraft-colonias.jpg',
    'assets/kxcraft-create-guerra.jpg',
    'assets/kxcraft-exploracion.jpg',
    'assets/kxcraft-mark.png'
)

function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-TomlString([string]$Text, [string]$Name) {
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*"(?<value>(?:[^"\\]|\\.)*)"\s*$'
    $m = [regex]::Match($Text, $pattern)
    if (!$m.Success) { throw "Missing TOML string '$Name'." }
    $value = $m.Groups['value'].Value
    if ($value -match '\\(?!["\\nrt])') { throw "Unsupported TOML escape in '$Name'." }
    return $value.Replace('\"', '"').Replace('\\', '\').Replace('\n', [string][char]10).Replace('\r', [string][char]13).Replace('\t', [string][char]9)
}

function Get-TomlBlocks([string]$Text) {
    return @([regex]::Split($Text, '(?m)^\[\[files\]\]\s*$') | Select-Object -Skip 1)
}

function Get-RelativeFile([string]$Base, [string]$Path) {
    $prefix = [IO.Path]::GetFullPath($Base)
    if (!$prefix.EndsWith([IO.Path]::DirectorySeparatorChar)) { $prefix += [IO.Path]::DirectorySeparatorChar }
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escaped site root: $Path" }
    return $full.Substring($prefix.Length).Replace('\', '/')
}

function Assert-AllowedPackPath([string]$Relative, [string]$Channel) {
    if ($Relative -match '(^|/)\.\.?(/|$)' -or $Relative.Contains(':') -or $Relative.StartsWith('/')) {
        throw "Unsafe Packwiz path: $Relative"
    }
    $prefix = '^pack/' + [regex]::Escape($Channel) + '/'
    $subPath = $Relative -replace $prefix, ''
    if ($subPath -match '^(pack\.toml|index\.toml|release\.json)$') { return }
    if ($subPath -match '^mods/[^/]+\.jar\.pw\.toml$') { return }
    if ($subPath -match '^(config|defaultconfigs)/[^/]+\.toml$') { return }
    if ($subPath -ceq 'servers.dat') { return }
    throw "Unexpected public Packwiz path: $Relative"
}

function Get-Provider([string]$Url, [string]$Relative) {
    $uri = $null
    Assert ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) "Invalid download URL: $Relative"
    Assert ($uri.Scheme -ceq 'https' -and $uri.IsDefaultPort -and !$uri.UserInfo -and !$uri.Query -and !$uri.Fragment) "Download URL must be clean HTTPS: $Relative"
    $decoded = [Uri]::UnescapeDataString($uri.AbsolutePath)
    switch -CaseSensitive ($uri.Host.ToLowerInvariant()) {
        'raw.githubusercontent.com' {
            Assert ($decoded -match '^/Francho2002/kxcraft/[0-9a-f]{40}/binaries/mods/(?:\d+\.\d+\.\d+/)?[^/]+\.jar$') "GitHub URL must pin a full KxCraft commit: $Relative"
            return 'github'
        }
        'cdn.modrinth.com' {
            Assert ($decoded -match '^/data/[A-Za-z0-9_-]+/versions/[A-Za-z0-9_-]+/[^/]+\.jar$') "Modrinth URL must be version-pinned: $Relative"
            return 'modrinth'
        }
        { $_ -in @('edge.forgecdn.net', 'mediafilez.forgecdn.net') } {
            Assert ($decoded -match '^/files/[0-9]{1,4}/[0-9]{1,4}/[^/]+\.jar$') "CurseForge URL must be file-pinned: $Relative"
            return 'curseforge'
        }
        default { throw "Unapproved mod source host $($uri.Host): $Relative" }
    }
}

function Test-PackChannel([string]$Channel, [hashtable]$ExpectedFiles) {
    $packRoot = Join-Path $root ('pack\' + $Channel)
    Assert (Test-Path -LiteralPath $packRoot -PathType Container) "Packwiz channel directory is missing: $Channel"
    $packPath = Join-Path $packRoot 'pack.toml'
    $indexPath = Join-Path $packRoot 'index.toml'
    $gatePath = Join-Path $packRoot 'release.json'
    foreach ($path in @($packPath, $indexPath, $gatePath)) { Assert (Test-Path -LiteralPath $path -PathType Leaf) "Required Packwiz control file is missing: $path" }

    $packText = [IO.File]::ReadAllText($packPath)
    $indexText = [IO.File]::ReadAllText($indexPath)
    $gate = Get-Content -LiteralPath $gatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $packVersion = Get-TomlString $packText 'version'
    Assert ($packVersion -match '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') "Pack version is invalid in $Channel."
    Assert ([string]$gate.releaseVersion -ceq $packVersion) "release.json version mismatch in $Channel."
    Assert ((Get-TomlString $packText 'pack-format') -ceq 'packwiz:1.1.0') "Unexpected Packwiz format in $Channel."
    Assert ((Get-TomlString $packText 'minecraft') -ceq '1.21.1') "Unexpected Minecraft version in $Channel."
    Assert ((Get-TomlString $packText 'neoforge') -ceq '21.1.265') "Unexpected NeoForge version in $Channel."
    Assert ((Get-TomlString $packText 'file') -ceq 'index.toml') "pack.toml must reference index.toml in $Channel."
    Assert ((Get-TomlString $packText 'hash-format') -ceq 'sha256') "pack.toml must use SHA-256 in $Channel."
    Assert ((Get-TomlString $indexText 'hash-format') -ceq 'sha256') "index.toml must use SHA-256 in $Channel."
    $indexHash = Get-TomlString $packText 'hash'
    Assert ($indexHash -match '^[0-9a-f]{64}$') "index.toml hash is malformed in $Channel."
    Assert ((Get-Sha256 $indexPath) -ceq $indexHash) "index.toml hash mismatch in $Channel."
    Assert ($gate.schemaVersion -eq 1 -and ($gate.state -ceq 'PUBLISHED' -or ($AllowCandidate -and $gate.state -ceq 'CANDIDATE'))) "Release gate is not PUBLISHED in $Channel."
    Assert ([string]$gate.packTomlUrl -ceq "https://francho2002.github.io/kxcraft/pack/$Channel/pack.toml") "Release gate URL mismatch in $Channel."
    Assert ([string]$gate.packTomlSha256 -ceq (Get-Sha256 $packPath)) "release.json does not pin pack.toml in $Channel."
    Assert ([int]$gate.exactSourceBlockerCount -eq 0 -and [int]$gate.zipSeededPreservedModCount -eq 0) "Release gate contains unresolved or locally preserved mods in $Channel."
    Assert ([string]$gate.rawBinaryCommit -match '^[0-9a-f]{40}$') "Release gate rawBinaryCommit is not immutable in $Channel."
    Assert ([string]$gate.sourceMapSha256 -match '^[0-9a-f]{64}$') "Release gate source-map hash is malformed in $Channel."

    $ExpectedFiles["pack/$Channel/pack.toml"] = $true
    $ExpectedFiles["pack/$Channel/index.toml"] = $true
    $ExpectedFiles["pack/$Channel/release.json"] = $true
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenJars = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $providers = @{ github = 0; modrinth = 0; curseforge = 0 }
    $modCount = 0
    $entries = Get-TomlBlocks $indexText
    Assert ($entries.Count -gt 0) "index.toml has no entries in $Channel."

    foreach ($block in $entries) {
        $relative = Get-TomlString $block 'file'
        Assert-AllowedPackPath ("pack/$Channel/" + $relative) $Channel
        $isMeta = ([regex]::Match($block, '(?m)^metafile\s*=\s*true\s*$')).Success
        Assert ($seen.Add($relative)) "Duplicate Packwiz index path in $Channel`: $relative"
        $entryHash = Get-TomlString $block 'hash'
        Assert ($entryHash -match '^[0-9a-f]{64}$') "Malformed index hash in $Channel`: $relative"
        $entryPath = [IO.Path]::GetFullPath((Join-Path $packRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        $rootPrefix = [IO.Path]::GetFullPath($packRoot)
        if (!$rootPrefix.EndsWith([IO.Path]::DirectorySeparatorChar)) { $rootPrefix += [IO.Path]::DirectorySeparatorChar }
        Assert ($entryPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) "Index path escapes $Channel`: $relative"
        Assert (Test-Path -LiteralPath $entryPath -PathType Leaf) "Missing indexed file in $Channel`: $relative"
        Assert ((Get-Sha256 $entryPath) -ceq $entryHash) "Indexed file hash mismatch in $Channel`: $relative"
        $ExpectedFiles["pack/$Channel/$relative"] = $true

        if (!$isMeta) {
            Assert ($relative -notmatch '^mods/') "Non-metafile mod download is forbidden in $Channel`: $relative"
            continue
        }
        Assert ($relative -match '^mods/[^/]+\.jar\.pw\.toml$') "Unexpected metafile path in $Channel`: $relative"
        $metaText = [IO.File]::ReadAllText($entryPath)
        Assert ((Get-TomlString $metaText 'side') -ceq 'client') "Non-client Packwiz entry in $Channel`: $relative"
        Assert (!(($metaText -match '(?im)^\[update\]\s*$'))) "Marketplace update block is forbidden in $Channel`: $relative"
        Assert ((Get-TomlString $metaText 'hash-format') -ceq 'sha256') "JAR hash format is not SHA-256 in $Channel`: $relative"
        Assert ((Get-TomlString $metaText 'hash') -match '^[0-9a-f]{64}$') "Malformed JAR SHA-256 in $Channel`: $relative"
        $filename = Get-TomlString $metaText 'filename'
        Assert ($filename -match '^[^<>:"/\\|?*]+\.jar$') "Unsafe JAR filename in $Channel`: $relative"
        Assert ($relative -ceq "mods/$filename.pw.toml") "Metafile filename/path mismatch in $Channel`: $relative"
        Assert ($seenJars.Add($filename)) "Duplicate managed JAR filename in $Channel`: $filename"
        $provider = Get-Provider (Get-TomlString $metaText 'url') $relative
        $providers[$provider]++
        $modCount++
    }

    Assert ([int]$gate.modCount -eq $modCount) "Release gate modCount mismatch in $Channel."
    if ($null -ne $gate.PSObject.Properties['indexEntryCount']) { Assert ([int]$gate.indexEntryCount -eq $entries.Count) "Release gate indexEntryCount mismatch in $Channel." }
    Assert (($providers.github + $providers.modrinth + $providers.curseforge) -eq $modCount) "Some managed mod source is uncounted in $Channel."
    Assert ([int]$gate.downloadableGitHubModCount -eq $providers.github -and [int]$gate.downloadableModrinthModCount -eq $providers.modrinth -and [int]$gate.downloadableCurseForgeModCount -eq $providers.curseforge) "Provider counts mismatch in $Channel."

    $unindexed = @(Get-ChildItem -LiteralPath $packRoot -Recurse -File | ForEach-Object { Get-RelativeFile $packRoot $_.FullName } | Where-Object { $_ -notin @('pack.toml','index.toml','release.json') -and !$seen.Contains($_) })
    Assert ($unindexed.Count -eq 0) "Unindexed file(s) in Packwiz channel $Channel`: $($unindexed -join ', ')"
    return [pscustomobject]@{ Name=$Channel; Version=$packVersion; Mods=$modCount; Entries=$entries.Count; Providers=$providers; Gate=$gate }
}

Assert (Test-Path -LiteralPath $root -PathType Container) 'Pages site root is missing.'
foreach ($required in $publicWebFiles) { Assert (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf) "Required public web file is missing: $required" }
$allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
foreach ($file in $allFiles) { Assert (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Symlink/reparse point is forbidden in Pages content: $($file.FullName)" }
$actual = @($allFiles | ForEach-Object { Get-RelativeFile $root $_.FullName } | Sort-Object -Culture 'en-US')
$expected = @{}
foreach ($path in $publicWebFiles) { $expected[$path] = $true }
foreach ($path in @('updater/manifest.json','updater/manifest.sig')) { $expected[$path] = $true }

foreach ($path in $actual) {
    Assert ($path -notmatch '(?i)(^|/)(\.env|.*\.key|.*\.p12|.*\.pem)$') "Private/secret-like file is forbidden in Pages: $path"
    Assert ($path -notmatch '(?i)\.(jar|zip|mca|nbt)$') "Binary/world archive is forbidden in Pages: $path"
    if ($path -notin $publicWebFiles -and $path -notin @('updater/manifest.json','updater/manifest.sig')) {
        $prefixChannel = $null
        foreach ($channel in $channels) { if ($path.StartsWith("pack/$channel/",[StringComparison]::OrdinalIgnoreCase)) { $prefixChannel = $channel; break } }
        Assert ($null -ne $prefixChannel) "Unexpected public file: $path"
        Assert-AllowedPackPath $path $prefixChannel
    }
}

$channelResults = @{}
foreach ($channel in $channels) { $channelResults[$channel] = Test-PackChannel $channel $expected }
$primary = $channelResults[$primaryChannel]
if ($deploymentPhase -eq 'Bridge') {
    foreach ($alias in @('KxCraft', 'private-3players')) {
        $aliasResult = $channelResults[$alias]
        Assert ($aliasResult.Version -ceq $primary.Version -and $aliasResult.Mods -eq $primary.Mods -and $aliasResult.Entries -eq $primary.Entries) "Temporary bridge alias $alias is out of sync with the seq3 Packwiz snapshot."
        $primaryIndexHash = Get-Sha256 (Join-Path $root 'pack\managed-3players\index.toml')
        $aliasIndexHash = Get-Sha256 (Join-Path $root ("pack\{0}\index.toml" -f $alias))
        Assert ($aliasIndexHash -ceq $primaryIndexHash) "Temporary bridge alias $alias does not match the seq3 Packwiz index."
    }
    Assert ($primary.Version -ceq '1.0.11' -and $primary.Mods -eq 199) 'The seq3 bridge must preserve the verified 1.0.11/199 snapshot.'
} else {
    Assert ($primary.Version -ceq '1.0.12' -and $primary.Mods -eq 201) 'The final channel must be KxCraft 1.0.12/201.'
}
$manifestPath = Join-Path $root 'updater\manifest.json'
$signaturePath = Join-Path $root 'updater\manifest.sig'
$publicKeyPath = Join-Path $PSScriptRoot 'kxcraft-updater-public-key.spki.base64'
foreach ($path in @($manifestPath,$signaturePath,$publicKeyPath)) { Assert (Test-Path -LiteralPath $path -PathType Leaf) "Updater publication file is missing: $path" }
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$manifest = [Text.UTF8Encoding]::new($false,$true).GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
$signatureBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($signaturePath)).Trim())
$keyBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($publicKeyPath)).Trim())
$rsa = [Security.Cryptography.RSA]::Create()
try {
    $read = 0
    $rsa.ImportSubjectPublicKeyInfo($keyBytes,[ref]$read)
    Assert ($read -eq $keyBytes.Length) 'Updater public key contains unexpected trailing bytes.'
    Assert ($rsa.VerifyData($manifestBytes,$signatureBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'Updater manifest RSA signature is invalid.'
} finally { $rsa.Dispose() }
Assert ($manifest.schemaVersion -eq 1 -and $manifest.state -ceq 'PUBLISHED') 'Updater manifest is not PUBLISHED.'
Assert ([string]$manifest.updaterVersion -match '^\d+\.\d+\.\d+$') 'Updater version is malformed.'
Assert ([int]$manifest.sequence -ge 1) 'Updater sequence is invalid.'
Assert ([string]$manifest.bundle.url -match ('^https://raw\.githubusercontent\.com/Francho2002/kxcraft/[0-9a-f]{40}/distribution-v1/updater/releases/' + [regex]::Escape([string]$manifest.updaterVersion) + '/KxCraft-Updater\.zip$')) 'Updater bundle URL is not pinned to a complete immutable Git commit and its declared version.'
Assert ([long]$manifest.bundle.length -gt 0 -and [string]$manifest.bundle.sha256 -match '^[0-9a-f]{64}$') 'Updater bundle integrity metadata is invalid.'
Assert (@($manifest.files).Count -eq 2) 'Updater manifest must contain exactly two updater files.'
foreach ($file in $manifest.files) { Assert ([string]$file.path -in @('KxCraft-Updater.ps1','KxCraft-ManagedFiles.ps1') -and [long]$file.length -gt 0 -and [string]$file.sha256 -match '^[0-9a-f]{64}$') 'Updater component pin is malformed.' }
$manifestChannelNames = @($manifest.channels.PSObject.Properties | ForEach-Object { $_.Name })
Assert ($manifestChannelNames.Count -eq 1 -and $manifestChannelNames[0] -ceq $primaryChannel) 'Updater manifest contains an unexpected channel.'
$signedChannel = $manifest.channels.PSObject.Properties[$primaryChannel].Value
if ($AllowCandidate -and [string]$primary.Gate.state -ceq 'CANDIDATE') {
    Assert ($null -ne $signedChannel -and [string]$signedChannel.packVersion -match '^\d+\.\d+\.\d+$' -and [string]$signedChannel.packTomlUrl -ceq [string]$primary.Gate.packTomlUrl -and [string]$signedChannel.packTomlSha256 -match '^[0-9a-f]{64}$' -and [int]$signedChannel.modCount -gt 0) 'The signed updater manifest does not pin a valid prior published channel for this candidate.'
    Assert ([version][string]$signedChannel.packVersion -lt [version][string]$primary.Version) 'A candidate must advance beyond the still-published signed Packwiz version.'
} else {
    Assert ($null -ne $signedChannel -and [string]$signedChannel.packVersion -ceq $primary.Version -and [string]$signedChannel.packTomlUrl -ceq [string]$primary.Gate.packTomlUrl -and [string]$signedChannel.packTomlSha256 -ceq [string]$primary.Gate.packTomlSha256 -and [int]$signedChannel.modCount -eq $primary.Mods) 'Updater signature does not pin the exact published managed Packwiz channel.'
}
$expected['updater/manifest.json'] = $true
$expected['updater/manifest.sig'] = $true
Assert ($actual.Count -eq $expected.Count) "Pages tree has $($actual.Count) files; allowlist expects $($expected.Count)."
foreach ($path in $actual) { Assert $expected.ContainsKey($path) "Unexpected public file: $path" }
foreach ($path in $expected.Keys) { Assert ($actual -contains $path) "Expected public file is missing: $path" }

$html = [IO.File]::ReadAllText((Join-Path $root 'index.html'))
$packagePanels = [regex]::Matches($html,'(?is)<article\b(?=[^>]*\bkx-play-panel--pack\b)[^>]*>.*?</article>')
Assert ($packagePanels.Count -eq 1) 'The public page must contain exactly one KxCraft package panel.'
$packagePanel = $packagePanels[0].Value
$packageGate = $primary.Gate
$packageVersion = [string]$packageGate.packageVersion
$packageHash = [string]$packageGate.packageSha256
$packageUrl = [string]$packageGate.packageUrl
$latestImportUrl = 'https://github.com/Francho2002/kxcraft/releases/latest/download/KxCraft.zip'
Assert ([string]$packageGate.packageFileName -ceq 'KxCraft.zip' -and [long]$packageGate.packageLength -gt 0 -and $packageHash -match '^[0-9a-f]{64}$') 'The KxCraft ZIP release metadata is incomplete.'
Assert ($packageVersion -match ('^'+[regex]::Escape([string]$primary.Version)+'(?: · Hotfix [0-9]+)?$')) 'The KxCraft ZIP package version does not match the Packwiz version.'
Assert ($packageUrl -match ('^https://github\.com/Francho2002/kxcraft/releases/download/kxc-'+[regex]::Escape([string]$primary.Version)+'-(?:final|hotfix[0-9]+)/KxCraft\.zip$')) 'The KxCraft ZIP metadata must point to an immutable versioned release asset.'
Assert ([regex]::Matches($packagePanel,'(?is)<input\b(?=[^>]*\bid="kxcraft-import-url")(?=[^>]*\btype="url")(?=[^>]*\bvalue="'+[regex]::Escape($latestImportUrl)+'")(?=[^>]*\breadonly\b)[^>]*>').Count -eq 1) 'The page must show the exact read-only latest ZIP URL for Prism import.'
Assert ($packagePanel -notmatch '(?is)<button\b') 'The import panel must not contain a separate copy button.'
Assert ([regex]::Matches($packagePanel,'(?is)<p\b[^>]*id="kxcraft-copy-status"[^>]*aria-live="polite"').Count -eq 1) 'The page must provide accessible copy confirmation and fallback status.'
Assert ($packagePanel -notmatch '(?is)<a\b[^>]*href="[^"]*KxCraft\.zip') 'Manual ZIP download links are not allowed in the installation panel.'
$visibleVersion = [regex]::Match($packagePanel,'(?is)<span\s+data-kx-package-version>(?<value>[^<]+)</span>')
Assert ($visibleVersion.Success -and [Net.WebUtility]::HtmlDecode($visibleVersion.Groups['value'].Value) -ceq [string]$primary.Version) 'Visible package version must show the base Packwiz version.'
Assert ([regex]::Matches($packagePanel,'(?is)<li\b').Count -eq 3) 'Step 02 must contain exactly three instructions.'
Assert ($packagePanel -notmatch '(?i)Hotfix') 'Hotfix labels must not appear in the public package panel.'
Assert ([regex]::Matches($packagePanel,'(?is)<code\s+data-kx-package-sha256>'+[regex]::Escape($packageHash)+'</code>').Count -eq 1) 'Visible package SHA-256 differs from release.json.'
foreach ($instruction in @('Abrí PrismLauncher.','Add Instance → Importar','Pegá el enlace que está debajo y pulsá OK.')) { Assert ($packagePanel.Contains($instruction)) "Prism import instruction is missing: $instruction" }
Assert ([regex]::Matches($packagePanel,'(?is)<label\b[^>]*for="kxcraft-import-url">Enlace directo del modpack</label>').Count -eq 1) 'The import field label must identify the KxCraft modpack.'
Assert ($packagePanel -notmatch '(?is)kx-panel-update-note|El modpack se actualizará automáticamente al iniciar el juego\.') 'The unwanted upper-corner auto-update notice must be removed.'
Assert ($packagePanel -notmatch '(?is)<p\b[^>]*kx-auto-update-note|Todos los mods se descargarán y actualizarán automáticamente al iniciar el juego\.') 'The standalone auto-update paragraph must be removed.'
$appJs = [IO.File]::ReadAllText((Join-Path $root 'assets/app.js'))
Assert ($appJs.Contains('input.addEventListener("click"') -and $appJs.Contains('event.key === "Enter"') -and $appJs.Contains('event.code === "Space"')) 'The URL field must copy on click, Enter and Space.'
Assert ($appJs.Contains('navigator.clipboard.writeText(input.value)') -and $appJs.Contains('input.select()') -and $appJs.Contains('¡Enlace copiado!')) 'URL clipboard copy and manual selection fallback are required.'
Assert ($html -match 'PrismLauncher-Cracked/releases/download/11\.1\.1/PrismLauncher-Windows-MinGW-w64-Setup-11\.1\.1\.exe') 'The PrismLauncher download in step 01 is missing.'
Assert ($html -notmatch 'Descargá KxCraft\.zip e importalo|Descargar KxCraft\.zip') 'The old manual KxCraft ZIP download flow remains.'
Assert ($html -notmatch '(?i)KxCraft(?:[- ]Lite|[- ]Full|[- ]Migrator)|migrador|migración|private-3players|KxCraft-FULL') 'Retired Lite/Full/migrator distribution text remains on the public page.'

Write-Output ("PASS: Pages $deploymentPhase release; channel=$primaryChannel version=$($primary.Version) mods=$($primary.Mods) entries=$($primary.Entries); signed Updater, package version/hash, latest import URL, clickable keyboard-accessible URL and no manual download checks passed.")
