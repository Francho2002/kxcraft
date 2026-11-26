# KxCraft Pages release gate. Validates the single signed Packwiz channel and
# rejects retired package choices or migration instructions from the public site.
[CmdletBinding()]
param(
    [string]$SiteRoot = 'site',
    [switch]$AllowCandidate,
    [string]$PublicSourceHtmlPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($SiteRoot)
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$channels = @('KxCraft')
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

function Get-KxPackagePanelHtml([string]$Html, [string]$SourceName) {
    $matches = [regex]::Matches($Html,'(?is)<article\b(?=[^>]*\bkx-play-panel--pack\b)[^>]*>.*?</article>')
    Assert ($matches.Count -eq 1) "$SourceName must contain exactly one KxCraft package panel."
    return $matches[0].Value
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
            $githubPath = [regex]::Match($decoded, '^/Francho2002/kxcraft/[0-9a-f]{40}/binaries/mods/(?:[0-9]+\.[0-9]+\.[0-9]+/)?(?<filename>[^/]+\.jar)$')
            $expectedFilename = [IO.Path]::GetFileName($Relative) -replace '\.pw\.toml$', ''
            Assert ($githubPath.Success -and $githubPath.Groups['filename'].Value -ceq $expectedFilename) "GitHub URL must pin a full KxCraft commit and the exact JAR filename: $Relative"
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
    Assert ((Get-TomlString $packText 'name') -ceq 'KxCraft') 'Packwiz pack.toml must identify the only KxCraft pack.'
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
    Assert ([string]$gate.packTomlUrl -ceq 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml') 'release.json changed the permanent KxCraft Packwiz URL.'
    Assert ([string]$gate.packTomlSha256 -ceq (Get-Sha256 $packPath)) "release.json does not pin pack.toml in $Channel."
    $packageVersion = if ($gate.PSObject.Properties['packageVersion'] -and ![string]::IsNullOrWhiteSpace([string]$gate.packageVersion)) { [string]$gate.packageVersion } else { $packVersion }
    Assert ($packageVersion -match '^\d+\.\d+\.\d+$') "release.json packageVersion is invalid in $Channel."
    $expectedPackageUrls = @(
        ('https://github.com/Francho2002/kxcraft/releases/download/kxc-' + $packageVersion + '/KxCraft.zip'),
        ('https://github.com/Francho2002/kxcraft/releases/download/kxc-' + $packageVersion + '-final/KxCraft.zip')
    )
    Assert ([string]$gate.packageFileName -ceq 'KxCraft.zip' -and [long]$gate.packageLength -gt 0 -and [string]$gate.packageSha256 -match '^[0-9a-f]{64}$' -and [string]$gate.packageUrl -cin $expectedPackageUrls) "release.json must pin the exact KxCraft.zip version, byte length, SHA-256 and immutable release URL in $Channel."
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
$packParent = Join-Path $root 'pack'
Assert (Test-Path -LiteralPath $packParent -PathType Container) 'Pages pack directory is missing.'
$packChildren = @(Get-ChildItem -LiteralPath $packParent -Force)
Assert ($packChildren.Count -eq 1 -and $packChildren[0].PSIsContainer -and $packChildren[0].Name -ceq 'KxCraft') 'Only site/pack/KxCraft/ may exist; alternate channels and root files are rejected.'
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

$manifestPath = Join-Path $root 'updater\manifest.json'
$signaturePath = Join-Path $root 'updater\manifest.sig'
$publicKeyPath = Join-Path $PSScriptRoot 'kxcraft-updater-public-key.spki.base64'
$bootstrapPath = Join-Path $projectRoot 'tools\distribution\KxCraft-Bootstrap.ps1'
foreach ($path in @($manifestPath,$signaturePath,$publicKeyPath,$bootstrapPath)) { Assert (Test-Path -LiteralPath $path -PathType Leaf) "Updater publication file is missing: $path" }
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$manifest = [Text.UTF8Encoding]::new($false,$true).GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
$signatureBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($signaturePath)).Trim())
$publicKeyText = [IO.File]::ReadAllText($publicKeyPath).Trim()
$bootstrapText = [IO.File]::ReadAllText($bootstrapPath)
$bootstrapKeyPattern = '(?m)^\$script:TrustedPublicKeyCspBase64\s*=\s*''(?<key>[A-Za-z0-9+/=]+)''\s*$'
$bootstrapKeyMatch = [regex]::Match($bootstrapText,$bootstrapKeyPattern)
Assert ($bootstrapKeyMatch.Success) 'The Bootstrap RSA trust key is missing or malformed.'
$keyBytes = [Convert]::FromBase64String($publicKeyText)
$bootstrapKeyBytes = [Convert]::FromBase64String($bootstrapKeyMatch.Groups['key'].Value)
Assert ($bootstrapKeyBytes.Length -ge 20 -and $bootstrapKeyBytes[0] -eq 6 -and $bootstrapKeyBytes[1] -eq 2 -and [Text.Encoding]::ASCII.GetString($bootstrapKeyBytes,8,4) -ceq 'RSA1') 'The Bootstrap CSP trust key is not a supported RSA public-key blob.'
$modulusLength = [int]([BitConverter]::ToUInt32($bootstrapKeyBytes,12) / 8)
Assert ($modulusLength -gt 0 -and $bootstrapKeyBytes.Length -eq 20 + $modulusLength) 'The Bootstrap CSP trust key has an invalid modulus length.'
$trustedModulus = [byte[]]$bootstrapKeyBytes[20..($bootstrapKeyBytes.Length - 1)]
[Array]::Reverse($trustedModulus)
$trustedExponent = [BitConverter]::GetBytes([BitConverter]::ToUInt32($bootstrapKeyBytes,16))
[Array]::Reverse($trustedExponent)
while ($trustedExponent.Length -gt 1 -and $trustedExponent[0] -eq 0) { $trustedExponent = [byte[]]$trustedExponent[1..($trustedExponent.Length - 1)] }
$trustedParameters = [Security.Cryptography.RSAParameters]::new()
$trustedParameters.Modulus = $trustedModulus
$trustedParameters.Exponent = $trustedExponent
$rsa = [Security.Cryptography.RSA]::Create()
$trustedRsa = [Security.Cryptography.RSA]::Create()
try {
    $read = 0
    $rsa.ImportSubjectPublicKeyInfo($keyBytes,[ref]$read)
    Assert ($read -eq $keyBytes.Length) 'Updater SPKI public key contains unexpected trailing bytes.'
    $trustedRsa.ImportParameters($trustedParameters)
    $signerParameters = $rsa.ExportParameters($false)
    $bootstrapParameters = $trustedRsa.ExportParameters($false)
    Assert ([Convert]::ToBase64String($signerParameters.Modulus) -ceq [Convert]::ToBase64String($bootstrapParameters.Modulus) -and [Convert]::ToBase64String($signerParameters.Exponent) -ceq [Convert]::ToBase64String($bootstrapParameters.Exponent)) 'The Bootstrap trust key and published RSA verification key differ.'
    Assert ($rsa.VerifyData($manifestBytes,$signatureBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'Updater manifest RSA signature is invalid.'
} finally { $rsa.Dispose(); $trustedRsa.Dispose() }
Assert ($manifest.schemaVersion -eq 1 -and $manifest.state -ceq 'PUBLISHED') 'Updater manifest is not PUBLISHED.'
Assert ([string]$manifest.updaterVersion -match '^\d+\.\d+\.\d+$') 'Updater version is malformed.'
Assert ([int]$manifest.sequence -ge 1) 'Updater sequence is invalid.'
Assert ([string]$manifest.bundle.url -match ('^https://raw\.githubusercontent\.com/Francho2002/kxcraft/[0-9a-f]{40}/distribution-v1/updater/releases/' + [regex]::Escape([string]$manifest.updaterVersion) + '/KxCraft-Updater\.zip$')) 'Updater bundle URL is not pinned to a complete immutable Git commit and its declared version.'
Assert ([long]$manifest.bundle.length -gt 0 -and [string]$manifest.bundle.sha256 -match '^[0-9a-f]{64}$') 'Updater bundle integrity metadata is invalid.'
Assert (@($manifest.files).Count -eq 2) 'Updater manifest must contain exactly two updater files.'
foreach ($file in $manifest.files) { Assert ([string]$file.path -in @('KxCraft-Updater.ps1','KxCraft-ManagedFiles.ps1') -and [long]$file.length -gt 0 -and [string]$file.sha256 -match '^[0-9a-f]{64}$') 'Updater component pin is malformed.' }
$channelProperties = @($manifest.channels.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
Assert ($channelProperties.Count -eq 1 -and $channelProperties[0].Name -ceq 'KxCraft') 'Signed Updater manifest must contain exactly the permanent KxCraft channel.'
$kxcraft = $channelResults['KxCraft']
$signedChannel = $manifest.channels.KxCraft
if ($AllowCandidate -and [string]$kxcraft.Gate.state -ceq 'CANDIDATE') {
    Assert ($null -ne $signedChannel -and [string]$signedChannel.packVersion -match '^\d+\.\d+\.\d+$' -and [string]$signedChannel.packTomlUrl -ceq [string]$kxcraft.Gate.packTomlUrl -and [string]$signedChannel.packTomlSha256 -match '^[0-9a-f]{64}$' -and [int]$signedChannel.modCount -gt 0) 'The signed updater manifest does not pin a valid prior published KxCraft Packwiz channel.'
    Assert ([version][string]$signedChannel.packVersion -lt [version][string]$kxcraft.Version) 'A candidate must advance beyond the still-published signed KxCraft version.'
} else {
    Assert ($null -ne $signedChannel -and [string]$signedChannel.packVersion -ceq $kxcraft.Version -and [string]$signedChannel.packTomlUrl -ceq [string]$kxcraft.Gate.packTomlUrl -and [string]$signedChannel.packTomlSha256 -ceq [string]$kxcraft.Gate.packTomlSha256 -and [int]$signedChannel.modCount -eq $kxcraft.Mods) 'Updater signature does not pin the exact published KxCraft Packwiz channel.'
}
$expected['updater/manifest.json'] = $true
$expected['updater/manifest.sig'] = $true
Assert ($actual.Count -eq $expected.Count) "Pages tree has $($actual.Count) files; allowlist expects $($expected.Count)."
foreach ($path in $actual) { Assert $expected.ContainsKey($path) "Unexpected public file: $path" }
foreach ($path in $expected.Keys) { Assert ($actual -contains $path) "Expected public file is missing: $path" }

$html = [IO.File]::ReadAllText((Join-Path $root 'index.html'))
$assetVersion = [string]$kxcraft.Version
$assetPackageVersion = if ($kxcraft.Gate.PSObject.Properties['packageVersion'] -and ![string]::IsNullOrWhiteSpace([string]$kxcraft.Gate.packageVersion)) { [string]$kxcraft.Gate.packageVersion } else { $assetVersion }
$expectedReleaseUrls = @(
    ('https://github.com/Francho2002/kxcraft/releases/download/kxc-' + $assetPackageVersion + '/KxCraft.zip'),
    ('https://github.com/Francho2002/kxcraft/releases/download/kxc-' + $assetPackageVersion + '-final/KxCraft.zip')
)
$expectedReleaseUrl = [string]$kxcraft.Gate.packageUrl
$packagePanel = Get-KxPackagePanelHtml $html 'Public index.html'
Assert ($expectedReleaseUrl -cin $expectedReleaseUrls) 'release.json must pin the immutable versioned KxCraft.zip asset.'
$importUrl = 'https://github.com/Francho2002/kxcraft/releases/latest/download/KxCraft.zip'
$visibleImportUrl = '(?is)<span\b(?=[^>]*\bid="kxcraft-import-url")(?=[^>]*\bclass="[^"]*\bkx-import-url\b[^"]*")[^>]*>\s*' + [regex]::Escape($importUrl) + '\s*</span>'
$copyButton = '(?is)<button\b(?=[^>]*\bid="kxcraft-copy-button")(?=[^>]*\btype="button")[^>]*>'
Assert ([regex]::Matches($packagePanel,$visibleImportUrl).Count -eq 1 -and [regex]::Matches($packagePanel,$copyButton).Count -eq 1 -and $packagePanel -notmatch '(?is)<a\b[^>]*href="[^"]*KxCraft\.zip') 'The package panel must expose the exact latest ZIP import URL and one copy button, without a manual ZIP download link.'
$displayedPackageHashes = [regex]::Matches($packagePanel,'(?is)<code\b(?=[^>]*\bdata-kx-package-sha256\b)[^>]*>(?<sha>[0-9a-f]{64})</code>')
Assert ($displayedPackageHashes.Count -eq 1 -and $displayedPackageHashes[0].Groups['sha'].Value.ToLowerInvariant() -ceq [string]$kxcraft.Gate.packageSha256) 'The public page must display the exact SHA-256 pinned for KxCraft.zip.'
Assert ([regex]::Matches($packagePanel,$copyButton).Count -eq 1) 'The page must contain exactly one KxCraft import copy control.'
Assert ($html -notmatch '(?i)KxCraft(?:[- ]Lite|[- ]Full|[- ]Migrator)|migrador|migraci\u00F3n|KxCraft-FULL') 'Retired Lite/Full/migrator distribution text remains on the public page.'
Assert ($html -match 'Los mods se descargar\u00E1n y actualizar\u00E1n autom\u00E1ticamente\.') 'The public installation instructions do not describe the automatic Packwiz flow.'

$retiredChannelTokens = @(('private-' + '3players'), ('managed-' + '3players'))
$permanentPackTomlUrl = 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml'
$routePinnedFiles = @(
    'tools/distribution/KxCraft-Bootstrap.ps1',
    'tools/distribution/updater/KxCraft-Updater.ps1',
    'tools/distribution/updater/Sign-KxCraftUpdaterPublishedManifest.ps1',
    'tools/distribution/Build-KxCraftSelfUpdatingPackages.ps1',
    'tools/distribution/Publicar-KxCraft.ps1'
)
$activeDistributionFiles = @($routePinnedFiles + @(
    '.github/scripts/kxcraft-updater-public-key.spki.base64',
    'web/public/index.html'
) | Select-Object -Unique)
foreach ($relative in $activeDistributionFiles) {
    $path = Join-Path $projectRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
    Assert (Test-Path -LiteralPath $path -PathType Leaf) "Active KxCraft distribution source is missing: $relative"
    $text = [IO.File]::ReadAllText($path)
    foreach ($retired in $retiredChannelTokens) { Assert (!$text.Contains($retired)) "Retired Packwiz path remains in active source: $relative" }
}
foreach ($relative in $routePinnedFiles) {
    $path = Join-Path $projectRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
    Assert (Test-Path -LiteralPath $path -PathType Leaf) "Permanent KxCraft route source is missing: $relative"
    Assert ([IO.File]::ReadAllText($path).Contains($permanentPackTomlUrl)) "Permanent KxCraft Packwiz URL changed or is missing from: $relative"
}
$sourceHtmlPath = if ([string]::IsNullOrWhiteSpace($PublicSourceHtmlPath)) { Join-Path $projectRoot 'web\public\index.html' } else { [IO.Path]::GetFullPath($PublicSourceHtmlPath) }
Assert (Test-Path -LiteralPath $sourceHtmlPath -PathType Leaf) 'Public HTML source path is missing.'
$sourceHtml = [IO.File]::ReadAllText($sourceHtmlPath)
$sourcePackagePanel = Get-KxPackagePanelHtml $sourceHtml 'Public HTML source'
$expectedReleaseUrl = [string]$kxcraft.Gate.packageUrl
Assert ($expectedReleaseUrl -cin $expectedReleaseUrls -and [regex]::Matches($sourcePackagePanel,$visibleImportUrl).Count -eq 1 -and [regex]::Matches($sourcePackagePanel,$copyButton).Count -eq 1 -and $sourcePackagePanel -notmatch '(?is)<a\b[^>]*href="[^"]*KxCraft\.zip') 'The KxCraft package panel in source HTML must expose the latest ZIP import URL and a copy button while release.json pins its immutable asset.'
$sourceHashes = [regex]::Matches($sourcePackagePanel,'(?is)<code\b(?=[^>]*\bdata-kx-package-sha256\b)[^>]*>(?<sha>[0-9a-f]{64})</code>')
Assert ($sourceHashes.Count -eq 1 -and $sourceHashes[0].Groups['sha'].Value.ToLowerInvariant() -ceq [string]$kxcraft.Gate.packageSha256) 'The public HTML source SHA-256 must match the KxCraft.zip release gate.'
Write-Output ("PASS: Pages allowlist; one permanent KxCraft channel=$($kxcraft.Version)/$($kxcraft.Mods); index entries=$($kxcraft.Entries); RSA signature, immutable Updater pin, exclusive KxCraft URL, latest ZIP import URL/copy button, retired-channel exclusion and SHA-256 checks passed.")
