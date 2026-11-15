[CmdletBinding()]
param([string]$SiteRoot = 'site')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($SiteRoot)
$packRoot = Join-Path $root 'pack\private-3players'
function Assert([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-TomlString([string]$Text,[string]$Name) {
    $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*=\s*"(?<value>(?:[^"\\]|\\.)*)"\s*$'
    $m = [regex]::Match($Text,$pattern)
    if (!$m.Success) { throw "Missing TOML string '$Name'." }
    $v=$m.Groups['value'].Value
    if ($v -match '\\(?!["\\nrt])') { throw "Unsupported TOML escape in '$Name'." }
    $v.Replace('\"','"').Replace('\\','\').Replace('\n',"`n").Replace('\r',"`r").Replace('\t',"`t")
}
function Get-TomlBlocks([string]$Text) { @([regex]::Split($Text,'(?m)^\[\[files\]\]\s*$') | Select-Object -Skip 1) }
Assert (Test-Path -LiteralPath $packRoot -PathType Container) 'Packwiz snapshot directory is missing.'
$requiredWeb=@('index.html','assets/app.js','assets/site.css')
foreach($p in $requiredWeb){Assert (Test-Path -LiteralPath (Join-Path $root $p) -PathType Leaf) "Required public web file is missing: $p"}
$allFiles=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
foreach($f in $allFiles){Assert (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Symlink/reparse point is forbidden in Pages content: $($f.FullName)"}
$actual=@($allFiles | ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/') } | Sort-Object -Culture 'en-US')
foreach($p in $actual){Assert ($p -notmatch '(?i)(^|/)(\.env|.*\.key|.*\.p12|.*\.pem)$') "Private/secret-like file is forbidden: $p"; Assert ($p -notmatch '(?i)\.(jar|zip|mca|dat|nbt)$') "Binary/world archive is forbidden in Pages: $p"; Assert ($p -match '^(index\.html|assets/(app\.js|site\.css)|pack/private-3players/(pack\.toml|index\.toml|release\.json|mods/[^/]+\.jar\.pw\.toml))$') "Unexpected Pages file: $p"}
$packPath=Join-Path $packRoot 'pack.toml'; $indexPath=Join-Path $packRoot 'index.toml'; $gatePath=Join-Path $packRoot 'release.json'
$packText=[IO.File]::ReadAllText($packPath); $indexText=[IO.File]::ReadAllText($indexPath); $gate=Get-Content -LiteralPath $gatePath -Raw | ConvertFrom-Json
Assert ((Get-TomlString $packText 'pack-format') -eq 'packwiz:1.1.0') 'Unexpected Packwiz format.'
Assert ((Get-TomlString $packText 'minecraft') -eq '1.21.1') 'Unexpected Minecraft version.'
Assert ((Get-TomlString $packText 'neoforge') -eq '21.1.265') 'Unexpected NeoForge version.'
Assert ((Get-TomlString $packText 'version') -eq '1.0.0') 'Pack version is not the approved release.'
Assert ((Get-TomlString $packText 'file') -eq 'index.toml') 'pack.toml must reference index.toml.'
Assert ((Get-TomlString $packText 'hash-format') -eq 'sha256') 'pack.toml index hash format must be SHA-256.'
Assert ((Get-TomlString $indexText 'hash-format') -eq 'sha256') 'index.toml must use SHA-256.'
$indexHash=Get-TomlString $packText 'hash'
Assert ($indexHash -match '^[0-9a-f]{64}$') 'index.toml hash is malformed.'
Assert ((Get-Sha256 $indexPath) -ceq $indexHash) 'index.toml SHA-256 does not match pack.toml.'
Assert ($gate.schemaVersion -eq 1 -and $gate.state -ceq 'PUBLISHED') 'Release gate is not PUBLISHED.'
Assert ($gate.releaseVersion -ceq '1.0.0') 'Release gate version mismatch.'
Assert ($gate.packTomlUrl -ceq 'https://francho2002.github.io/kxcraft/pack/private-3players/pack.toml') 'Release gate manifest URL mismatch.'
Assert ($gate.packTomlSha256 -ceq (Get-Sha256 $packPath)) 'release.json does not pin pack.toml.'
Assert ($gate.modCount -eq 158 -and $gate.exactSourceBlockerCount -eq 0 -and $gate.zipSeededPreservedModCount -eq 0) 'Release gate mod counts are invalid.'
Assert ($gate.rawBinaryCommit -match '^[0-9a-f]{40}$') 'Release gate raw binary commit is not immutable.'
Assert ($gate.sourceMapSha256 -match '^[0-9a-f]{64}$') 'Release gate source-map hash is malformed.'
$entries=Get-TomlBlocks $indexText
Assert ($entries.Count -eq 158) "Expected 158 index records, got $($entries.Count)."
$expected=@{'index.html'=$true;'assets/app.js'=$true;'assets/site.css'=$true;'pack/private-3players/pack.toml'=$true;'pack/private-3players/index.toml'=$true;'pack/private-3players/release.json'=$true}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$providers=@{ github=0; modrinth=0; curseforge=0 }
foreach($block in $entries){
    $relative=Get-TomlString $block 'file'; $isMeta=([regex]::Match($block,'(?m)^metafile\s*=\s*true\s*$')).Success
    Assert $isMeta 'Every published record must be a metafile.'
    Assert ($relative -match '^mods/[^/]+\.jar\.pw\.toml$') "Unexpected managed path: $relative"
    Assert ($seen.Add($relative)) "Duplicate metadata path: $relative"
    $entryHash=Get-TomlString $block 'hash'; Assert ($entryHash -match '^[0-9a-f]{64}$') "Malformed index hash: $relative"
    $metaPath=Join-Path $packRoot ($relative.Replace('/','\'))
    Assert (Test-Path -LiteralPath $metaPath -PathType Leaf) "Missing metafile: $relative"
    Assert ((Get-Sha256 $metaPath) -ceq $entryHash) "Metafile hash mismatch: $relative"
    $meta=[IO.File]::ReadAllText($metaPath)
    Assert ((Get-TomlString $meta 'side') -ceq 'client') "Non-client metafile: $relative"
    Assert (!(($meta -match '(?im)^\[update\]\s*$'))) "Marketplace update block is forbidden: $relative"
    Assert ((Get-TomlString $meta 'hash-format') -ceq 'sha256') "JAR hash format is not SHA-256: $relative"
    $jarHash=Get-TomlString $meta 'hash'; Assert ($jarHash -match '^[0-9a-f]{64}$') "Malformed JAR hash: $relative"
    $filename=Get-TomlString $meta 'filename'; Assert ($filename -match '^[^<>:"/\\|?*]+\.jar$') "Unsafe JAR filename: $relative"
    Assert ($relative -ceq "mods/$filename.pw.toml") "Metafile filename/path mismatch: $relative"
    $uri=$null; Assert ([Uri]::TryCreate((Get-TomlString $meta 'url'),[UriKind]::Absolute,[ref]$uri)) "Invalid download URL: $relative"
    Assert ($uri.Scheme -ceq 'https' -and $uri.IsDefaultPort -and !$uri.UserInfo -and !$uri.Query -and !$uri.Fragment) "Download URL must be clean HTTPS: $relative"
    $decoded=[Uri]::UnescapeDataString($uri.AbsolutePath)
    switch($uri.Host){
        'raw.githubusercontent.com' { Assert ($decoded -match "^/Francho2002/kxcraft/[0-9a-f]{40}/binaries/mods/[^/]+\.jar$") "GitHub URL must pin a full commit: $relative"; Assert ([IO.Path]::GetFileName($decoded) -ceq $filename) "GitHub filename mismatch: $relative"; $providers.github++ }
        'cdn.modrinth.com' { Assert ($decoded -match '^/data/[A-Za-z0-9_-]+/versions/[A-Za-z0-9_-]+/[^/]+\.jar$') "Modrinth URL must be version-pinned: $relative"; $providers.modrinth++ }
        'edge.forgecdn.net' { Assert ($decoded -match '^/files/[0-9]{1,4}/[0-9]{1,4}/[^/]+\.jar$') "CurseForge URL must be file-pinned: $relative"; $providers.curseforge++ }
        default { throw "Unapproved mod source host $($uri.Host): $relative" }
    }
    $expected["pack/private-3players/$relative"]=$true
}
Assert ($providers.github -eq 20 -and $providers.modrinth -eq 123 -and $providers.curseforge -eq 15) 'Source provider counts do not match the release gate.'
Assert ($gate.downloadableGitHubModCount -eq $providers.github -and $gate.downloadableModrinthModCount -eq $providers.modrinth -and $gate.downloadableCurseForgeModCount -eq $providers.curseforge) 'Release gate provider counts mismatch.'
Assert ($gate.rawBinaryCommit -eq 'd878793f83283257c038e54d7b0a1bac0bf2e37d') 'Release gate points to an unexpected binary commit.'
Assert ($actual.Count -eq $expected.Count) "Pages tree has $($actual.Count) files; expected $($expected.Count)."
foreach($p in $actual){Assert $expected.ContainsKey($p) "Unexpected public file: $p"}
foreach($p in $expected.Keys){Assert ($actual -contains $p) "Expected public file is missing: $p"}
$html=[IO.File]::ReadAllText((Join-Path $root 'index.html'))
Assert ($html -match 'aria-disabled="true"') 'KxCraft.zip download control must remain disabled.'
Assert ($html -match 'KxCraft\.zip') 'Download section marker disappeared.'
Write-Output "PASS: public Pages allowlist; Packwiz 158/158; sources GitHub $($providers.github), Modrinth $($providers.modrinth), CurseForge $($providers.curseforge); release gate PUBLISHED; no mods/worlds/secrets in Pages."