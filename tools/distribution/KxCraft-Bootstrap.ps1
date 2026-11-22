[CmdletBinding()]
param(
    [ValidateSet('managed-3players')]
    [string]$Channel = 'managed-3players'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:BootstrapVersion = '1.0.0'
$script:ManifestUrl = 'https://francho2002.github.io/kxcraft/updater/manifest.json'
$script:TrustedPublicKeyCspBase64 = 'BgIAAACkAABSU0ExAAwAAAEAAQDVrdlpxrI2oXoq+UeXGeQ9a6ZCUBQCzZeUVC+LuuAEWkxhow3Wh2j3ONqSmRjMXEYahLTiarUlusmPKKyxnbieAlxrqb5R6NMNaf+YSVvttw6sTs2o0lFm1Q3oWAwtjfw65vG4QNd/YNmJDTDT2zMS/mnvBArpRz5uR7+fa8b4zeitHOwCatpxDPX1J0lgTJ0ZiLh7ntAlUQc2yvuFvGkO+d4yC0xH1yvdKmszkFKDokAeRWXYOLPL3oQSev1Dkv8jJdDls+21v7NxwJOQMKO0V62V8GMVrGvyYLgp2SWUfDNSjdYRMMHe4DLGtK4ybLmUbOR1IeFN47LtJHsYd7HTYpyAifziHRJuzwbW11lrY7eXs11TTm6UDw86iaY7djcDXb/GSvVYQ+FtKoZMuZikzUgCvOi1+bdPnG6cz2oKen8WL8xiVojAX6tCifGp9RkBjpS2H3rdJdqUFPuwh7AMgfbWmwYMkWmELl8ZZgfeBwEBGQzDp3NQsBz3SimpO7k='
$script:MaximumManifestBytes = 262144
$script:MaximumBundleBytes = 4194304

function Stop-KxBootstrap([string]$Message) {
    [Console]::Error.WriteLine('KxCraft update blocked: ' + $Message)
    exit 12
}

function Get-KxSha256Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-KxBootstrapHttps([Uri]$Uri, [string]$Kind) {
    if ($Uri.Scheme -cne 'https' -or !$Uri.IsDefaultPort -or ![string]::IsNullOrEmpty($Uri.UserInfo) -or
        ![string]::IsNullOrEmpty($Uri.Query) -or ![string]::IsNullOrEmpty($Uri.Fragment)) {
        throw ($Kind + ' must be a clean HTTPS URL.')
    }
    if ($Kind -eq 'manifest' -and ($Uri.Host -cne 'francho2002.github.io' -or $Uri.AbsolutePath -cne '/kxcraft/updater/manifest.json')) {
        throw 'Updater manifest origin is not the pinned KxCraft GitHub Pages endpoint.'
    }
    if ($Kind -eq 'signature' -and ($Uri.Host -cne 'francho2002.github.io' -or $Uri.AbsolutePath -cne '/kxcraft/updater/manifest.sig')) {
        throw 'Updater signature origin is not the pinned KxCraft GitHub Pages endpoint.'
    }
    if ($Kind -eq 'bundle' -and ($Uri.Host -cne 'raw.githubusercontent.com' -or
        $Uri.AbsolutePath -notmatch '^/Francho2002/kxcraft/[0-9a-f]{40}/distribution-v1/updater/releases/[0-9]+\.[0-9]+\.[0-9]+/KxCraft-Updater\.zip$')) {
        throw 'Updater bundle must use a full-commit URL in the KxCraft repository.'
    }
}

function Get-KxHttpsBytes([Uri]$Uri, [int]$MaximumBytes, [string]$Kind) {
    Assert-KxBootstrapHttps $Uri $Kind
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.UserAgent = 'KxCraft-Bootstrap/' + $script:BootstrapVersion
    $response = $null
    $stream = $null
    $memory = New-Object IO.MemoryStream
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw ($Kind + ' returned HTTP ' + [int]$response.StatusCode + '.') }
        if ($response.ContentLength -gt $MaximumBytes) { throw ($Kind + ' exceeds the permitted size.') }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 32768
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (($memory.Length + $read) -gt $MaximumBytes) { throw ($Kind + ' exceeds the permitted size.') }
            $memory.Write($buffer, 0, $read)
        }
        return ,$memory.ToArray()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $memory.Dispose()
    }
}

function Test-KxManifestSignature([byte[]]$ManifestBytes, [byte[]]$SignatureBytes) {
    $signatureText = [Text.Encoding]::ASCII.GetString($SignatureBytes).Trim()
    $signature = [Convert]::FromBase64String($signatureText)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.ImportCspBlob([Convert]::FromBase64String($script:TrustedPublicKeyCspBase64))
        return [bool]$rsa.VerifyData($ManifestBytes, 'SHA256', $signature)
    } finally { $rsa.Dispose() }
}

function Test-KxSha256([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }

function Get-KxChannelManifest([byte[]]$ManifestBytes) {
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $json = $encoding.GetString($ManifestBytes) | ConvertFrom-Json -ErrorAction Stop
    if ($json.schemaVersion -ne 1 -or [string]$json.state -cne 'PUBLISHED') { throw 'Signed updater manifest is not a published schema-v1 release.' }
    $sequence = 0
    if (![int]::TryParse([string]$json.sequence, [ref]$sequence) -or $sequence -lt 1) { throw 'Updater release sequence is invalid.' }
    if ([string]$json.minimumBootstrapVersion -cne '1.0.0') { throw 'This release requires a newer Bootstrap. Download the current KxCraft.zip and reimport the instance.' }
    if ([string]$json.updaterVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Updater version is invalid.' }
    if (!(Test-KxSha256 ([string]$json.bundle.sha256))) { throw 'Updater bundle SHA-256 is invalid.' }
    $bundleLength = 0L
    if (![long]::TryParse([string]$json.bundle.length, [ref]$bundleLength) -or $bundleLength -lt 1 -or $bundleLength -gt $script:MaximumBundleBytes) { throw 'Updater bundle length is invalid.' }
    $bundleUri = $null
    if (![Uri]::TryCreate([string]$json.bundle.url, [UriKind]::Absolute, [ref]$bundleUri)) { throw 'Updater bundle URL is invalid.' }
    Assert-KxBootstrapHttps $bundleUri 'bundle'
    if ($json.files.Count -ne 2) { throw 'Updater manifest must pin exactly two local PowerShell files.' }
    $expectedFiles = @{ 'KxCraft-Updater.ps1' = $null; 'KxCraft-ManagedFiles.ps1' = $null }
    foreach ($file in $json.files) {
        $path = [string]$file.path
        if (!$expectedFiles.ContainsKey($path) -or !(Test-KxSha256 ([string]$file.sha256))) { throw 'Updater file list is invalid.' }
        $length = 0L
        if (![long]::TryParse([string]$file.length, [ref]$length) -or $length -lt 1 -or $length -gt 1048576) { throw 'Updater file length is invalid.' }
        if ($null -ne $expectedFiles[$path]) { throw 'Updater file list contains a duplicate path.' }
        $expectedFiles[$path] = [pscustomobject]@{ Sha256 = [string]$file.sha256; Length = $length }
    }
    if ($expectedFiles.Values -contains $null) { throw 'Updater manifest omits a required local file.' }
    if (!$json.channels.PSObject.Properties[$Channel]) { throw 'This updater manifest does not provide the selected KxCraft channel.' }
    $channelInfo = $json.channels.$Channel
    $packUrl = [string]$channelInfo.packTomlUrl
    if ($packUrl -cne 'https://francho2002.github.io/kxcraft/pack/managed-3players/pack.toml') { throw 'The configured Packwiz URL does not match the pinned KxCraft channel.' }
    if (!(Test-KxSha256 ([string]$channelInfo.packTomlSha256))) { throw 'Managed Packwiz manifest SHA-256 is invalid.' }
    $modCount = 0
    if (![int]::TryParse([string]$channelInfo.modCount, [ref]$modCount) -or $modCount -lt 1 -or $modCount -gt 512) { throw 'Managed Packwiz channel does not pin a valid bounded mod inventory.' }
    if ([string]$channelInfo.packVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Managed Packwiz channel version is invalid.' }
    return [pscustomobject]@{ Manifest=$json; Sequence=$sequence; BundleUri=$bundleUri; Files=$expectedFiles; PackUrl=$packUrl; PackHash=[string]$channelInfo.packTomlSha256; ModCount=$modCount }
}

function Write-KxAtomicJson([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $jsonText = ConvertTo-Json -InputObject $Value -Depth 20
    [IO.File]::WriteAllText($temporary, $jsonText, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = $Path + '.previous'
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        [IO.File]::Replace($temporary, $Path, $backup, $true)
    } else { [IO.File]::Move($temporary, $Path) }
}

function Expand-KxVerifiedBundle([byte[]]$Bytes, [hashtable]$Files, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    $memory = New-Object IO.MemoryStream(,$Bytes)
    $archive = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        if ($archive.Entries.Count -ne 2) { throw 'Updater ZIP contains unexpected files.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $archive.Entries) {
            $path = [string]$entry.FullName
            if (!$Files.ContainsKey($path) -or !$seen.Add($path) -or $path.Contains('/') -or $path.Contains('\')) { throw 'Updater ZIP contains an unsafe or unexpected path.' }
            if ([long]$entry.Length -ne [long]$Files[$path].Length) { throw ('Updater component length mismatch: ' + $path) }
            $target = Join-Path $Destination $path
            $input = $entry.Open()
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $buffer = New-Object byte[] 32768
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) { $output.Write($buffer,0,$read); [void]$sha.TransformBlock($buffer,0,$read,$buffer,0) }
                [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
                $actual = ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
            } finally { $sha.Dispose(); $output.Dispose(); $input.Dispose() }
            if ($actual -cne [string]$Files[$path].Sha256) { throw ('Updater component SHA-256 mismatch: ' + $path) }
        }
        if ($seen.Count -ne $Files.Count) { throw 'Updater ZIP is missing a required component.' }
    } finally { $archive.Dispose(); $memory.Dispose() }
}

function ConvertTo-KxProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"','$1$1\"'
    $escaped = $escaped -replace '(\\+)$','$1$1'
    return '"' + $escaped + '"'
}

try {
    if ([string]::IsNullOrWhiteSpace($env:INST_MC_DIR)) { throw 'Prism did not provide INST_MC_DIR.' }
    $minecraft = [IO.Path]::GetFullPath($env:INST_MC_DIR)
    $manifestUri = [Uri]$script:ManifestUrl
    $sigUri = [Uri]($script:ManifestUrl -replace 'manifest\.json$','manifest.sig')
    $manifestBytes = Get-KxHttpsBytes $manifestUri $script:MaximumManifestBytes 'manifest'
    $signatureBytes = Get-KxHttpsBytes $sigUri 16384 'signature'
    if (!(Test-KxManifestSignature $manifestBytes $signatureBytes)) { throw 'Updater manifest signature is invalid; no local files were changed.' }
    $release = Get-KxChannelManifest $manifestBytes

    $kxRoot = Join-Path $minecraft '.kxcraft'
    $channelRoot = Join-Path $kxRoot ('updaters\' + $Channel)
    [IO.Directory]::CreateDirectory($channelRoot) | Out-Null
    $statePath = Join-Path $channelRoot 'active.json'
    $oldState = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $oldState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Local updater activation state is corrupt; preserved without changes.' }
        if ([int]$oldState.sequence -gt $release.Sequence) { throw 'Signed updater sequence is older than this installation; refusing rollback.' }
        if ([int]$oldState.sequence -eq $release.Sequence -and [string]$oldState.bundleSha256 -cne [string]$release.Manifest.bundle.sha256) { throw 'Signed updater sequence conflicts with the locally trusted version.' }
    }

    $versionKey = [string]$release.Manifest.updaterVersion + '-' + ([string]$release.Manifest.bundle.sha256).Substring(0,12)
    if ($oldState -and [string]$oldState.bundleSha256 -ceq [string]$release.Manifest.bundle.sha256 -and
        [string]$oldState.installDirectoryName -match '^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{12}(?:-repair-[0-9a-f]{8})?$') {
        $versionKey = [string]$oldState.installDirectoryName
    }
    $versionDirectory = Join-Path $channelRoot $versionKey
    $installedOk = $false
    if (Test-Path -LiteralPath $versionDirectory -PathType Container) {
        $installedOk = $true
        foreach ($path in $release.Files.Keys) {
            $localFile = Join-Path $versionDirectory $path
            if (!(Test-Path -LiteralPath $localFile -PathType Leaf) -or (Get-KxSha256Bytes ([IO.File]::ReadAllBytes($localFile))) -cne [string]$release.Files[$path].Sha256) { $installedOk = $false; break }
        }
        if (!$installedOk) {
            $versionKey = [string]$release.Manifest.updaterVersion + '-' + ([string]$release.Manifest.bundle.sha256).Substring(0,12) + '-repair-' + ([Guid]::NewGuid().ToString('N').Substring(0,8))
            $versionDirectory = Join-Path $channelRoot $versionKey
        }
    }

    if (!$installedOk) {
        Write-Output ('KxCraft: verificando el actualizador ' + $release.Manifest.updaterVersion + '...')
        $bundleBytes = Get-KxHttpsBytes $release.BundleUri $script:MaximumBundleBytes 'bundle'
        if ($bundleBytes.Length -ne [long]$release.Manifest.bundle.length -or (Get-KxSha256Bytes $bundleBytes) -cne [string]$release.Manifest.bundle.sha256) { throw 'Updater bundle integrity check failed; previous version remains active.' }
        $stage = Join-Path $channelRoot ('.stage-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        try {
            Expand-KxVerifiedBundle $bundleBytes $release.Files $stage
            [IO.Directory]::Move($stage, $versionDirectory)
        } catch {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            throw
        }
    }

    $newState = [pscustomobject]@{ schemaVersion=1; channel=$Channel; sequence=$release.Sequence; updaterVersion=[string]$release.Manifest.updaterVersion; bundleSha256=[string]$release.Manifest.bundle.sha256; installDirectoryName=$versionKey; manifestSha256=(Get-KxSha256Bytes $manifestBytes); activatedAtUtc=[DateTime]::UtcNow.ToString('o') }

    $updaterPath = Join-Path $versionDirectory 'KxCraft-Updater.ps1'
    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (!(Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    if (!(Test-Path -LiteralPath $powershell -PathType Leaf)) { throw 'Windows PowerShell 5.1 could not be located.' }
    $argList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$updaterPath,'-PackTomlUrl',$release.PackUrl,'-MinecraftDirectory',$minecraft,'-ExpectedPackSha256',$release.PackHash,'-ExpectedModCount',[string]$release.ModCount)
    $encodedArgs = ($argList | ForEach-Object { ConvertTo-KxProcessArgument ([string]$_) }) -join ' '
    $process = Start-Process -FilePath $powershell -ArgumentList $encodedArgs -WorkingDirectory $minecraft -Wait -PassThru -NoNewWindow -ErrorAction Stop
    if ($process.ExitCode -ne 0) { throw ('Versioned updater failed with exit code ' + $process.ExitCode + '; Minecraft will not start.') }
    Write-KxAtomicJson $statePath $newState
    Write-Output 'KxCraft: actualización verificada. Minecraft puede iniciarse.'
    exit 0
} catch {
    Stop-KxBootstrap $_.Exception.Message
}
