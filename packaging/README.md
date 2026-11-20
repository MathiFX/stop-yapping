# Windows packaging

Build on Windows with the .NET 10 SDK. The script restores locked app dependencies and a pinned Microsoft Windows SDK Build Tools release. It publishes a self-contained x64 app, runs its audio buffer and disconnected-Vowen checks, then packages it with MakeAppx.

```powershell
.\packaging\Build-Msix.ps1
```

The development build uses a separate Windows package identity. The [GitHub workflow](../.github/workflows/windows.yml) signs it with a temporary test certificate on a disposable runner and checks installation and removal. The test package and certificate stay on that runner. [Microsoft's MSIX signing guidance](https://learn.microsoft.com/windows/msix/package/signing-package-overview)

## Publishing a release

1. Obtain an approved public-trust code signing identity. Use the certificate's exact subject as the publisher and keep it consistent between releases. Keep signing credentials out of the repository.
2. Run `.\packaging\Build-Msix.ps1 -Publisher 'CERTIFICATE SUBJECT' -Version 0.1.0.0`. The file under `artifacts/unsigned-release` is input to the signing pipeline.
3. Sign the MSIX with SHA-256 and a trusted timestamp from the signing provider. Verify it with SignTool (`signtool verify /pa /all /v /tw <file.msix>`).
4. On a clean Windows 11 machine, install by double-clicking the MSIX with ordinary Windows security settings. Confirm the tray app opens, startup appears after first launch, the Discord test works, and Windows uninstalls it without leaving its startup registration. Test upgrading from the previous release when applicable.
5. Publish only the verified signed installer. Include the SHA-256 digest and release notes. Keep VB-CABLE separate.

[Microsoft's production signing guidance](https://learn.microsoft.com/windows/msix/package/signing-package-overview)
