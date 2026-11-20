#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $Dotnet = 'dotnet',
    [string] $Iscc = 'ISCC.exe',
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version = '0.2.1',
    [string] $DriverZip,
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $SigningThumbprint,
    [uri] $TimestampServer
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'artifacts\setup'
if ($SigningThumbprint) { $output = Join-Path $output 'signed' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$work = Join-Path $output ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

if (!$DriverZip) {
    $DriverZip = Join-Path $work 'VBCABLE_Driver_Pack46.zip'
    Invoke-WebRequest -Uri 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack46.zip' -OutFile $DriverZip
}
$expected = 'BC44E8974191A5A2427D6C979E2DAB08DBB09925F3F435DFA2F0BA3E45B6EB90'
if ((Get-FileHash -LiteralPath $DriverZip -Algorithm SHA256).Hash -ne $expected) {
    throw 'The VB-CABLE archive is different from the approved vendor package.'
}

$driver = Join-Path $work 'VB-CABLE'
Expand-Archive -LiteralPath $DriverZip -DestinationPath $driver
$driverExecutable = Join-Path $driver 'VBCABLE_Setup_x64.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $driverExecutable
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=BUREL VINCENT') {
    throw 'The VB-CABLE setup signature did not match the vendor.'
}
$driverHash = (Get-FileHash -LiteralPath $driverExecutable -Algorithm SHA256).Hash

$msix = & (Join-Path $PSScriptRoot 'Build-Msix.ps1') -Dotnet $Dotnet -Version "$Version.0" | ForEach-Object {
    if ($_ -is [System.IO.FileInfo]) { $_ } else { Write-Host $_ }
}
$app = Join-Path $work 'app'
$toolAssets = Get-Content (Join-Path $PSScriptRoot 'obj\project.assets.json') -Raw | ConvertFrom-Json
$nugetRoot = $toolAssets.packageFolders.PSObject.Properties.Name | Select-Object -First 1
$makeAppx = Join-Path $nugetRoot 'microsoft.windows.sdk.buildtools\10.0.28000.2957\bin\10.0.28000.0\x64\makeappx.exe'
$signTool = Join-Path (Split-Path -Parent $makeAppx) 'signtool.exe'
& $makeAppx unpack /p $msix.FullName /d $app > (Join-Path $work 'unpack.log')
if ($LASTEXITCODE -ne 0) { throw 'Could not extract the validated app payload.' }
foreach ($name in 'AppxManifest.xml','AppxBlockMap.xml','[Content_Types].xml') {
    $metadata = Join-Path $app $name
    if (Test-Path -LiteralPath $metadata) { Remove-Item -LiteralPath $metadata }
}

$compilerArguments = @(
    "/DReleaseVersion=$Version", "/DAppFolder=$app", "/DDriverFolder=$driver",
    "/DDriverSetupSha256=$driverHash", "/DOutputFolder=$output"
)
if ($SigningThumbprint) {
    if (!$TimestampServer -or $TimestampServer.Scheme -ne 'https' -or
        $TimestampServer.AbsoluteUri -notmatch '^https://[A-Za-z0-9./:_-]+$') {
        throw 'Use the HTTPS RFC 3161 timestamp URL from your signing provider.'
    }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningThumbprint"
    if (!$certificate.HasPrivateKey) { throw 'The signing certificate has no usable private key.' }
    $appExe = Join-Path $app 'StopYapping.exe'
    & $signTool sign /fd SHA256 /sha1 $SigningThumbprint /tr $TimestampServer.AbsoluteUri /td SHA256 $appExe
    if ($LASTEXITCODE -ne 0) { throw 'Application code signing failed.' }

    $signingFolder = Join-Path $work 'signed-uninstaller'
    New-Item -ItemType Directory -Path $signingFolder | Out-Null
    # $q and $f are Inno Setup placeholders for quotes and the file being signed.
    $innoSignCommand = '$q' + $signTool.Replace('$', '$$') + '$q sign /fd SHA256 /sha1 ' +
        $SigningThumbprint + ' /tr ' + $TimestampServer.AbsoluteUri + ' /td SHA256 $f'
    $compilerArguments += @('/DSignRelease=1', "/DSigningFolder=$signingFolder", "--signtool=release=$innoSignCommand")
}
$compilerArguments += Join-Path $PSScriptRoot 'StopYapping.iss'
& $Iscc @compilerArguments
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup could not build the installer.' }
$installer = Get-Item -LiteralPath (Join-Path $output 'StopYapping-Setup-x64.exe')
if ($SigningThumbprint) {
    $signedFiles = @((Join-Path $app 'StopYapping.exe'), $installer.FullName)
    $uninstallers = Get-ChildItem -LiteralPath $signingFolder -Filter '*.exe'
    if (!$uninstallers) { throw 'Inno Setup did not produce a signed uninstaller.' }
    $signedFiles += $uninstallers.FullName
    foreach ($file in $signedFiles) {
        & $signTool verify /pa /all /tw $file
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        if ($LASTEXITCODE -ne 0 -or $signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Thumbprint -ne $SigningThumbprint -or !$signature.TimeStamperCertificate) {
            throw "The signature or timestamp could not be verified for $([IO.Path]::GetFileName($file))."
        }
    }
}
$installer
