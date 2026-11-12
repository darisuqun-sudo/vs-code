# Windows MSIX preview

Build with Windows SDK MakeAppx and the x64 Code - OSS distribution in
`VSCode-win32-x64`. The command below creates an unsigned preview in `Output`
with a placeholder package identity. The preview is a packaging artifact.
Installation and launch through the Microsoft Store still need testing.

```powershell
.\scripts\Build-CodeOSS-MSIX.ps1 -Preview
```

For Store submission, rebuild using the exact package Name, Publisher, and
PublisherDisplayName from Partner Center. Omit `-Preview` and pass those three
values to the script. The Store signs the package after certification.

## GitHub release draft

Run from the Git checkout after the source commit reaches `origin/main`.
Set the file path to the existing Windows preview if it was built outside the
checkout. This creates a release draft and attaches the MSIX as a release asset.

```powershell
$repo = 'darisuqun-sudo/vs-code'
$tag = 'windows-msix-v1.140.0.0-preview'
$asset = 'D:/ھۆججەتلىرىم/app/Output/Taklimakan-Code-Editor-1.140.0.0-x64-preview.msix'
$target = git rev-parse origin/main
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve origin/main.' }
if (!(Test-Path -LiteralPath $asset -PathType Leaf)) { throw 'MSIX preview missing.' }
gh auth status --hostname github.com
if ($LASTEXITCODE -ne 0) { throw 'Sign in with gh auth login first.' }
$sha256 = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
gh release create $tag $asset --repo $repo --target $target --draft --prerelease --latest=false `
  --title 'Taklimakan Code Editor 1.140.0.0 Windows x64 preview' `
  --notes "Unsigned packaging preview with placeholder identity. SHA-256: $sha256"
```

If the draft already exists, inspect it with `gh release view $tag --repo $repo`.
After review, use `gh release edit $tag --repo $repo --draft=false` to expose the
preview to repository members. The private repository requires GitHub access.

## Download page

For `taklimakan.umutwar.com/download`, add a separate Windows section in
[`public/download/index.html`](public/download/index.html). If the link needs
to change independently of the page, put the verified Windows URL in a separate
`public/windows-release.json` and load it from
[`public/download/download.js`](public/download/download.js).
[`public/android-release.json`](public/android-release.json) and
[`public/releases.js`](public/releases.js) supply the existing Android link.
Use the Store product URL for the public install button after certification.
The root domain `umutwar.com` is a different site. Add a link in its own page
editor if the Windows link also belongs there.

The existing `web-assets` archive supplies the Vercel editor runtime. Windows
build output and signing keys stay outside Git.
