[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$PublishedBasePackagePath,
    [Parameter(Mandatory = $true)][string]$BootstrapPath,
    [Parameter(Mandatory = $true)][string]$ClientConfigPath,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$ManifestSignaturePath,
    [Parameter(Mandatory = $true)][string]$PublicKeyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$validationModulePath = Join-Path $PSScriptRoot 'KxCraftPackageValidation.psm1'
Import-Module $validationModulePath -Force
$packagePath = [IO.Path]::GetFullPath($PackagePath)
$basePackagePath = [IO.Path]::GetFullPath($PublishedBasePackagePath)
$bootstrapPath = [IO.Path]::GetFullPath($BootstrapPath)
$expectedBaseHash = '26c6f2c26949b2529c98ca82f4f05ce57320682c78245211dbc6da900bee4e4a'
$expectedPackUrl = 'https://francho2002.github.io/kxcraft/pack/KxCraft/pack.toml'
$expectedPackVersion = '1.0.15'
$expectedModCount = 201
$expectedCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\.minecraft\KxCraft-Bootstrap.ps1" -Channel KxCraft'
$builderPath = Join-Path $PSScriptRoot 'Build-KxCraftSelfUpdatingPackages.ps1'
$builderText = [IO.File]::ReadAllText($builderPath)
$sourceBytes = [IO.File]::ReadAllBytes($bootstrapPath)
$sourceText = [Text.UTF8Encoding]::new($false, $true).GetString($sourceBytes)
$checks = [Collections.Generic.List[string]]::new()

function Assert-PrelaunchTest([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw ('FAIL: ' + $Message) }
    $script:checks.Add($Message)
}

function Assert-ValidationRejects([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-PrelaunchTest $rejected $Message
}

function Get-ZipEntryHash([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function ConvertFrom-QSettingsEscapes([string]$Value) {
    $builder = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ([int][char]$Value[$i] -eq 92 -and $i + 1 -lt $Value.Length) {
            $next = [int][char]$Value[$i + 1]
            if ($next -eq 92 -or $next -eq 34) {
                [void]$builder.Append([char]$next)
                $i++
                continue
            }
        }
        [void]$builder.Append($Value[$i])
    }
    return $builder.ToString()
}

Assert-PrelaunchTest ((Get-FileHash -LiteralPath $basePackagePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedBaseHash) 'The comparison ZIP is the exact public KxCraft 1.0.15 baseline.'
Assert-PrelaunchTest ($builderText.Contains("Import-Module `$validationModulePath -Force") -and $builderText.Contains('Assert-KxPackageCoherence -PackagePath $OutputZip') -and $builderText.Contains('-ClientConfigPath $clientAeroStructuresConfigPath') -and $builderText.Contains('-ExpectedPreLaunchCommand $prelaunchCommand')) 'The package generator invokes the shared signed-manifest, Bootstrap, client-config, ZIP-payload, and Pre-Launch validator after building.'
Assert-PrelaunchTest ($builderText.Contains('[switch]$PackageOnly') -and $builderText.Contains('without editing release metadata or pages')) 'The generator supports a package-only candidate build without changing release metadata or web pages.'

$manifestBytes = [IO.File]::ReadAllBytes($ManifestPath)
$manifest = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
$coherence = Assert-KxPackageCoherence -PackagePath $packagePath -BootstrapPath $bootstrapPath -ClientConfigPath $ClientConfigPath -ManifestPath $ManifestPath -ManifestSignaturePath $ManifestSignaturePath -PublicKeyPath $PublicKeyPath -ExpectedPreLaunchCommand $expectedCommand -ExpectedPackVersion $expectedPackVersion -ExpectedModCount $expectedModCount
Assert-PrelaunchTest ($coherence.ManifestSequence -eq 7 -and $coherence.PackVersion -ceq $expectedPackVersion -and $coherence.ModCount -eq $expectedModCount -and $coherence.PackTomlUrl -ceq $expectedPackUrl) 'The production RSA signature is valid and sequence 7 pins KxCraft 1.0.15/201 at the permanent Packwiz URL.'
Assert-PrelaunchTest ((Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $coherence.BootstrapSha256) 'The Bootstrap inside the ZIP is byte-identical to the checked source file.'
Assert-PrelaunchTest ($coherence.ClientConfigSha256 -ceq (Get-FileHash -LiteralPath $ClientConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'The package contains the checked client Create Aeronautics Structures config with its login message disabled.'

$archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
$baseArchive = [IO.Compression.ZipFile]::OpenRead($basePackagePath)
try {
    $packageNames = @($archive.Entries | ForEach-Object { $_.FullName })
    $baseNames = @($baseArchive.Entries | ForEach-Object { $_.FullName })
    $duplicates = @($packageNames | Group-Object | Where-Object Count -gt 1)
    $inventoryDiff = @(Compare-Object -ReferenceObject $baseNames -DifferenceObject $packageNames)
    $addedEntries = @($inventoryDiff | Where-Object SideIndicator -eq '=>' | Select-Object -ExpandProperty InputObject)
    $removedEntries = @($inventoryDiff | Where-Object SideIndicator -eq '<=' | Select-Object -ExpandProperty InputObject)
    Assert-PrelaunchTest ($duplicates.Count -eq 0 -and $addedEntries.Count -eq 1 -and $addedEntries[0] -ceq 'KxCraft/.minecraft/config/cr_aero_structures-client.toml' -and $removedEntries.Count -eq 0) 'The candidate adds only the requested client config, removes no ZIP entries, and has no duplicate paths.'

    $jarEntries = @($archive.Entries | Where-Object { $_.FullName -match '^KxCraft/\.minecraft/mods/[^/]+\.jar$' })
    Assert-PrelaunchTest ($jarEntries.Count -eq 0) 'The Prism ZIP remains lightweight and contains no mod JARs.'

    $changedEntries = [Collections.Generic.List[string]]::new()
    foreach ($entry in $baseArchive.Entries) {
        $other = $archive.GetEntry($entry.FullName)
        if ((Get-ZipEntryHash $entry) -cne (Get-ZipEntryHash $other)) { $changedEntries.Add($entry.FullName) }
    }
    $changedSorted = @($changedEntries | Sort-Object)
    $expectedChanged = @('KxCraft/.minecraft/KxCraft-Bootstrap.ps1', 'KxCraft/instance.cfg') | Sort-Object
    Assert-PrelaunchTest ($changedSorted.Count -eq 2 -and $changedSorted[0] -ceq $expectedChanged[0] -and $changedSorted[1] -ceq $expectedChanged[1]) 'Among entries already in the public ZIP, only instance.cfg and the packaged Bootstrap payload change; the requested client config is the only new entry.'

    $configEntry = $archive.GetEntry('KxCraft/instance.cfg')
    $reader = [IO.StreamReader]::new($configEntry.Open(), [Text.Encoding]::UTF8, $true)
    try { $configText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $prelaunchLines = @([regex]::Split($configText, "`r?`n") | Where-Object { $_ -match '^PreLaunchCommand=' })
    Assert-PrelaunchTest ($prelaunchLines.Count -eq 1) 'instance.cfg has exactly one PreLaunchCommand.'

    $decodedCommand = ConvertFrom-QSettingsEscapes $prelaunchLines[0].Substring('PreLaunchCommand='.Length)
    $testInstanceDirectory = 'C:\QA Profiles With Spaces\PrismLauncher\instances\KxCraft 1.0.15 Hotfix 1'
    $decodedCommand = $decodedCommand.Replace('$INST_DIR', $testInstanceDirectory)
    if (!('KxCraftPrelaunchWindowsArgv' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class KxCraftPrelaunchWindowsArgv
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argc);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Parse(string commandLine)
    {
        int argc;
        IntPtr argv = CommandLineToArgvW(commandLine, out argc);
        if (argv == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            string[] result = new string[argc];
            for (int i = 0; i < argc; i++)
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        }
        finally { LocalFree(argv); }
    }
}
'@
    }
    $argv = [KxCraftPrelaunchWindowsArgv]::Parse($decodedCommand)
    $expectedBootstrapPath = $testInstanceDirectory + '\.minecraft\KxCraft-Bootstrap.ps1'
    Assert-PrelaunchTest ($argv.Count -eq 9 -and $argv[0] -ceq 'powershell.exe' -and $argv[5] -ceq '-File' -and $argv[6] -ceq $expectedBootstrapPath -and $argv[7] -ceq '-Channel' -and $argv[8] -ceq 'KxCraft' -and $decodedCommand -notmatch 'KxCraft-Bootstrap\.ps1-Channel') 'CommandLineToArgvW keeps the spaced Bootstrap path as the sole -File argument and the KxCraft channel separate.'
}
finally { $baseArchive.Dispose(); $archive.Dispose() }

$wrongChannelConfig = '[General]' + "`n" + 'PreLaunchCommand=powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"$INST_DIR\\.minecraft\\KxCraft-Bootstrap.ps1\" -Channel managed-3players' + "`n"
Assert-ValidationRejects { Assert-KxPreLaunchConfig -ConfigText $wrongChannelConfig -ExpectedCommand $expectedCommand } 'The shared validator rejects a ZIP config that names a channel other than KxCraft.'
$concatenatedConfig = '[General]' + "`n" + 'PreLaunchCommand=powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $INST_DIR\\.minecraft\\KxCraft-Bootstrap.ps1-Channel KxCraft' + "`n"
Assert-ValidationRejects { Assert-KxPreLaunchConfig -ConfigText $concatenatedConfig -ExpectedCommand $expectedCommand } 'The shared validator rejects a Prism command whose QSettings escaping would concatenate -Channel into the script path.'
$wrongRouteText = $sourceText.Replace($expectedPackUrl, 'https://francho2002.github.io/kxcraft/pack/other/pack.toml')
Assert-ValidationRejects { Assert-KxBootstrapAndManifestPolicy -BootstrapText $wrongRouteText -Manifest $manifest -ExpectedPackVersion $expectedPackVersion -ExpectedModCount $expectedModCount } 'The shared validator rejects a Bootstrap whose Packwiz URL differs from the signed manifest.'
$wrongChannelManifest = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$wrongChannelManifest.channels.KxCraft.packTomlUrl = 'https://francho2002.github.io/kxcraft/pack/other/pack.toml'
Assert-ValidationRejects { Assert-KxBootstrapAndManifestPolicy -BootstrapText $sourceText -Manifest $wrongChannelManifest -ExpectedPackVersion $expectedPackVersion -ExpectedModCount $expectedModCount } 'The shared validator rejects a manifest with a Packwiz URL outside the permanent channel.'
$tamperedBootstrapBytes = [byte[]]::new($sourceBytes.Length)
[Array]::Copy($sourceBytes, $tamperedBootstrapBytes, $sourceBytes.Length)
$tamperedBootstrapBytes[0] = $tamperedBootstrapBytes[0] -bxor 1
Assert-ValidationRejects { Assert-KxPackagedBootstrapBytes -SourceBytes $sourceBytes -PackagedBytes $tamperedBootstrapBytes } 'The shared validator rejects a packaged Bootstrap that differs by even one byte from the inspected source.'

$packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
$packageLength = [long](Get-Item -LiteralPath $packagePath).Length
Write-Output ("PASS: {0} assertions; ZIP bytes={1}; SHA-256={2}; Bootstrap SHA-256={3}; signed sequence={4}." -f $checks.Count, $packageLength, $packageHash, $coherence.BootstrapSha256, $coherence.ManifestSequence)
