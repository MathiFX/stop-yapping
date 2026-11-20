#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Development')]
param(
    [Parameter(ParameterSetName = 'Release', Mandatory = $true)]
    [string] $Publisher,
    [ValidatePattern('^\d+\.\d+\.\d+\.0$')]
    [string] $Version = '0.1.0.0',
    [string] $Dotnet = 'dotnet'
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '..\src\StopYapping\StopYapping.csproj'
$artifacts = Join-Path $PSScriptRoot '..\artifacts'
$development = $PSCmdlet.ParameterSetName -eq 'Development'
$channel = if ($development) { 'development' } else { 'unsigned-release' }
$work = Join-Path $artifacts $channel
$payload = Join-Path $work ('payload-' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $work "StopYapping-$Version-x64.msix"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

& $Dotnet restore (Join-Path $PSScriptRoot 'BuildTools.csproj') --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'Could not restore Windows SDK Build Tools.' }
$toolPackage = Get-Content (Join-Path $PSScriptRoot 'obj\project.assets.json') -Raw | ConvertFrom-Json
$nugetRoot = $toolPackage.packageFolders.PSObject.Properties.Name | Select-Object -First 1
$sdkTools = Join-Path $nugetRoot 'microsoft.windows.sdk.buildtools\10.0.28000.2957\bin\10.0.28000.0\x64'
$makeAppx = Join-Path $sdkTools 'makeappx.exe'
if (!(Test-Path -LiteralPath $makeAppx)) { throw 'MakeAppx.exe was not found in the restored Windows SDK.' }

$appVersion = $Version -replace '\.0$', ''
& $Dotnet publish $project -c Release -r win-x64 --self-contained -p:ContinuousIntegrationBuild=true -p:RestoreLockedMode=true "-p:Version=$appVersion" -o $payload
if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }

$exe = Join-Path $payload 'StopYapping.exe'
$smoke = Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -PassThru -Wait
if ($smoke.ExitCode -ne 0) { throw 'Application self-test failed.' }

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Assets') -Destination $payload -Recurse
foreach ($name in 'LICENSE', 'THIRD-PARTY-NOTICES.txt') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\$name") -Destination $payload
}
$dependencies = Get-Content (Join-Path $payload 'StopYapping.deps.json') -Raw | ConvertFrom-Json
foreach ($runtime in $dependencies.libraries.PSObject.Properties.Name) {
    if ($runtime -notmatch '^runtimepack\.(Microsoft\.(NETCore|WindowsDesktop)\.App\.Runtime\.win-x64)/(.+)$') { continue }
    $id = $Matches[1]
    $runtimeFolder = Join-Path $nugetRoot (Join-Path $id.ToLowerInvariant() $Matches[3])
    $notices = Get-ChildItem -LiteralPath $runtimeFolder -File |
        Where-Object Name -match '^(LICENSE|THIRD-PARTY-NOTICES)(\.txt)?$'
    if (!$notices) { throw "Redistribution notices for $id were not found." }
    foreach ($notice in $notices) {
        Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $payload "$id-$($notice.Name)")
    }
}
[xml] $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.xml') -Raw
$manifest.Package.Identity.Version = $Version
if ($development) {
    $manifest.Package.Identity.Name = 'StopYapping.Development'
} else {
    if ($Publisher.Contains('311729368913984317654407730594956997722')) {
        throw 'Use the subject from the actual release signing certificate.'
    }
    $manifest.Package.Identity.Publisher = $Publisher
}
$manifest.Save((Join-Path (Resolve-Path -LiteralPath $payload) 'AppxManifest.xml'))

$packLog = Join-Path $work 'makeappx.log'
& $makeAppx pack /h SHA256 /d $payload /p $package /o > $packLog
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $packLog -Tail 30
    throw 'MSIX packaging failed.'
}
Get-Item -LiteralPath $package
