#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Store')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Preview')]
    [switch]$Preview,

    [Parameter(Mandatory, ParameterSetName = 'Store')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$')]
    [string]$PackageName,

    [Parameter(Mandatory, ParameterSetName = 'Store')]
    [ValidatePattern('^CN=.+$')]
    [string]$Publisher,

    [Parameter(Mandatory, ParameterSetName = 'Store')]
    [ValidateNotNullOrEmpty()]
    [string]$PublisherDisplayName,

    [string]$DisplayName = 'Taklimakan Code Editor',
    [string]$SourcePath = (Join-Path $PSScriptRoot '../VSCode-win32-x64'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../Output'),
    [version]$Version,
    [string]$MakeAppxPath
)

$ErrorActionPreference = 'Stop'
if ($Preview) {
    $PackageName = 'Taklimakan.CodeEditor.Preview'
    $Publisher = 'CN=Taklimakan Preview'
    $PublisherDisplayName = 'Taklimakan Preview'
}

$source = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$app = Join-Path $source 'resources/app'
$executable = Join-Path $source 'Code - OSS.exe'
$icon = Join-Path $app 'resources/win32/code_150x150.png'
foreach ($path in @($executable, $icon, (Join-Path $app 'LICENSE.txt'), (Join-Path $app 'ThirdPartyNotices.txt'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Windows build file: $path" }
}
if (-not $Version) {
    $appVersion = (Get-Content -LiteralPath (Join-Path $app 'package.json') -Raw | ConvertFrom-Json).version
    $Version = [version]($appVersion + '.0')
}
if ($Version.Major -lt 1 -or $Version.Revision -ne 0 -or @($Version.Major, $Version.Minor, $Version.Build).Where({ $_ -gt 65535 -or $_ -lt 0 }).Count) {
    throw 'Use a four-part Store version with a nonzero major version and a fourth part of zero.'
}
if (-not $MakeAppxPath) {
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $MakeAppxPath = Get-ChildItem -LiteralPath $sdkBin -Directory |
        Where-Object Name -Match '^\d+(\.\d+){3}$' |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64/makeappx.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if (-not $MakeAppxPath) { throw 'Windows SDK MakeAppx.exe was not found.' }

$output = [IO.Directory]::CreateDirectory($OutputDirectory).FullName
$suffix = if ($Preview) { 'preview' } else { 'store' }
$destination = Join-Path $output "Taklimakan-Code-Editor-$Version-x64-$suffix.msix"
if (Test-Path -LiteralPath $destination) { throw "Package already exists: $destination" }

$work = [IO.Directory]::CreateDirectory((Join-Path ([IO.Path]::GetTempPath()) ('codeoss-msix-' + [guid]::NewGuid())))
$completed = $false
try {
    Add-Type -AssemblyName System.Drawing
    $assetNames = [ordered]@{ StoreLogo = 50; Square44x44Logo = 44 }
    $original = [Drawing.Image]::FromFile($icon)
    try {
        foreach ($asset in $assetNames.GetEnumerator()) {
            $bitmap = [Drawing.Bitmap]::new($asset.Value, $asset.Value)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.DrawImage($original, 0, 0, $bitmap.Width, $bitmap.Height)
                } finally { $graphics.Dispose() }
                $bitmap.Save((Join-Path $work.FullName ($asset.Key + '.png')), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose() }
        }
    } finally { $original.Dispose() }

    $nameXml = [Security.SecurityElement]::Escape($DisplayName)
    $publisherXml = [Security.SecurityElement]::Escape($Publisher)
    $publisherDisplayXml = [Security.SecurityElement]::Escape($PublisherDisplayName)
    $manifest = Join-Path $work.FullName 'AppxManifest.xml'
    @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap rescap">
  <Identity Name="$PackageName" Publisher="$publisherXml" Version="$Version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>$nameXml</DisplayName>
    <PublisherDisplayName>$publisherDisplayXml</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Resources><Resource Language="en-us" /></Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Applications>
    <Application Id="CodeEditor" Executable="Code - OSS.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="$nameXml" Description="A desktop code editor based on Code - OSS."
        BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png" />
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"@ | Set-Content -LiteralPath $manifest -Encoding UTF8

    $map = Join-Path $work.FullName 'package-map.txt'
    $entries = @(
        '[Files]'
        ('"{0}" "AppxManifest.xml"' -f $manifest)
        ('"{0}" "Assets\Square150x150Logo.png"' -f $icon)
        foreach ($asset in $assetNames.Keys) {
            '"{0}" "Assets\{1}.png"' -f (Join-Path $work.FullName ($asset + '.png')), $asset
        }
        foreach ($file in (Get-ChildItem -LiteralPath $source -File | Where-Object { $_.Extension -in '.exe','.dll','.pak','.dat','.bin','.json','.html','.xml' -and $_.Name -notlike '.*' })) {
            '"{0}" "{1}"' -f $file.FullName, $file.Name
        }
        foreach ($folder in @('bin', 'locales', 'resources')) {
            foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $source $folder) -File -Recurse -Force)) {
                '"{0}" "{1}"' -f $file.FullName, $file.FullName.Substring($source.Length + 1)
            }
        }
    )
    $entries | Set-Content -LiteralPath $map -Encoding Unicode
    & $MakeAppxPath pack /f $map /p $destination /no | Where-Object { $_ -notmatch '^Processing ' }
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx exited with code $LASTEXITCODE." }
    $completed = $true
    Get-FileHash -LiteralPath $destination -Algorithm SHA256
} finally {
    foreach ($file in (Get-ChildItem -LiteralPath $work.FullName -File)) {
        Remove-Item -LiteralPath $file.FullName
    }
    Remove-Item -LiteralPath $work.FullName
    if (-not $completed -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Remove-Item -LiteralPath $destination
    }
}
