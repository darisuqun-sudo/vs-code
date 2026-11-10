# Code-OSS Android

Code-OSS نىڭ Android ئۈچۈن تەييارلانغان ئايرىم نەشرى. ئىمزالانغان APK ۋە SHA-256 ھۆججىتىنى [GitHub Releases](../../releases) دىن چۈشۈرۈڭ.

ئەسلى Workbench مەنبەسى [Code-OSS 1.140.0](https://github.com/microsoft/vscode/tree/07f806f999227108933c2e30515b26eecc1fda74).

## Windows x64

Windows packaging is defined in [installer.iss](installer.iss). The release
script checks the staged application, signs its Windows binaries and
PowerShell files, then signs and verifies the Inno Setup installer and
uninstaller.

Use the pinned upstream commit above in a local `code-oss` checkout.
Apply [the build patch](patches/code-oss-07f806f-build.patch) to that checkout.
With a matching x64 build in `VSCode-win32-x64`, run the following from this
repository in PowerShell 7. Use a public code-signing certificate with its
private key accessible to SignTool, along with Node.js, Git, Windows SDK
SignTool and Inno Setup.

```powershell
.\scripts\Sign-CodeOSS-Windows.ps1 -Action Release -Thumbprint '<OV_THUMBPRINT>'
```

Use `-StoreLocation LocalMachine` for a certificate in the machine store.
Verify installation, launch and removal on a clean Windows 11 system with
Smart App Control enabled before publishing the resulting installer.
Generated files under `Output/` stay outside Git.
