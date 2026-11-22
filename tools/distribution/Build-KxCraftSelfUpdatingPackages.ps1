[CmdletBinding()]
param(
    [string]$CandidateRoot = '',
    [string]$OutputZip = '',
    [string]$BasePackageZip = '',
    [string]$ProfileCandidatePath = '',
    [string]$ClientProfileMinecraftDirectory = 'C:\Users\panch\AppData\Roaming\PrismLauncher\instances\KxCraft\.minecraft'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($CandidateRoot)) { $CandidateRoot=Join-Path $projectRoot 'distribution-v1\private-update-manager\self-updating-1.0.9-candidate-20261119' }
$CandidateRoot=[IO.Path]::GetFullPath($CandidateRoot)
$packagesRoot=Join-Path $projectRoot 'distribution-v1\packages'
if ([string]::IsNullOrWhiteSpace($BasePackageZip)) { $BasePackageZip=Join-Path $packagesRoot 'KxCraft.zip' }
$basePackage=[IO.Path]::GetFullPath($BasePackageZip)
if ([string]::IsNullOrWhiteSpace($OutputZip)) { $OutputZip=Join-Path $CandidateRoot 'packages\KxCraft.zip' }
$OutputZip=[IO.Path]::GetFullPath($OutputZip)
if ([string]::IsNullOrWhiteSpace($ProfileCandidatePath)) { $ProfileCandidatePath=Join-Path $projectRoot 'distribution-v1\private-update-manager\1.0.9-preparation-20261119\expanded-candidates\1.0.9-20261119T062302Z\candidate.json' }
$candidateJsonPath=[IO.Path]::GetFullPath($ProfileCandidatePath)
$packRoot=Join-Path $CandidateRoot 'site\pack\managed-3players'
$bundleManifestPath=Join-Path $CandidateRoot 'site\updater\manifest.json'
$bundleManifest=Get-Content -LiteralPath $bundleManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$bundleVersion=[string]$bundleManifest.updaterVersion
if($bundleVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'Updater manifest version is malformed.'}
$bundlePath=Join-Path $CandidateRoot ('binaries\distribution-v1\updater\releases\'+$bundleVersion+'\KxCraft-Updater.zip')
$bootstrapPath=Join-Path $PSScriptRoot 'KxCraft-Bootstrap.ps1'
$helperPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'packwiz\KxCraft-ManagedFiles.ps1'
$updaterPath=Join-Path $PSScriptRoot 'updater\KxCraft-Updater.ps1'
$profile=Get-Content -LiteralPath $candidateJsonPath -Raw|ConvertFrom-Json -ErrorAction Stop
$channelGate=Get-Content -LiteralPath (Join-Path $packRoot 'release.json') -Raw|ConvertFrom-Json -ErrorAction Stop
if ($profile.status -cne 'READY' -or $profile.version -cne [string]$channelGate.releaseVersion -or $profile.profileRecords.Count -ne [int]$channelGate.modCount -or $channelGate.state -notin @('CANDIDATE','PUBLISHED')) { throw 'The package profile candidate and Packwiz release gate do not describe the same approved release.' }

function Get-Sha256([byte[]]$Bytes) { $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()} }
function Get-TomlValue([string]$Text,[string]$Name) { $m=[regex]::Match($Text,'(?m)^'+[regex]::Escape($Name)+'\s*=\s*"(?<v>(?:[^"\\]|\\.)*)"\s*$');if(!$m.Success){throw "Missing TOML field: $Name"};return $m.Groups['v'].Value.Replace('\"','"').Replace('\\','\') }
function Copy-ZipEntry([IO.Compression.ZipArchiveEntry]$Source,[IO.Compression.ZipArchiveEntry]$Target) {
    $input=$Source.Open();$output=$Target.Open()
    try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
}
function Write-ZipBytes([IO.Compression.ZipArchive]$Archive,[string]$Name,[byte[]]$Bytes) {
    $entry=$Archive.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal);$stream=$entry.Open()
    try{$stream.Write($Bytes,0,$Bytes.Length)}finally{$stream.Dispose()}
}

foreach($f in @($bootstrapPath,$helperPath,$updaterPath,$bundlePath,$candidateJsonPath)){if(!(Test-Path -LiteralPath $f -PathType Leaf)){throw "Required package source is missing: $f"}}
$bundleHash=(Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($bundleHash -cne [string]$bundleManifest.bundle.sha256 -or (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string](@($bundleManifest.files|Where-Object path -eq 'KxCraft-ManagedFiles.ps1')[0].sha256) -or (Get-FileHash -LiteralPath $updaterPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string](@($bundleManifest.files|Where-Object path -eq 'KxCraft-Updater.ps1')[0].sha256)) { throw 'Updater files do not match the signed candidate manifest.' }
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
    $sourceJar=Join-Path $ClientProfileMinecraftDirectory ('mods\'+$jarName)
    if(!(Test-Path -LiteralPath $sourceJar -PathType Leaf)){throw "Approved local profile JAR is missing: $jarName"}
    $jarItem=Get-Item -LiteralPath $sourceJar
    if($jarItem.Length -ne [long]$record.bytes -or (Get-FileHash -LiteralPath $sourceJar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $jarHash){throw "Local JAR does not match the approved candidate bytes: $jarName"}
    $managedFiles.Add([pscustomobject]@{path=('mods/'+$jarName);sha256=$jarHash})
    $modCount++
}
if($modCount -ne $expectedModCount -or $managedFiles.Count -ne $expectedModCount -or $recordsByName.Count -ne $expectedModCount){throw "Expected exact $expectedModCount/$expectedModCount source, index, and profile records; found $modCount/$($managedFiles.Count)/$($recordsByName.Count)."}
$initialState=[pscustomobject]@{schemaVersion=1;packTomlUrl='https://francho2002.github.io/kxcraft/pack/managed-3players/pack.toml';files=@()}
$bootstrapBytes=[IO.File]::ReadAllBytes($bootstrapPath)
$updaterBytes=[IO.File]::ReadAllBytes($updaterPath)
$helperBytes=[IO.File]::ReadAllBytes($helperPath)
$activeBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject ([pscustomobject]@{schemaVersion=1;channel='managed-3players';sequence=0;updaterVersion=$updaterVersion;bundleSha256=$bundleHash;installDirectoryName=$updaterInstallName;seededByPackage=$true}) -Depth 10))
$prelaunch='PreLaunchCommand=powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\\.minecraft\\KxCraft-Bootstrap.ps1" -Channel "managed-3players"'
$readme=@"
KxCraft $packVersion

Importá esta instancia en PrismLauncher y presioná Jugar.
Antes de abrir Minecraft, KxCraft Bootstrap verifica el manifiesto firmado y Packwiz descarga los $expectedModCount mods necesarios.
En los inicios siguientes, Packwiz sincroniza los archivos nuevos, modificados o retirados del manifiesto vigente.

Si falla la firma, una descarga o la comprobación de integridad, Minecraft no se inicia con una instalación incompleta.
El ZIP no contiene JAR de mods. Conserva la configuración, los resourcepacks, los mapas iniciales y los archivos necesarios de Prism.
"@
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
        'KxCraft/.minecraft/kxcraft-initial-seed/manifest.json'=$true
        'KxCraft/.minecraft/.kxcraft/updaters/managed-3players/active.json'=$true
        ('KxCraft/.minecraft/.kxcraft/updaters/managed-3players/'+$updaterInstallName+'/KxCraft-Updater.ps1')=$true
        ('KxCraft/.minecraft/.kxcraft/updaters/managed-3players/'+$updaterInstallName+'/KxCraft-ManagedFiles.ps1')=$true
        'KxCraft/.minecraft/mods/'=$true
    }
    try{
        foreach($entry in $source.Entries){
            if(!$seen.Add($entry.FullName)){throw "Base ZIP contains duplicate entry: $($entry.FullName)"}
            if($entry.FullName -ceq 'KxCraft/.minecraft/mods/' -or $entry.FullName -match '^KxCraft/\.minecraft/mods/[^/]+\.jar$' -or $entry.FullName -match '^KxCraft/\.minecraft/\.kxcraft/legacy/1\.0\.8-'){continue}
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
        Write-ZipBytes $target 'KxCraft/.minecraft/.kxcraft-packwiz-state.json' ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $initialState -Depth 20)));[void]$added.Add('KxCraft/.minecraft/.kxcraft-packwiz-state.json')
        Write-ZipBytes $target 'KxCraft/.minecraft/KxCraft-AutoUpdate-README.txt' $readmeBytes;[void]$added.Add('KxCraft/.minecraft/KxCraft-AutoUpdate-README.txt')
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
        Write-ZipBytes $target 'KxCraft/.minecraft/.kxcraft/updaters/managed-3players/active.json' $activeBytes;[void]$added.Add('KxCraft/.minecraft/.kxcraft/updaters/managed-3players/active.json')
        $prefix='KxCraft/.minecraft/.kxcraft/updaters/managed-3players/'+$updaterInstallName+'/'
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
$zipHash=(Get-FileHash -LiteralPath $OutputZip -Algorithm SHA256).Hash.ToLowerInvariant()
$sidecar=$OutputZip+'.sha256'
[IO.File]::WriteAllText($sidecar,($zipHash+'  '+[IO.Path]::GetFileName($OutputZip)+[Environment]::NewLine),[Text.Encoding]::ASCII)
Write-Output ('Built private KxCraft package: '+$OutputZip)
Write-Output ('Size bytes: '+(Get-Item -LiteralPath $OutputZip).Length)
Write-Output ('SHA-256: '+$zipHash)
