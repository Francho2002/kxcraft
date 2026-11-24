[CmdletBinding()]
param([string]$PackRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$updaterPath = Join-Path $PSScriptRoot 'KxCraft-Updater.ps1'
if ([string]::IsNullOrWhiteSpace($PackRoot)) { $PackRoot = Join-Path $projectRoot 'site\pack\KxCraft' }
$PackRoot = [IO.Path]::GetFullPath($PackRoot)
if (!(Test-Path -LiteralPath $updaterPath -PathType Leaf)) { throw 'Updater source is missing.' }
if (!(Test-Path -LiteralPath (Join-Path $PackRoot 'index.toml') -PathType Leaf)) { throw 'Packwiz index is missing.' }

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($updaterPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Updater source has PowerShell parse errors.' }
$functionAst = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-KxCraftImmutableModUrl' }, $false) | Select-Object -First 1
if ($null -eq $functionAst) { throw 'Immutable URL validator was not found in the Updater source.' }
Invoke-Expression $functionAst.Extent.Text

$commit = 'a1234567890abcdef1234567890abcdef1234567'
$plain = 'https://raw.githubusercontent.com/Francho2002/kxcraft/' + $commit + '/binaries/mods/example.jar'
$validCases = @(
    @{ Url=$plain; File='example.jar' },
    @{ Url=('https://raw.githubusercontent.com/Francho2002/kxcraft/' + $commit + '/binaries/mods/1.0.12/example.jar'); File='example.jar' },
    @{ Url=('https://raw.githubusercontent.com/Francho2002/kxcraft/' + $commit + '/binaries/mods/1.0.12-rc.1+build.2/example.jar'); File='example.jar' },
    @{ Url='https://raw.githubusercontent.com/Francho2002/kxcraft/8059b7e8c502a64c8e106cc054913b6b222e9c43/binaries/mods/1.0.12/create-military-integration-0.1.0-dev.jar'; File='create-military-integration-0.1.0-dev.jar' }
)
foreach ($case in $validCases) {
    $relative = 'mods/' + $case.File + '.pw.toml'
    Assert-KxCraftImmutableModUrl $case.Url $relative $case.File
}

$invalidCases = @(
    @{ Url=($plain + '?download=1'); File='example.jar' },
    @{ Url=($plain + '#fragment'); File='example.jar' },
    @{ Url=$plain.Replace('https://','http://'); File='example.jar' },
    @{ Url=$plain.Replace('Francho2002','OtherOwner'); File='example.jar' },
    @{ Url=$plain.Replace('/kxcraft/','/other-repo/'); File='example.jar' },
    @{ Url=$plain.Replace($commit,'0123456789abcdef0123456789abcdef012345'); File='example.jar' },
    @{ Url=$plain.Replace($commit,'main'); File='example.jar' },
    @{ Url=$plain.Replace('/binaries/mods/example.jar','/binaries/mods/latest/example.jar'); File='example.jar' },
    @{ Url=$plain.Replace('/binaries/mods/example.jar','/binaries/mods/not-a-version/example.jar'); File='example.jar' },
    @{ Url=$plain.Replace('/binaries/mods/example.jar','/binaries/mods/01.0.12/example.jar'); File='example.jar' },
    @{ Url=$plain.Replace('/binaries/mods/example.jar','/binaries/mods/1.0.12/extra/example.jar'); File='example.jar' },
    @{ Url=$plain.Replace('example.jar','other.jar'); File='example.jar' },
    @{ Url=$plain.Replace('raw.githubusercontent.com','raw.githubusercontent.com.evil'); File='example.jar' },
    @{ Url=$plain.Replace('https://','https://user@'); File='example.jar' },
    @{ Url=$plain.Replace('raw.githubusercontent.com/','raw.githubusercontent.com:8443/'); File='example.jar' }
)
foreach ($case in $invalidCases) {
    $rejected = $false
    try { Assert-KxCraftImmutableModUrl $case.Url 'mods/example.jar.pw.toml' $case.File }
    catch { $rejected = $true }
    if (!$rejected) { throw ('Unsafe GitHub URL was accepted: ' + $case.Url) }
}

$metafiles = @(Get-ChildItem -LiteralPath (Join-Path $PackRoot 'mods') -Filter '*.pw.toml' -File)
if ($metafiles.Count -ne 202) { throw ('Expected 202 Packwiz mod metafiles; found ' + $metafiles.Count) }
$githubUrls = 0
$cmiFound = $false
foreach ($meta in $metafiles) {
    $text = [IO.File]::ReadAllText($meta.FullName)
    $filenameMatch = [regex]::Match($text, '(?m)^filename\s*=\s*"([^"]+)"\s*$')
    $urlMatch = [regex]::Match($text, '(?m)^url\s*=\s*"([^"]+)"\s*$')
    $hashMatch = [regex]::Match($text, '(?m)^hash\s*=\s*"([0-9a-fA-F]{64})"\s*$')
    if (!$filenameMatch.Success -or !$urlMatch.Success -or !$hashMatch.Success) { throw ('Incomplete filename, URL, or SHA-256 metadata: ' + $meta.Name) }
    $filename = $filenameMatch.Groups[1].Value
    $url = $urlMatch.Groups[1].Value
    $uri = $null
    if (![Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { throw ('Invalid absolute mod URL: ' + $meta.Name) }
    if ($uri.Host -ceq 'raw.githubusercontent.com') {
        $relative = 'mods/' + $filename + '.pw.toml'
        Assert-KxCraftImmutableModUrl $url $relative $filename
        $githubUrls++
    }
    if ($filename -ceq 'create-military-integration-0.1.0-dev.jar') {
        $expectedCmiUrl = 'https://raw.githubusercontent.com/Francho2002/kxcraft/8059b7e8c502a64c8e106cc054913b6b222e9c43/binaries/mods/1.0.12/create-military-integration-0.1.0-dev.jar'
        if ($url -cne $expectedCmiUrl -or $hashMatch.Groups[1].Value -cne 'd730eea48dc354283de43e3d988a43b5e010d473d3d6d5e8de7ce83a61457fe0') { throw 'CMI metafile URL or approved SHA-256 changed.' }
        $cmiFound = $true
    }
}
if ($githubUrls -ne 22) { throw ('Expected to validate all 22 GitHub mod URLs; found ' + $githubUrls) }
if (!$cmiFound) { throw 'Approved CMI entry was not found in the 202-mod Packwiz inventory.' }

[pscustomobject]@{
    result = 'PASS'
    urlPolicyCasesAccepted = $validCases.Count
    unsafeUrlCasesRejected = $invalidCases.Count
    packModMetafiles = $metafiles.Count
    gitHubUrlsValidated = $githubUrls
    cmiVersionedUrlAccepted = $cmiFound
    packRoot = $PackRoot
} | ConvertTo-Json -Depth 4
