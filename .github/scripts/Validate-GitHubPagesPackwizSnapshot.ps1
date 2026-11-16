# Source baseline: Francho2002/kxcraft/.github/scripts/Validate-GitHubPagesPackwizSnapshot.ps1
# Adapted for dynamic Packwiz releases; keep security gates tied to actual content.
[CmdletBinding()]
param(
    [string]$SiteRoot = 'site',
    [switch]$AllowCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($SiteRoot)
$packRoot = Join-Path $root 'pack\private-3players'

function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Assert-AllowedPackPath([string]$Relative) {
    if ($Relative -match '(^|/)\.\.?(/|$)' -or $Relative.Contains(':') -or $Relative.StartsWith('/')) {
        throw "Unsafe Packwiz path: $Relative"
    }
    if ($Relative -match '^pack/private-3players/(pack\.toml|index\.toml|release\.json)$') { return }
    if ($Relative -match '^pack/private-3players/mods/[^/]+\.jar\.pw\.toml$') { return }
    if ($Relative -match '^pack/private-3players/(config|defaultconfigs)/[^/]+\.toml$') { return }
    if ($Relative -ceq 'pack/private-3players/servers.dat') { return }
    throw "Unexpected public Packwiz path: $Relative"
}

Assert (Test-Path -LiteralPath $packRoot -PathType Container) 'Packwiz snapshot directory is missing.'
foreach ($required in @('index.html', 'assets/app.js', 'assets/site.css')) {
    Assert (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf) "Required public web file is missing: $required"
}

$allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
foreach ($file in $allFiles) {
    Assert (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Symlink/reparse point is forbidden in Pages content: $($file.FullName)"
}
$actual = @($allFiles | ForEach-Object { Get-RelativeFile $root $_.FullName } | Sort-Object -Culture 'en-US')
foreach ($path in $actual) {
    Assert ($path -notmatch '(?i)(^|/)(\.env|.*\.key|.*\.p12|.*\.pem)$') "Private/secret-like file is forbidden: $path"
    Assert ($path -notmatch '(?i)\.(jar|zip|mca|nbt)$') "Binary/world archive is forbidden in Pages: $path"
    if ($path -ceq 'pack/private-3players/servers.dat') { continue }
    if ($path -notin @('index.html', 'assets/app.js', 'assets/site.css')) { Assert-AllowedPackPath $path }
}

$packPath = Join-Path $packRoot 'pack.toml'
$indexPath = Join-Path $packRoot 'index.toml'
$gatePath = Join-Path $packRoot 'release.json'
foreach ($path in @($packPath, $indexPath, $gatePath)) { Assert (Test-Path -LiteralPath $path -PathType Leaf) "Required Packwiz control file missing: $path" }

$packText = [IO.File]::ReadAllText($packPath)
$indexText = [IO.File]::ReadAllText($indexPath)
$gate = Get-Content -LiteralPath $gatePath -Raw | ConvertFrom-Json
$packVersion = Get-TomlString $packText 'version'
$releaseVersion = [string]$gate.releaseVersion
Assert ($packVersion -match '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') "Pack version is not a valid version string: $packVersion"
Assert ($releaseVersion -ceq $packVersion) 'release.json version does not match pack.toml.'
Assert ((Get-TomlString $packText 'pack-format') -ceq 'packwiz:1.1.0') 'Unexpected Packwiz format.'
Assert ((Get-TomlString $packText 'minecraft') -ceq '1.21.1') 'Unexpected Minecraft version.'
Assert ((Get-TomlString $packText 'neoforge') -ceq '21.1.265') 'Unexpected NeoForge version.'
Assert ((Get-TomlString $packText 'file') -ceq 'index.toml') 'pack.toml must reference index.toml.'
Assert ((Get-TomlString $packText 'hash-format') -ceq 'sha256') 'pack.toml index hash format must be SHA-256.'
Assert ((Get-TomlString $indexText 'hash-format') -ceq 'sha256') 'index.toml must use SHA-256.'

$indexHash = Get-TomlString $packText 'hash'
Assert ($indexHash -match '^[0-9a-f]{64}$') 'index.toml hash is malformed.'
Assert ((Get-Sha256 $indexPath) -ceq $indexHash) 'index.toml SHA-256 does not match pack.toml.'
Assert ($gate.schemaVersion -eq 1 -and ($gate.state -ceq 'PUBLISHED' -or ($AllowCandidate -and $gate.state -ceq 'CANDIDATE'))) 'Release gate is not PUBLISHED (candidate validation is opt-in only for local review).'
Assert ($gate.packTomlUrl -ceq 'https://francho2002.github.io/kxcraft/pack/private-3players/pack.toml') 'Release gate manifest URL mismatch.'
Assert ($gate.packTomlSha256 -ceq (Get-Sha256 $packPath)) 'release.json does not pin pack.toml.'
Assert ($gate.exactSourceBlockerCount -eq 0 -and $gate.zipSeededPreservedModCount -eq 0) 'Release gate reports unresolved or locally preserved mods.'
Assert ($gate.rawBinaryCommit -match '^[0-9a-f]{40}$') 'Release gate rawBinaryCommit is not a full immutable SHA.'
Assert ($gate.sourceMapSha256 -match '^[0-9a-f]{64}$') 'Release gate source-map hash is malformed.'

$entries = Get-TomlBlocks $indexText
Assert ($entries.Count -gt 0) 'index.toml has no entries.'
$expected = @{
    'index.html' = $true
    'assets/app.js' = $true
    'assets/site.css' = $true
    'pack/private-3players/pack.toml' = $true
    'pack/private-3players/index.toml' = $true
    'pack/private-3players/release.json' = $true
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$seenJars = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$providers = @{ github = 0; modrinth = 0; curseforge = 0 }
$modCount = 0

foreach ($block in $entries) {
    $relative = Get-TomlString $block 'file'
    Assert-AllowedPackPath ("pack/private-3players/" + $relative)
    $isMeta = ([regex]::Match($block, '(?m)^metafile\s*=\s*true\s*$')).Success
    Assert ($seen.Add($relative)) "Duplicate Packwiz index path: $relative"
    $entryHash = Get-TomlString $block 'hash'
    Assert ($entryHash -match '^[0-9a-f]{64}$') "Malformed index hash: $relative"
    $entryPath = [IO.Path]::GetFullPath((Join-Path $packRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $rootPrefix = [IO.Path]::GetFullPath($packRoot)
    if (!$rootPrefix.EndsWith([IO.Path]::DirectorySeparatorChar)) { $rootPrefix += [IO.Path]::DirectorySeparatorChar }
    Assert ($entryPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) "Index path escapes Packwiz root: $relative"
    Assert (Test-Path -LiteralPath $entryPath -PathType Leaf) "Missing indexed file: $relative"
    Assert ((Get-Sha256 $entryPath) -ceq $entryHash) "Indexed file hash mismatch: $relative"
    $expected["pack/private-3players/$relative"] = $true

    if (!$isMeta) {
        Assert ($relative -notmatch '^mods/') "Non-metafile mod downloads are forbidden: $relative"
        continue
    }

    Assert ($relative -match '^mods/[^/]+\.jar\.pw\.toml$') "Unexpected metafile path: $relative"
    $metaText = [IO.File]::ReadAllText($entryPath)
    Assert ((Get-TomlString $metaText 'side') -ceq 'client') "Non-client Packwiz entry: $relative"
    Assert (!(($metaText -match '(?im)^\[update\]\s*$'))) "Marketplace update block is forbidden: $relative"
    Assert ((Get-TomlString $metaText 'hash-format') -ceq 'sha256') "JAR hash format is not SHA-256: $relative"
    $jarHash = Get-TomlString $metaText 'hash'
    Assert ($jarHash -match '^[0-9a-f]{64}$') "Malformed JAR hash: $relative"
    $filename = Get-TomlString $metaText 'filename'
    Assert ($filename -match '^[^<>:"/\\|?*]+\.jar$') "Unsafe JAR filename: $relative"
    Assert ($relative -ceq "mods/$filename.pw.toml") "Metafile filename/path mismatch: $relative"
    Assert ($seenJars.Add($filename)) "Duplicate managed JAR filename: $filename"
    $url = Get-TomlString $metaText 'url'
    $uri = $null
    Assert ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) "Invalid download URL: $relative"
    Assert ($uri.Scheme -ceq 'https' -and $uri.IsDefaultPort -and !$uri.UserInfo -and !$uri.Query -and !$uri.Fragment) "Download URL must be clean HTTPS: $relative"
    $decoded = [Uri]::UnescapeDataString($uri.AbsolutePath)

    switch -CaseSensitive ($uri.Host.ToLowerInvariant()) {
        'raw.githubusercontent.com' {
            Assert ($decoded -match '^/Francho2002/kxcraft/[0-9a-f]{40}/binaries/mods/[^/]+\.jar$') "GitHub URL must pin a full KxCraft commit: $relative"
            $providers.github++
        }
        'cdn.modrinth.com' {
            Assert ($decoded -match '^/data/[A-Za-z0-9_-]+/versions/[A-Za-z0-9_-]+/[^/]+\.jar$') "Modrinth URL must be version-pinned: $relative"
            $providers.modrinth++
        }
        { $_ -in @('edge.forgecdn.net', 'mediafilez.forgecdn.net') } {
            Assert ($decoded -match '^/files/[0-9]{1,4}/[0-9]{1,4}/[^/]+\.jar$') "CurseForge URL must be file-pinned: $relative"
            $providers.curseforge++
        }
        default { throw "Unapproved mod source host $($uri.Host): $relative" }
    }
    $modCount++
}

Assert ($gate.modCount -eq $modCount) "Release gate modCount=$($gate.modCount) but manifest contains $modCount mod JARs."
if ($null -ne $gate.PSObject.Properties['indexEntryCount']) {
    Assert ($gate.indexEntryCount -eq $entries.Count) "Release gate indexEntryCount=$($gate.indexEntryCount) but index.toml contains $($entries.Count) entries."
}
Assert (($providers.github + $providers.modrinth + $providers.curseforge) -eq $modCount) 'Some managed mod source was not counted.'
Assert ($gate.downloadableGitHubModCount -eq $providers.github -and $gate.downloadableModrinthModCount -eq $providers.modrinth -and $gate.downloadableCurseForgeModCount -eq $providers.curseforge) 'Release gate provider counts do not match actual metafiles.'
Assert ($actual.Count -eq $expected.Count) "Pages tree has $($actual.Count) files; manifest allows $($expected.Count)."
foreach ($path in $actual) { Assert $expected.ContainsKey($path) "Unexpected public file: $path" }
foreach ($path in $expected.Keys) { Assert ($actual -contains $path) "Expected public file is missing: $path" }

$html = [IO.File]::ReadAllText((Join-Path $root 'index.html'))
Assert ($html -match 'aria-disabled="true"') 'KxCraft.zip download control must remain disabled.'
Assert ($html -match 'KxCraft\.zip') 'Download section marker disappeared.'
Write-Output "PASS: Pages allowlist; Packwiz mods=$modCount/index entries=$($entries.Count); providers GitHub=$($providers.github), Modrinth=$($providers.modrinth), CurseForge=$($providers.curseforge); PUBLISHED gate and SHA-256 checks passed."
