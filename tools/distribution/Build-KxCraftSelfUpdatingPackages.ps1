[CmdletBinding()]
param(
    [string]$CandidateRoot = '',
    [string]$OutputZip = '',
    [string]$BasePackageZip = '',
    [string]$ProfileCandidatePath = '',
    [string]$ClientProfileMinecraftDirectory = '',
    [string]$ExpectedPackVersion = '',
    [int]$ExpectedModCount = 0,
    [string]$PackageReleaseTag = '',
    [string]$PackageDisplayVersion = '',
    [switch]$PackageOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$validationModulePath=Join-Path $PSScriptRoot 'KxCraftPackageValidation.psm1'
if(!(Test-Path -LiteralPath $validationModulePath -PathType Leaf)){throw 'KxCraft package validation module is missing.'}
Import-Module $validationModulePath -Force
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    $activeCandidatePath=Join-Path $projectRoot 'distribution-v1\private-update-manager\active-candidate.json'
    if (!(Test-Path -LiteralPath $activeCandidatePath -PathType Leaf)) { throw 'The active KxCraft candidate pointer is missing.' }
    $activeCandidate=Get-Content -LiteralPath $activeCandidatePath -Raw|ConvertFrom-Json -ErrorAction Stop
    $CandidateRoot=[string]$activeCandidate.candidate
}
$CandidateRoot=[IO.Path]::GetFullPath($CandidateRoot)
$packagesRoot=Join-Path $projectRoot 'distribution-v1\packages'
if ([string]::IsNullOrWhiteSpace($BasePackageZip)) { $BasePackageZip=Join-Path $packagesRoot 'KxCraft.zip' }
$basePackage=[IO.Path]::GetFullPath($BasePackageZip)
if ([string]::IsNullOrWhiteSpace($OutputZip)) { $OutputZip=Join-Path $CandidateRoot 'packages\KxCraft.zip' }
$OutputZip=[IO.Path]::GetFullPath($OutputZip)
if ([string]::IsNullOrWhiteSpace($ClientProfileMinecraftDirectory)) {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { throw 'APPDATA is unavailable; pass ClientProfileMinecraftDirectory explicitly.' }
    $ClientProfileMinecraftDirectory=Join-Path $env:APPDATA 'PrismLauncher\instances\KxCraft\.minecraft'
}
$ClientProfileMinecraftDirectory=[IO.Path]::GetFullPath($ClientProfileMinecraftDirectory)
if ([string]::IsNullOrWhiteSpace($ProfileCandidatePath)) { $ProfileCandidatePath=Join-Path $CandidateRoot 'candidate.json' }
$candidateJsonPath=[IO.Path]::GetFullPath($ProfileCandidatePath)
$packRoot=Join-Path $CandidateRoot 'site\pack\KxCraft'
$bundleManifestPath=Join-Path $CandidateRoot 'site\updater\manifest.json'
$bundleManifest=Get-Content -LiteralPath $bundleManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$bundleVersion=[string]$bundleManifest.updaterVersion
if($bundleVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'Updater manifest version is malformed.'}
$bundlePath=Join-Path $CandidateRoot ('binaries\distribution-v1\updater\releases\'+$bundleVersion+'\KxCraft-Updater.zip')
$bootstrapPath=Join-Path $PSScriptRoot 'KxCraft-Bootstrap.ps1'
$clientAeroStructuresConfigPath=Join-Path $projectRoot 'modpack\config\cr_aero_structures-client.toml'
if(!(Test-Path -LiteralPath $clientAeroStructuresConfigPath -PathType Leaf)){throw 'The approved client Create Aeronautics Structures config source is missing.'}
$clientAeroStructuresConfigBytes=[IO.File]::ReadAllBytes($clientAeroStructuresConfigPath)
$clientAeroStructuresConfigText=[Text.UTF8Encoding]::new($false,$true).GetString($clientAeroStructuresConfigBytes)
if(@([regex]::Matches($clientAeroStructuresConfigText,'(?m)^showLoginMessage\s*=\s*false\s*$')).Count -ne 1 -or $clientAeroStructuresConfigText -match '(?m)^showLoginMessage\s*=\s*true\s*$'){throw 'Client Create Aeronautics Structures config must set showLoginMessage = false exactly once.'}
$helperPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'packwiz\KxCraft-ManagedFiles.ps1'
$updaterPath=Join-Path $PSScriptRoot 'updater\KxCraft-Updater.ps1'
$profile=Get-Content -LiteralPath $candidateJsonPath -Raw|ConvertFrom-Json -ErrorAction Stop
$candidate=$profile
$channelGate=Get-Content -LiteralPath (Join-Path $packRoot 'release.json') -Raw|ConvertFrom-Json -ErrorAction Stop
if ($profile.status -cne 'READY' -or $profile.version -cne [string]$channelGate.releaseVersion -or $profile.profileRecords.Count -ne [int]$channelGate.modCount -or $channelGate.state -cne 'PUBLISHED' -or [string]$channelGate.packTomlUrl -cne 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml') { throw 'The package profile candidate and published KxCraft release gate do not describe the same approved release.' }
if (($ExpectedPackVersion -and $ExpectedPackVersion -cne [string]$channelGate.releaseVersion) -or ($ExpectedModCount -gt 0 -and $ExpectedModCount -ne [int]$channelGate.modCount)) { throw 'The candidate differs from the release version/mod-count expectation supplied for this package build.' }
$packDirs=@(Get-ChildItem -LiteralPath (Join-Path $CandidateRoot 'site\pack') -Directory | Select-Object -ExpandProperty Name)
if ($packDirs.Count -ne 1 -or $packDirs[0] -cne 'KxCraft') { throw 'A Pages candidate must contain only site/pack/KxCraft/.' }


function Get-Sha256([byte[]]$Bytes) { $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()} }
function Get-ZipEntryHash([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream=$Entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
}
function Get-ZipEntryBytes([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream=$Entry.Open();$memory=[IO.MemoryStream]::new()
    try{$stream.CopyTo($memory);return ,$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()}
}
function Assert-UpdaterBundleEntry([IO.Compression.ZipArchive]$Archive,[string]$Name,[string]$SourcePath,[string]$ExpectedHash) {
    $entries=@($Archive.Entries|Where-Object {$_.FullName -ceq $Name})
    if($entries.Count -ne 1){throw "Updater bundle entry is missing or duplicated: $Name"}
    $source=Get-Item -LiteralPath $SourcePath
    $entryHash=Get-ZipEntryHash $entries[0]
    if($entries[0].Length -ne $source.Length -or $entryHash -cne (Get-Sha256 ([IO.File]::ReadAllBytes($SourcePath))) -or $entryHash -cne $ExpectedHash){throw "Updater bundle entry differs from the package runtime bytes: $Name"}
}
function Assert-UpdaterBundlePinnedEntry([IO.Compression.ZipArchive]$Archive,[string]$Name,[long]$ExpectedLength,[string]$ExpectedHash) {
    $entries=@($Archive.Entries|Where-Object {$_.FullName -ceq $Name})
    if($entries.Count -ne 1){throw "Updater bundle entry is missing or duplicated: $Name"}
    if($entries[0].Length -ne $ExpectedLength -or (Get-ZipEntryHash $entries[0]) -cne $ExpectedHash){throw "Immutable Updater bundle entry differs from its signed manifest pin: $Name"}
}
function Get-TomlValue([string]$Text,[string]$Name) { $m=[regex]::Match($Text,'(?m)^'+[regex]::Escape($Name)+'\s*=\s*"(?<v>(?:[^"\\]|\\.)*)"\s*$');if(!$m.Success){throw "Missing TOML field: $Name"};return $m.Groups['v'].Value.Replace('\"','"').Replace('\\','\') }
function Copy-ZipEntry([IO.Compression.ZipArchiveEntry]$Source,[IO.Compression.ZipArchiveEntry]$Target) {
    $input=$Source.Open();$output=$Target.Open()
    try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
}
function Write-ZipBytes([IO.Compression.ZipArchive]$Archive,[string]$Name,[byte[]]$Bytes) {
    $entry=$Archive.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal);$stream=$entry.Open()
    try{$stream.Write($Bytes,0,$Bytes.Length)}finally{$stream.Dispose()}
}
function Set-KxPackagePanelHtml([string]$Html,[string]$PackageHash,[string]$PackageDisplayVersion) {
    $panelPattern='(?is)<article\b(?=[^>]*\bkx-play-panel--pack\b)[^>]*>.*?</article>'
    $panels=[regex]::Matches($Html,$panelPattern)
    if($panels.Count -ne 1){throw 'The public page must contain exactly one KxCraft package panel.'}
    $panel=$panels[0].Value
    $importUrl='https://github.com/Francho2002/kxcraft/releases/latest/download/KxCraft.zip'
    if([regex]::Matches($panel,'(?is)<span\b(?=[^>]*\bid="kxcraft-import-url")(?=[^>]*\bclass="[^"]*\bkx-import-url\b[^"]*")[^>]*>\s*'+[regex]::Escape($importUrl)+'\s*</span>').Count -ne 1){throw 'The package panel must expose the exact visible Prism import URL.'}
    if([regex]::Matches($panel,'(?is)<button\b(?=[^>]*\bid="kxcraft-copy-button")(?=[^>]*\btype="button")[^>]*>').Count -ne 1){throw 'The package panel must have exactly one import-link copy button.'}
    if($panel -match '(?i)<a\b[^>]*href="[^"]*KxCraft\.zip'){throw 'The package panel must not expose a manual ZIP download link.'}
    $hashPattern='(?is)(<code\s+data-kx-package-sha256>)(?:[0-9a-f]{64}|__KXCRAFT_PACKAGE_SHA256__)(</code>)'
    if([regex]::Matches($panel,$hashPattern).Count -ne 1){throw 'The package panel must contain exactly one package SHA-256 field.'}
    $panel=[regex]::Replace($panel,$hashPattern,[System.Text.RegularExpressions.MatchEvaluator]{param($m) $m.Groups[1].Value+$PackageHash+$m.Groups[2].Value})
    $versionPattern='(?is)(<span\s+data-kx-package-version>)[^<]*(</span>)'
    if([regex]::Matches($panel,$versionPattern).Count -ne 1){throw 'The package panel must contain exactly one visible package version field.'}
    $panel=[regex]::Replace($panel,$versionPattern,[System.Text.RegularExpressions.MatchEvaluator]{param($m) $m.Groups[1].Value+[System.Net.WebUtility]::HtmlEncode($PackageDisplayVersion)+$m.Groups[2].Value})
    return $Html.Substring(0,$panels[0].Index)+$panel+$Html.Substring($panels[0].Index+$panels[0].Length)
}

foreach($f in @($bootstrapPath,$bundlePath,$candidateJsonPath)){if(!(Test-Path -LiteralPath $f -PathType Leaf)){throw "Required package source is missing: $f"}}
$bundleHash=(Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
$bundleLength=(Get-Item -LiteralPath $bundlePath).Length
if ($bundleHash -cne [string]$bundleManifest.bundle.sha256 -or $bundleLength -ne [long]$bundleManifest.bundle.length) { throw 'Immutable Updater bundle does not match the signed candidate manifest.' }
$bundleArchive=[IO.Compression.ZipFile]::OpenRead($bundlePath)
try{
    $bundleNames=@($bundleArchive.Entries|ForEach-Object {[string]$_.FullName})
    if($bundleArchive.Entries.Count -ne 2 -or @($bundleNames|Where-Object {$_ -cnotin @('KxCraft-Updater.ps1','KxCraft-ManagedFiles.ps1')}).Count -ne 0){throw 'Updater bundle must contain exactly the two pinned runtime files.'}
    $updaterPin=@($bundleManifest.files|Where-Object path -eq 'KxCraft-Updater.ps1')[0]
    $helperPin=@($bundleManifest.files|Where-Object path -eq 'KxCraft-ManagedFiles.ps1')[0]
    Assert-UpdaterBundlePinnedEntry $bundleArchive 'KxCraft-Updater.ps1' ([long]$updaterPin.length) ([string]$updaterPin.sha256)
    Assert-UpdaterBundlePinnedEntry $bundleArchive 'KxCraft-ManagedFiles.ps1' ([long]$helperPin.length) ([string]$helperPin.sha256)
    $updaterBytes=Get-ZipEntryBytes ($bundleArchive.GetEntry('KxCraft-Updater.ps1'))
    $helperBytes=Get-ZipEntryBytes ($bundleArchive.GetEntry('KxCraft-ManagedFiles.ps1'))
}finally{$bundleArchive.Dispose()}
$manifest=Get-Content -LiteralPath $bundleManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$manifestSignaturePath=Join-Path (Split-Path -Parent $bundleManifestPath) 'manifest.sig'
$publicKeyPath=Join-Path $PSScriptRoot 'updater\public-key.csp.base64'
foreach($required in @($manifestSignaturePath,$publicKeyPath)){if(!(Test-Path -LiteralPath $required -PathType Leaf)){throw "Signed Updater publication input is missing: $required"}}
$channelProperties=@($manifest.channels.PSObject.Properties|Where-Object {$_.MemberType -eq 'NoteProperty'})
if($manifest.state -cne 'PUBLISHED' -or $channelProperties.Count -ne 1 -or $channelProperties[0].Name -cne 'KxCraft' -or [string]$manifest.channels.KxCraft.packTomlUrl -cne 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml' -or [string]$manifest.channels.KxCraft.packTomlSha256 -cne [string]$channelGate.packTomlSha256 -or [int]$manifest.channels.KxCraft.modCount -ne [int]$channelGate.modCount -or [string]$manifest.channels.KxCraft.packVersion -cne [string]$channelGate.releaseVersion){throw 'Signed Updater manifest must pin exactly the published KxCraft channel.'}
$bundleUri=[Uri][string]$manifest.bundle.url
if($bundleUri.AbsoluteUri -notmatch ('^https://raw\.githubusercontent\.com/Francho2002/kxcraft/[0-9a-f]{40}/distribution-v1/updater/releases/'+[regex]::Escape([string]$manifest.updaterVersion)+'/KxCraft-Updater\.zip$')){throw 'Updater bundle URL is not pinned to an immutable commit.'}
$manifestBytes=[IO.File]::ReadAllBytes($bundleManifestPath)
$signatureBytes=[Convert]::FromBase64String(([IO.File]::ReadAllText($manifestSignaturePath)).Trim())
$verifyRsa=New-Object Security.Cryptography.RSACryptoServiceProvider
try{$verifyRsa.PersistKeyInCsp=$false;$verifyRsa.ImportCspBlob([Convert]::FromBase64String(([IO.File]::ReadAllText($publicKeyPath)).Trim()));if(!$verifyRsa.VerifyData($manifestBytes,'SHA256',$signatureBytes)){throw 'Updater manifest signature verification failed.'}}finally{$verifyRsa.Dispose()}
$packVersion=[string]$channelGate.releaseVersion
$expectedModCount=[int]$channelGate.modCount
$updaterVersion=[string]$bundleManifest.updaterVersion
if($updaterVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'Updater manifest version is malformed.'}
$updaterInstallName=$updaterVersion+'-'+$bundleHash.Substring(0,12)

$packBytes=[IO.File]::ReadAllBytes((Join-Path $packRoot 'pack.toml'))
$indexBytes=[IO.File]::ReadAllBytes((Join-Path $packRoot 'index.toml'))
if ((Get-Sha256 $packBytes) -cne [string]$channelGate.packTomlSha256 -or (Get-Sha256 $indexBytes) -cne (Get-TomlValue ([Text.UTF8Encoding]::new($false,$true).GetString($packBytes)) 'hash')) { throw 'Managed Packwiz hashes do not match the candidate release gate.' }
$indexText=[Text.UTF8Encoding]::new($false,$true).GetString($indexBytes)
$managedFiles=[Collections.Generic.List[object]]::new()
$seenFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$recordsByName=@{}
foreach($record in $profile.profileRecords){if($recordsByName.ContainsKey([string]$record.filename)){throw ('Duplicate approved profile JAR filename: '+$record.filename)};$recordsByName[[string]$record.filename]=$record}
$modCount=0
foreach($block in ([regex]::Split($indexText,'(?m)^\[\[files\]\]\s*$')|Select-Object -Skip 1)){
    if($block -notmatch '(?m)^metafile\s*=\s*true\s*$'){throw 'Candidate contains an unexpected non-mod index entry.'}
    $relative=Get-TomlValue $block 'file';$metadataHash=(Get-TomlValue $block 'hash').ToLowerInvariant()
    if($relative -notmatch '^mods/([^/]+\.pw\.toml)$' -or !$seenFiles.Add($relative)){throw "Unsafe or duplicate Packwiz path: $relative"}
    $filename=$Matches[1] -replace '\.pw\.toml$',''
    $metaPath=Join-Path $packRoot ($relative.Replace('/','\'))
    $metaBytes=[IO.File]::ReadAllBytes($metaPath);if((Get-Sha256 $metaBytes) -cne $metadataHash){throw "Metafile SHA-256 mismatch: $relative"}
    $meta=[Text.UTF8Encoding]::new($false,$true).GetString($metaBytes)
    $jarName=Get-TomlValue $meta 'filename';$jarHash=(Get-TomlValue $meta 'hash').ToLowerInvariant()
    if($filename -cne $jarName -or $jarHash -notmatch '^[0-9a-f]{64}$'){throw "Metafile filename or JAR hash is invalid: $relative"}
    $record=$recordsByName[$jarName]
    if(!$record -or [string]$record.sha256 -cne $jarHash){throw "Packwiz record does not match the exact profile inventory: $jarName"}
    if(!$PackageOnly){
        $sourceJar=Join-Path $ClientProfileMinecraftDirectory ('mods\'+$jarName)
        if(!(Test-Path -LiteralPath $sourceJar -PathType Leaf)){throw "Approved local profile JAR is missing: $jarName"}
        $jarItem=Get-Item -LiteralPath $sourceJar
        if($jarItem.Length -ne [long]$record.bytes -or (Get-FileHash -LiteralPath $sourceJar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $jarHash){throw "Local JAR does not match the approved candidate bytes: $jarName"}
    }
    $managedFiles.Add([pscustomobject]@{path=('mods/'+$jarName);sha256=$jarHash})
    $modCount++
}
if($modCount -ne $expectedModCount -or $managedFiles.Count -ne $expectedModCount -or $recordsByName.Count -ne $expectedModCount){throw "Expected exact $expectedModCount/$expectedModCount source, index, and profile records; found $modCount/$($managedFiles.Count)/$($recordsByName.Count)."}
$initialState=[pscustomobject]@{schemaVersion=1;packTomlUrl='https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml';files=@()}
$bootstrapBytes=[IO.File]::ReadAllBytes($bootstrapPath)
$activeBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject ([pscustomobject]@{schemaVersion=1;channel='KxCraft';sequence=0;updaterVersion=$updaterVersion;bundleSha256=$bundleHash;installDirectoryName=$updaterInstallName;seededByPackage=$true}) -Depth 10))
function ConvertTo-PrismQSettingsEscapedValue([string]$Value){
    # QSettings consumes backslashes as escape prefixes unless they are doubled.
    $backslash=[string][char]92
    $quote=[string][char]34
    $escapedBackslash=$backslash+$backslash
    $escapedQuote=$backslash+$quote
    return $Value.Replace($backslash,$escapedBackslash).Replace($quote,$escapedQuote)
}
$prelaunchCommand='powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\.minecraft\KxCraft-Bootstrap.ps1" -Channel KxCraft'
$prelaunch='PreLaunchCommand='+(ConvertTo-PrismQSettingsEscapedValue $prelaunchCommand)
$sourceBootstrapText=[Text.UTF8Encoding]::new($false,$true).GetString($bootstrapBytes)
Assert-KxBootstrapAndManifestPolicy -BootstrapText $sourceBootstrapText -Manifest $manifest -ExpectedPackVersion $packVersion -ExpectedModCount $expectedModCount
$readme=@"
KxCraft $packVersion

Importá esta instancia en PrismLauncher y presioná Jugar.
Antes de abrir Minecraft, KxCraft Bootstrap verifica el manifiesto firmado y Packwiz descarga los $expectedModCount mods necesarios.
En los inicios siguientes, Packwiz sincroniza los archivos nuevos, modificados o retirados del manifiesto vigente.

Si falla la firma, una descarga o la comprobación de integridad, Minecraft no se inicia con una instalación incompleta.
El ZIP no contiene JAR de mods. Conserva la configuración, los resourcepacks, los mapas iniciales y los archivos necesarios de Prism.
"@
$readme=[regex]::Replace($readme,'\r?\n',"`r`n")
    $readme=[regex]::Replace($readme,'\r?\n',"`r`n")
    $readmeBytes=[Text.UTF8Encoding]::new($false).GetBytes($readme)

function Build-Package([string]$BaseZip,[string]$OutputZip){
    $source=[IO.Compression.ZipFile]::OpenRead($BaseZip)
    $outputStream=[IO.File]::Open($OutputZip,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $target=New-Object IO.Compression.ZipArchive($outputStream,[IO.Compression.ZipArchiveMode]::Create,$false)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $added=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $newNames=@{
        'KxCraft/instance.cfg'=$true
        'KxCraft/.minecraft/kxcraft-prelaunch.ps1'=$true
        'KxCraft/.minecraft/KxCraft-ManagedFiles.ps1'=$true
        'KxCraft/.minecraft/.kxcraft-packwiz-state.json'=$true
        'KxCraft/.minecraft/packwiz.json'=$true
        'KxCraft/.minecraft/KxCraft-AutoUpdate-README.txt'=$true
        'KxCraft/.minecraft/KxCraft-Bootstrap.ps1'=$true
        'KxCraft/.minecraft/config/cr_aero_structures-client.toml'=$true
        'KxCraft/.minecraft/kxcraft-initial-seed/manifest.json'=$true
        'KxCraft/.minecraft/.kxcraft/updaters/KxCraft/active.json'=$true
        ('KxCraft/.minecraft/.kxcraft/updaters/KxCraft/'+$updaterInstallName+'/KxCraft-Updater.ps1')=$true
        ('KxCraft/.minecraft/.kxcraft/updaters/KxCraft/'+$updaterInstallName+'/KxCraft-ManagedFiles.ps1')=$true
        'KxCraft/.minecraft/mods/'=$true
    }
    if($PackageOnly){[void]$newNames.Remove('KxCraft/.minecraft/KxCraft-AutoUpdate-README.txt')}
    try{
        foreach($entry in $source.Entries){
            if(!$seen.Add($entry.FullName)){throw "Base ZIP contains duplicate entry: $($entry.FullName)"}
            if($entry.FullName -ceq 'KxCraft/.minecraft/mods/' -or $entry.FullName -match '^KxCraft/\.minecraft/mods/[^/]+\.jar$' -or $entry.FullName -match '^KxCraft/\.minecraft/\.kxcraft/legacy/1\.0\.8-' -or $entry.FullName -match '^KxCraft/\.minecraft/\.kxcraft/updaters/') {continue}
            if($newNames.ContainsKey($entry.FullName)){continue}
            $created=$target.CreateEntry($entry.FullName,[IO.Compression.CompressionLevel]::Optimal)
            $created.LastWriteTime=$entry.LastWriteTime
            $created.ExternalAttributes=$entry.ExternalAttributes
            Copy-ZipEntry $entry $created
            [void]$added.Add($entry.FullName)
        }
        $cfgEntry=$source.GetEntry('KxCraft/instance.cfg')
        if(!$cfgEntry){throw 'Base ZIP lacks Prism instance.cfg.'}
        $reader=New-Object IO.StreamReader($cfgEntry.Open(),[Text.Encoding]::UTF8,$true)
        try{$cfg=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if($cfg -notmatch '(?im)^PreLaunchCommand=') { throw 'Base Prism instance lacks a prelaunch command to replace.' }
        $cfg=[regex]::Replace($cfg,'(?im)^PreLaunchCommand=.*$',[System.Text.RegularExpressions.MatchEvaluator]{param($m) $prelaunch})
        Write-ZipBytes $target 'KxCraft/instance.cfg' ([Text.UTF8Encoding]::new($false).GetBytes($cfg));[void]$added.Add('KxCraft/instance.cfg')
        Write-ZipBytes $target 'KxCraft/.minecraft/config/cr_aero_structures-client.toml' $clientAeroStructuresConfigBytes;[void]$added.Add('KxCraft/.minecraft/config/cr_aero_structures-client.toml')
        Write-ZipBytes $target 'KxCraft/.minecraft/.kxcraft-packwiz-state.json' ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $initialState -Depth 20)));[void]$added.Add('KxCraft/.minecraft/.kxcraft-packwiz-state.json')
        if(!$PackageOnly){Write-ZipBytes $target 'KxCraft/.minecraft/KxCraft-AutoUpdate-README.txt' $readmeBytes;[void]$added.Add('KxCraft/.minecraft/KxCraft-AutoUpdate-README.txt')}
        Write-ZipBytes $target 'KxCraft/.minecraft/KxCraft-Bootstrap.ps1' $bootstrapBytes;[void]$added.Add('KxCraft/.minecraft/KxCraft-Bootstrap.ps1')
        $seedManifestEntry=$source.GetEntry('KxCraft/.minecraft/kxcraft-initial-seed/manifest.json')
        if($seedManifestEntry){
            $seedReader=New-Object IO.StreamReader($seedManifestEntry.Open(),[Text.Encoding]::UTF8,$true)
            try{$seedManifest=$seedReader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}finally{$seedReader.Dispose()}
            $seedManifest.purpose='One-time KxCraft Prism seed for FTB Chunks map tiles, verified Distant Horizons server LOD, and client map settings.'
            if($null -ne $seedManifest.distantHorizonsCache.runtimeEvidence -and $null -ne $seedManifest.distantHorizonsCache.runtimeEvidence.PSObject.Properties['clientLog']){$seedManifest.distantHorizonsCache.runtimeEvidence.PSObject.Properties.Remove('clientLog')}
            Write-ZipBytes $target 'KxCraft/.minecraft/kxcraft-initial-seed/manifest.json' ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $seedManifest -Depth 32)))
            [void]$added.Add('KxCraft/.minecraft/kxcraft-initial-seed/manifest.json')
        }
        Write-ZipBytes $target 'KxCraft/.minecraft/.kxcraft/updaters/KxCraft/active.json' $activeBytes;[void]$added.Add('KxCraft/.minecraft/.kxcraft/updaters/KxCraft/active.json')
        $prefix='KxCraft/.minecraft/.kxcraft/updaters/KxCraft/'+$updaterInstallName+'/'
        Write-ZipBytes $target ($prefix+'KxCraft-Updater.ps1') $updaterBytes;[void]$added.Add($prefix+'KxCraft-Updater.ps1')
        Write-ZipBytes $target ($prefix+'KxCraft-ManagedFiles.ps1') $helperBytes;[void]$added.Add($prefix+'KxCraft-ManagedFiles.ps1')
        $target.Dispose();$outputStream.Dispose();$source.Dispose()
    } catch {
        $target.Dispose();$outputStream.Dispose();$source.Dispose()
        throw
    }
}

$candidatePackages=Split-Path -Parent $OutputZip
[IO.Directory]::CreateDirectory($candidatePackages)|Out-Null
if(!(Test-Path -LiteralPath $basePackage -PathType Leaf)){throw "Single KxCraft base ZIP is missing: $basePackage"}
if(Test-Path -LiteralPath $OutputZip -PathType Leaf){throw "KxCraft ZIP candidate already exists; refusing overwrite: $OutputZip"}
Build-Package $basePackage $OutputZip
$packageCoherence=Assert-KxPackageCoherence -PackagePath $OutputZip -BootstrapPath $bootstrapPath -ClientConfigPath $clientAeroStructuresConfigPath -ManifestPath $bundleManifestPath -ManifestSignaturePath $manifestSignaturePath -PublicKeyPath $publicKeyPath -ExpectedPreLaunchCommand $prelaunchCommand -ExpectedPackVersion $packVersion -ExpectedModCount $expectedModCount
$zipHash=(Get-FileHash -LiteralPath $OutputZip -Algorithm SHA256).Hash.ToLowerInvariant()
$zipLength=[long](Get-Item -LiteralPath $OutputZip).Length
if($PackageOnly){
    $sidecar=$OutputZip+'.sha256'
    [IO.File]::WriteAllText($sidecar,($zipHash+'  '+[IO.Path]::GetFileName($OutputZip)+[Environment]::NewLine),[Text.Encoding]::ASCII)
    Write-Output ('Built private KxCraft package without editing release metadata or pages: '+$OutputZip)
    Write-Output ('Size bytes: '+$zipLength)
    Write-Output ('SHA-256: '+$zipHash)
    Write-Output ('Packaged Bootstrap SHA-256: '+$packageCoherence.BootstrapSha256)
    Write-Output ('Verified signed sequence: '+$packageCoherence.ManifestSequence)
    return
}
if ([string]::IsNullOrWhiteSpace($PackageReleaseTag)) { $PackageReleaseTag='kxc-'+[string]$channelGate.releaseVersion+'-final' }
if ([string]::IsNullOrWhiteSpace($PackageDisplayVersion)) { $PackageDisplayVersion=[string]$channelGate.releaseVersion }
if ($PackageReleaseTag -notmatch ('^kxc-'+[regex]::Escape([string]$channelGate.releaseVersion)+'-(?:final|hotfix[0-9]+)$')) { throw 'Package release tag must identify this Packwiz version as final or a numbered hotfix.' }
if ($PackageDisplayVersion -notmatch ('^'+[regex]::Escape([string]$channelGate.releaseVersion)+'(?: · Hotfix [0-9]+)?$')) { throw 'Visible package version must match the Packwiz release and optional hotfix number.' }
$downloadUrl='https://github.com/Francho2002/kxcraft/releases/download/'+$PackageReleaseTag+'/KxCraft.zip'
$channelGate | Add-Member -NotePropertyName packageFileName -NotePropertyValue 'KxCraft.zip' -Force
$channelGate | Add-Member -NotePropertyName packageVersion -NotePropertyValue $PackageDisplayVersion -Force
$channelGate | Add-Member -NotePropertyName packageLength -NotePropertyValue $zipLength -Force
$channelGate | Add-Member -NotePropertyName packageSha256 -NotePropertyValue $zipHash -Force
$channelGate | Add-Member -NotePropertyName packageUrl -NotePropertyValue $downloadUrl -Force
$releasePath=Join-Path $packRoot 'release.json'
[IO.File]::WriteAllText($releasePath,((ConvertTo-Json -InputObject $channelGate -Depth 32)+[char]10),[Text.UTF8Encoding]::new($false))
foreach($pagePath in @((Join-Path $CandidateRoot 'site\index.html'),(Join-Path $projectRoot 'web\public\index.html'))){
    if(!(Test-Path -LiteralPath $pagePath -PathType Leaf)){throw "The public installation page is missing: $pagePath"}
    $page=[IO.File]::ReadAllText($pagePath)
    $page=Set-KxPackagePanelHtml $page $zipHash $PackageDisplayVersion
    [IO.File]::WriteAllText($pagePath,$page,[Text.UTF8Encoding]::new($false))
}
$candidate | Add-Member -NotePropertyName package -NotePropertyValue ([pscustomobject]@{fileName='KxCraft.zip';length=$zipLength;sha256=$zipHash;url=$downloadUrl;path=$OutputZip;version=$PackageDisplayVersion;releaseTag=$PackageReleaseTag}) -Force
[IO.File]::WriteAllText($candidateJsonPath,((ConvertTo-Json -InputObject $candidate -Depth 64)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
$sidecar=$OutputZip+'.sha256'
[IO.File]::WriteAllText($sidecar,($zipHash+'  '+[IO.Path]::GetFileName($OutputZip)+[Environment]::NewLine),[Text.Encoding]::ASCII)
Write-Output ('Built private KxCraft package: '+$OutputZip)
Write-Output ('Size bytes: '+$zipLength)
Write-Output ('SHA-256: '+$zipHash)
Write-Output ('Public download metadata pinned in release.json and index.html: '+$downloadUrl)
