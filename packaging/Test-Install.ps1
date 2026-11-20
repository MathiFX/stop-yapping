#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This test creates a temporary certificate. Run it only on a GitHub-hosted disposable runner.'
}
$package = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\artifacts\development\*.msix') |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (!$package) { throw 'Build the development package before testing.' }
$name = 'StopYapping.Development'
if (Get-AppxPackage -Name $name) { throw 'A previous development package is already installed.' }
$toolPackage = Get-Content (Join-Path $PSScriptRoot 'obj\project.assets.json') -Raw | ConvertFrom-Json
$nugetRoot = $toolPackage.packageFolders.PSObject.Properties.Name | Select-Object -First 1
$signTool = Join-Path $nugetRoot 'microsoft.windows.sdk.buildtools\10.0.28000.2957\bin\10.0.28000.0\x64\signtool.exe'
$publicCertPath = Join-Path $env:RUNNER_TEMP 'stop-yapping-ci.cer'
$certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Stop Yapping Development' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)
try {
    Export-Certificate -Cert $certificate -FilePath $publicCertPath | Out-Null
    Import-Certificate -FilePath $publicCertPath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    & $signTool sign /fd SHA256 /sha1 $certificate.Thumbprint $package.FullName
    if ($LASTEXITCODE -ne 0) { throw 'Windows could not sign the test package.' }

    Add-AppxPackage -Path $package.FullName
    $installed = Get-AppxPackage -Name $name
    if (!$installed -or !(Test-Path -LiteralPath (Join-Path $installed.InstallLocation 'StopYapping.exe'))) {
        throw 'Installed package or executable is missing.'
    }
    $manifest = Get-AppxPackageManifest -Package $installed.PackageFullName
    $startup = $manifest.SelectSingleNode("//*[local-name()='StartupTask' and @TaskId='StopYappingStartup']")
    if (!$startup) { throw 'The Windows startup extension is missing.' }
    $exe = Join-Path $installed.InstallLocation 'StopYapping.exe'
    $process = Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw 'The installed application self-test failed.' }
    Write-Host 'Windows package and startup extension registered.'
}
finally {
    try {
        $installed = Get-AppxPackage -Name $name
        if ($installed) { Remove-AppxPackage -Package $installed.PackageFullName }
    }
    finally {
        $thumbprint = $certificate.Thumbprint
        Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$thumbprint" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $publicCertPath -ErrorAction SilentlyContinue
    }
}
if (Get-AppxPackage -Name $name) { throw 'The package is still registered after uninstall.' }
Write-Host 'Windows package removed.'
