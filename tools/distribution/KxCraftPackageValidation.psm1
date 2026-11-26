Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KxPermanentPackTomlUrl = 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml'

function Get-KxValidationSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-KxZipEntryBytes([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        return ,$memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}

function Assert-KxBootstrapAndManifestPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapText,
        [Parameter(Mandatory = $true)][psobject]$Manifest,
        [Parameter(Mandatory = $true)][string]$ExpectedPackVersion,
        [Parameter(Mandatory = $true)][int]$ExpectedModCount
    )

    if ($BootstrapText -notmatch '(?m)^\s*\[ValidateSet\(''KxCraft''\)\]\s*$' -or
        $BootstrapText -notmatch '(?m)^\s*\[string\]\$Channel\s*=\s*''KxCraft''\s*$') {
        throw 'Bootstrap must accept only the permanent KxCraft channel and default to it.'
    }
    if ($BootstrapText -notmatch '(?m)^\$script:PackTomlUrl\s*=\s*''https://francho2002\.github\.io/kxcraft/pack/KxCraft/pack\.toml''\s*$') {
        throw 'Bootstrap Packwiz URL differs from the permanent KxCraft URL.'
    }
    if ($BootstrapText -match '(?i)managed-3players|private-3players') {
        throw 'Bootstrap contains a reference to a retired channel.'
    }

    $channelProperties = @($Manifest.channels.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
    if ([string]$Manifest.state -cne 'PUBLISHED' -or $channelProperties.Count -ne 1 -or
        $channelProperties[0].Name -cne 'KxCraft' -or
        [string]$Manifest.channels.KxCraft.packTomlUrl -cne $script:KxPermanentPackTomlUrl -or
        [string]$Manifest.channels.KxCraft.packVersion -cne $ExpectedPackVersion -or
        [int]$Manifest.channels.KxCraft.modCount -ne $ExpectedModCount) {
        throw 'Signed manifest and Bootstrap do not agree on the permanent KxCraft channel, Packwiz URL, version, and inventory.'
    }
}

function ConvertTo-KxQSettingsValue([string]$Value) {
    $backslash = [string][char]92
    $quote = [string][char]34
    return $Value.Replace($backslash, $backslash + $backslash).Replace($quote, $backslash + $quote)
}

function Assert-KxPreLaunchConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigText,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand
    )

    $lines = @([regex]::Split($ConfigText, "`r?`n") | Where-Object { $_ -match '^PreLaunchCommand=' })
    $expectedLine = 'PreLaunchCommand=' + (ConvertTo-KxQSettingsValue $ExpectedCommand)
    if ($lines.Count -ne 1 -or $lines[0] -cne $expectedLine -or $lines[0] -match 'KxCraft-Bootstrap\.ps1-Channel') {
        throw 'Prism instance.cfg does not preserve the separate Pre-Launch -File and -Channel arguments.'
    }
}

function Assert-KxPackagedBootstrapBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$SourceBytes,
        [Parameter(Mandatory = $true)][byte[]]$PackagedBytes
    )

    if ($SourceBytes.Length -ne $PackagedBytes.Length -or
        (Get-KxValidationSha256 $SourceBytes) -cne (Get-KxValidationSha256 $PackagedBytes)) {
        throw 'Packaged Bootstrap bytes differ from the source file that was checked.'
    }
}

function Assert-KxPackageCoherence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [string]$InitialProfileSeedDirectory = '',
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ManifestSignaturePath,
        [Parameter(Mandatory = $true)][string]$PublicKeyPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPreLaunchCommand,
        [Parameter(Mandatory = $true)][string]$ExpectedPackVersion,
        [Parameter(Mandatory = $true)][int]$ExpectedModCount
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $manifestBytes = [IO.File]::ReadAllBytes($ManifestPath)
    $signatureBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($ManifestSignaturePath)).Trim())
    $publicKeyBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($PublicKeyPath)).Trim())
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.ImportCspBlob($publicKeyBytes)
        if (!$rsa.VerifyData($manifestBytes, 'SHA256', $signatureBytes)) { throw 'Updater manifest signature verification failed.' }
    }
    finally { $rsa.Dispose() }

    $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
    $sourceBytes = [IO.File]::ReadAllBytes($BootstrapPath)
    $sourceText = [Text.UTF8Encoding]::new($false, $true).GetString($sourceBytes)
    Assert-KxBootstrapAndManifestPolicy -BootstrapText $sourceText -Manifest $manifest -ExpectedPackVersion $ExpectedPackVersion -ExpectedModCount $ExpectedModCount

    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $bootstrapEntries = @($archive.Entries | Where-Object { $_.FullName -ceq 'KxCraft/.minecraft/KxCraft-Bootstrap.ps1' })
        $configEntries = @($archive.Entries | Where-Object { $_.FullName -ceq 'KxCraft/instance.cfg' })
        if ($bootstrapEntries.Count -ne 1 -or $configEntries.Count -ne 1) { throw 'Package must contain exactly one instance.cfg and one Bootstrap.' }
        $packagedBootstrapBytes = Read-KxZipEntryBytes $bootstrapEntries[0]
        Assert-KxPackagedBootstrapBytes -SourceBytes $sourceBytes -PackagedBytes $packagedBootstrapBytes
        $seedResults = @()
        if (![string]::IsNullOrWhiteSpace($InitialProfileSeedDirectory)) {
            $seedRoot = [IO.Path]::GetFullPath($InitialProfileSeedDirectory)
            $seedMap = [ordered]@{
                'options.txt' = 'KxCraft/.minecraft/options.txt'
                'config/cr_aero_structures-client.toml' = 'KxCraft/.minecraft/config/cr_aero_structures-client.toml'
                'config/ragdoll_corpse-common.toml' = 'KxCraft/.minecraft/config/ragdoll_corpse-common.toml'
                'config/voicechat/voicechat-client.properties' = 'KxCraft/.minecraft/config/voicechat/voicechat-client.properties'
                'resourcepacks/KxCraft-SimpleVoiceChat-es_ar.zip' = 'KxCraft/.minecraft/resourcepacks/KxCraft-SimpleVoiceChat-es_ar.zip'
            }
            foreach ($relative in $seedMap.Keys) {
                $seedPath = Join-Path $seedRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
                if (!(Test-Path -LiteralPath $seedPath -PathType Leaf)) { throw "Required initial profile seed file is missing: $relative" }
                $entries = @($archive.Entries | Where-Object { $_.FullName -ceq [string]$seedMap[$relative] })
                if ($entries.Count -ne 1) { throw "Initial profile seed entry is missing or duplicated: $($seedMap[$relative])" }
                $sourceSeedBytes = [IO.File]::ReadAllBytes($seedPath)
                $packageSeedBytes = Read-KxZipEntryBytes $entries[0]
                if ($sourceSeedBytes.Length -ne $packageSeedBytes.Length -or (Get-KxValidationSha256 $sourceSeedBytes) -cne (Get-KxValidationSha256 $packageSeedBytes)) {
                    throw "Packaged initial profile seed differs from its checked source: $relative"
                }
                $seedResults += [pscustomobject]@{ Path = [string]$seedMap[$relative]; Sha256 = Get-KxValidationSha256 $packageSeedBytes }
            }
        }
        $configBytes = Read-KxZipEntryBytes $configEntries[0]
        $configText = [Text.UTF8Encoding]::new($false, $true).GetString($configBytes)
        Assert-KxPreLaunchConfig -ConfigText $configText -ExpectedCommand $ExpectedPreLaunchCommand

        return [pscustomobject]@{
            BootstrapSha256 = Get-KxValidationSha256 $packagedBootstrapBytes
            ManifestSequence = [int]$manifest.sequence
            PackVersion = [string]$manifest.channels.KxCraft.packVersion
            ModCount = [int]$manifest.channels.KxCraft.modCount
            PackTomlUrl = [string]$manifest.channels.KxCraft.packTomlUrl
            InstanceConfigSha256 = Get-KxValidationSha256 $configBytes
            InitialProfileSeed = @($seedResults)
        }
    }
    finally { $archive.Dispose() }
}

Export-ModuleMember -Function Assert-KxBootstrapAndManifestPolicy, Assert-KxPreLaunchConfig, Assert-KxPackagedBootstrapBytes, Assert-KxPackageCoherence
