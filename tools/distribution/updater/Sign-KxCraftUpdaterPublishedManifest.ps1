[CmdletBinding()]
param(
    [string]$CandidateRoot = '',
    [string]$ManifestPath = '',
    [string]$SignaturePath = '',
    [string]$PackRoot = '',
    [string]$BundlePath = '',
    [string]$UpdaterPath = '',
    [string]$ManagedFilesPath = '',
    [string]$PublicKeyPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    $activeCandidatePath = Join-Path $projectRoot 'distribution-v1\private-update-manager\active-candidate.json'
    if (!(Test-Path -LiteralPath $activeCandidatePath -PathType Leaf)) { throw 'Active KxCraft candidate pointer is missing.' }
    $activeCandidate = Get-Content -LiteralPath $activeCandidatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $CandidateRoot = [string]$activeCandidate.candidate
}
$CandidateRoot = [IO.Path]::GetFullPath($CandidateRoot)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $CandidateRoot 'site\updater\manifest.json' }
if ([string]::IsNullOrWhiteSpace($SignaturePath)) { $SignaturePath = $ManifestPath -replace '\.json$','.sig' }
if ([string]::IsNullOrWhiteSpace($PackRoot)) { $PackRoot = Join-Path $CandidateRoot 'site\pack\KxCraft' }
if ([string]::IsNullOrWhiteSpace($BundlePath)) { $BundlePath = Join-Path $CandidateRoot 'binaries\distribution-v1\updater\releases\1.0.2\KxCraft-Updater.zip' }
if ([string]::IsNullOrWhiteSpace($UpdaterPath)) { $UpdaterPath = Join-Path $projectRoot 'tools\distribution\updater\KxCraft-Updater.ps1' }
if ([string]::IsNullOrWhiteSpace($ManagedFilesPath)) { $ManagedFilesPath = Join-Path $projectRoot 'tools\packwiz\KxCraft-ManagedFiles.ps1' }
if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = Join-Path $projectRoot 'tools\distribution\updater\public-key.csp.base64' }

foreach ($path in @($ManifestPath,$PackRoot,$BundlePath,$UpdaterPath,$ManagedFilesPath,$PublicKeyPath)) {
    if (!(Test-Path -LiteralPath $path)) { throw "Required publication input is missing: $path" }
}

function Get-KxFileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Test-KxSha256([string]$Value) { return $Value -match '^[0-9a-f]{64}$' }

$manifestBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($ManifestPath))
$manifest = [Text.UTF8Encoding]::new($false,$true).GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
if ($manifest.schemaVersion -ne 1 -or [string]$manifest.state -cne 'PUBLISHED') { throw 'Published-manifest signer accepts only schema-v1 PUBLISHED manifests.' }
if ([int]$manifest.sequence -ne 4 -or [string]$manifest.updaterVersion -cne '1.0.2' -or [string]$manifest.minimumBootstrapVersion -cne '1.0.0') { throw 'Updater release version or sequence is invalid.' }

$bundleUri = [Uri]([string]$manifest.bundle.url)
if ($bundleUri.Scheme -cne 'https' -or $bundleUri.Host -cne 'raw.githubusercontent.com' -or
    $bundleUri.AbsoluteUri -notmatch ('^https://raw\.githubusercontent\.com/Francho2002/kxcraft/[0-9a-f]{40}/distribution-v1/updater/releases/' + [regex]::Escape([string]$manifest.updaterVersion) + '/KxCraft-Updater\.zip$')) {
    throw 'Published Updater bundle URL must pin the approved file to a full commit SHA in Francho2002/kxcraft.'
}
if (!(Test-KxSha256 ([string]$manifest.bundle.sha256)) -or [long]$manifest.bundle.length -lt 1 -or [long]$manifest.bundle.length -gt 1048576) { throw 'Published bundle length or SHA-256 is invalid.' }

$bundleSha = Get-KxFileSha256 ([IO.Path]::GetFullPath($BundlePath))
if ((Get-Item -LiteralPath $BundlePath).Length -ne [long]$manifest.bundle.length -or $bundleSha -cne [string]$manifest.bundle.sha256) { throw 'Local Updater bundle does not match its manifest pin.' }

$remoteTemp = Join-Path $env:TEMP ('kxcraft-published-updater-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    Invoke-WebRequest -Uri $bundleUri.AbsoluteUri -OutFile $remoteTemp -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop | Out-Null
    if (!(Test-Path -LiteralPath $remoteTemp -PathType Leaf) -or (Get-Item -LiteralPath $remoteTemp).Length -ne [long]$manifest.bundle.length -or (Get-KxFileSha256 $remoteTemp) -cne [string]$manifest.bundle.sha256) {
        throw 'Remote Updater bundle did not return the exact published bytes.'
    }
} finally {
    Remove-Item -LiteralPath $remoteTemp -Force -ErrorAction SilentlyContinue
}

$packGatePath = Join-Path $PackRoot 'release.json'
$packPath = Join-Path $PackRoot 'pack.toml'
$indexPath = Join-Path $PackRoot 'index.toml'
foreach ($path in @($packGatePath,$packPath,$indexPath)) { if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Published Packwiz file is missing: $path" } }
$packGate = Get-Content -LiteralPath $packGatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$packHash = Get-KxFileSha256 $packPath
$indexHash = Get-KxFileSha256 $indexPath
$packText = [IO.File]::ReadAllText($packPath)
$indexHashMatch = [regex]::Match($packText,'(?ms)^\[index\]\s+file\s*=\s*"index\.toml"\s+hash-format\s*=\s*"sha256"\s+hash\s*=\s*"([0-9a-f]{64})"')
$indexText = [IO.File]::ReadAllText($indexPath)
$indexEntryCount = [regex]::Matches($indexText,'(?m)^\[\[files\]\]\s*$').Count
if (!$indexHashMatch.Success -or $indexHashMatch.Groups[1].Value -cne $indexHash -or $indexEntryCount -ne [int]$packGate.modCount) { throw 'Packwiz index hash or entry count does not match release.json.' }
if ($packGate.schemaVersion -ne 1 -or [string]$packGate.state -cne 'PUBLISHED' -or [string]$packGate.releaseVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [int]$packGate.modCount -lt 1 -or [int]$packGate.modCount -gt 512 -or [int]$packGate.indexEntryCount -ne [int]$packGate.modCount -or [string]$packGate.packTomlUrl -cne 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml' -or
    [string]$packGate.packTomlSha256 -cne $packHash) { throw 'Packwiz release gate is not a valid, hash-consistent published snapshot.' }
$manifestChannels = @($manifest.channels.PSObject.Properties | ForEach-Object { $_.Name })
if ($manifestChannels.Count -ne 1 -or $manifestChannels[0] -cne 'KxCraft') { throw 'Published updater manifest must contain only the permanent KxCraft channel.' }
$channel = $manifest.channels.'KxCraft'
if ($null -eq $channel -or [string]$channel.packVersion -cne [string]$packGate.releaseVersion -or [string]$channel.packTomlUrl -cne [string]$packGate.packTomlUrl -or
    [string]$channel.packTomlSha256 -cne $packHash -or [int]$channel.modCount -ne [int]$packGate.modCount) { throw 'Signed updater manifest does not pin the published Packwiz release.' }

$expectedFiles = @{
    'KxCraft-Updater.ps1' = [IO.Path]::GetFullPath($UpdaterPath)
    'KxCraft-ManagedFiles.ps1' = [IO.Path]::GetFullPath($ManagedFilesPath)
}
if (@($manifest.files).Count -ne 2) { throw 'Updater manifest must pin exactly two files.' }
foreach ($entry in $manifest.files) {
    $name = [string]$entry.path
    if (!$expectedFiles.ContainsKey($name) -or !(Test-KxSha256 ([string]$entry.sha256))) { throw "Unexpected Updater component pin: $name" }
    $componentPath = $expectedFiles[$name]
    if ([long]$entry.length -ne (Get-Item -LiteralPath $componentPath).Length -or (Get-KxFileSha256 $componentPath) -cne [string]$entry.sha256) {
        throw "Updater component does not match the published pin: $name"
    }
}
$protectedPath = Join-Path $env:LOCALAPPDATA 'KxCraft\DistributionTrust\updater-signing-key.dpapi'
if (!(Test-Path -LiteralPath $protectedPath -PathType Leaf)) { throw 'DPAPI-protected KxCraft signing key is unavailable for this Windows user.' }
$entropy = [Text.Encoding]::UTF8.GetBytes('KxCraft Distribution V1 signing key, schema 1')
$privateBlob = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($protectedPath),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
$signer = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
    $signer.PersistKeyInCsp = $false
    $signer.ImportCspBlob($privateBlob)
    $signature = $signer.SignData($manifestBytes,'SHA256')
} finally {
    [Array]::Clear($privateBlob,0,$privateBlob.Length)
    $signer.Dispose()
}

$publicBlob = [Convert]::FromBase64String((Get-Content -LiteralPath $PublicKeyPath -Raw).Trim())
$verifier = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
    $verifier.PersistKeyInCsp = $false
    $verifier.ImportCspBlob($publicBlob)
    if (!$verifier.VerifyData($manifestBytes,'SHA256',$signature)) { throw 'The generated RSA signature failed local verification.' }
} finally { $verifier.Dispose() }

[IO.File]::WriteAllText([IO.Path]::GetFullPath($SignaturePath),[Convert]::ToBase64String($signature) + "`n",(New-Object Text.UTF8Encoding($false)))
Write-Output ('Published manifest signature verified: ' + [IO.Path]::GetFullPath($SignaturePath))
Write-Output ('Manifest SHA-256: ' + (Get-KxFileSha256 ([IO.Path]::GetFullPath($ManifestPath))))
Write-Output ('Remote bundle SHA-256 verified: ' + $bundleSha)
Write-Output ('Packwiz ' + [string]$packGate.releaseVersion + '/' + [string]$packGate.modCount + '-mod snapshot SHA-256: ' + $packHash)
