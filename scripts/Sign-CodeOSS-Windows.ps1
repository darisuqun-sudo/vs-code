#Requires -Version 5.1
<#
.SYNOPSIS
Creates a local test certificate, signs a separate Windows build, or prepares
a signed Windows release candidate with Inno Setup.
.DESCRIPTION
Local certificate trust is for Authenticode testing on this computer. Smart App
Control requires a certificate from a trusted provider.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('NewCertificate', 'TrustLocalCertificate', 'Sign', 'Release')]
    [string]$Action,

    [string]$CertificatePath = (Join-Path $PSScriptRoot '..\.taskcache\code-oss-local-signing.cer'),

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$Thumbprint,

    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$StoreLocation = 'CurrentUser',

    [string]$SourcePath = (Join-Path $PSScriptRoot '..\VSCode-win32-x64'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\releases\Code-OSS-Windows-signed'),
    [string]$SignToolPath,
    [string]$InnoCompilerPath,
    [uri]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$AppendToExisting
)

$ErrorActionPreference = 'Stop'
$testSubject = 'CN=Code OSS Local Test Signing'
$localDevThumbprint = '7AF98A2DE4BDF36A4D756D375D44F1B13C0AE532'
$codeSigningOid = '1.3.6.1.5.5.7.3.3'

function Resolve-FileSystemPath([string]$Path) {
    $provider = $null
    $drive = $null
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref]$provider, [ref]$drive
    )
    if ($provider.Name -ne 'FileSystem') {
        throw "Expected a filesystem path: $Path"
    }
    return $fullPath
}

function Get-CodeSigningCertificate([string]$Location, [string]$Id) {
    $cert = Get-Item -LiteralPath "Cert:\$Location\My\$Id"
    $now = Get-Date
    $purposes = @($cert.Extensions | Where-Object Oid -ne $null |
        Where-Object { $_.Oid.Value -eq '2.5.29.37' } |
        ForEach-Object { $_.EnhancedKeyUsages | ForEach-Object { $_.Value } })
    if (-not $cert.HasPrivateKey -or $now -lt $cert.NotBefore -or
        $now -gt $cert.NotAfter -or $codeSigningOid -notin $purposes) {
        throw 'The certificate must be current, allow code signing, and have an accessible private key.'
    }
    return $cert
}

function Find-SignTool {
    if ($SignToolPath) {
        $tool = Get-Item -LiteralPath $SignToolPath
        if ($tool.PSIsContainer -or $tool.Name -ne 'signtool.exe') {
            throw 'Supply the Windows SDK signtool.exe path.'
        }
        return $tool.FullName
    }
    $command = Get-Command signtool.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem -LiteralPath $sdkBin -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object {
            Get-Item -LiteralPath (Join-Path $_.FullName 'x64\signtool.exe') -ErrorAction SilentlyContinue
        } |
        Select-Object -First 1
    if (-not $tool) {
        throw 'Windows SDK SignTool was not found. Install the Windows SDK signing tools or set -SignToolPath.'
    }
    return $tool.FullName
}

function Find-InnoCompiler {
    if ($InnoCompilerPath) {
        $tool = Get-Item -LiteralPath $InnoCompilerPath
        if ($tool.PSIsContainer -or $tool.Name -ne 'ISCC.exe') {
            throw 'Supply the Inno Setup ISCC.exe path.'
        }
        return $tool.FullName
    }
    $command = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    foreach ($directory in $env:LOCALAPPDATA, ${env:ProgramFiles(x86)}, $env:ProgramFiles) {
        if ($directory) {
            foreach ($subdirectory in 'Programs\Inno Setup 6', 'Inno Setup 6') {
                $path = Join-Path $directory "$subdirectory\ISCC.exe"
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    return $path
                }
            }
        }
    }
    throw 'Inno Setup ISCC.exe was not found. Supply -InnoCompilerPath.'
}

function Confirm-PublicSigningCertificate($Certificate) {
    if ($Certificate.Subject -eq $Certificate.Issuer) {
        throw 'Release requires a CA-issued code signing certificate. A self-signed certificate can only be used with Sign.'
    }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new($codeSigningOid)) | Out-Null
        $chain.ChainPolicy.RevocationMode = 'Online'
        $chain.ChainPolicy.RevocationFlag = 'ExcludeRoot'
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(20)
        if (-not $chain.Build($Certificate)) {
            $status = ($chain.ChainStatus | ForEach-Object { $_.Status }) -join ', '
            throw "The signing certificate chain failed Windows verification: $status"
        }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        if (-not (Test-Path -LiteralPath "Cert:\LocalMachine\AuthRoot\$($root.Thumbprint)")) {
            throw "The signing chain does not end in the Windows third-party root store: $($root.Subject)"
        }
    } finally {
        $chain.Dispose()
    }
}

function Get-EmbeddedSigningCertificate([string]$Path) {
    try {
        return [Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($Path)
    } catch [Security.Cryptography.CryptographicException] {
        return $null
    }
}

function Confirm-EmbeddedSigner([string]$Path, [string]$ExpectedThumbprint) {
    $embedded = Get-EmbeddedSigningCertificate $Path
    try {
        if (-not $embedded -or $embedded.GetCertHashString() -ne $ExpectedThumbprint) {
            throw "Unexpected or missing embedded signer: $Path"
        }
    } finally {
        if ($embedded) {
            $embedded.Dispose()
        }
    }
}

if ($Action -eq 'NewCertificate') {
    $publicFile = Resolve-FileSystemPath $CertificatePath
    if ([IO.Path]::GetExtension($publicFile) -ne '.cer' -or (Test-Path -LiteralPath $publicFile)) {
        throw 'Specify a new .cer file for the public certificate.'
    }
    if ($PSCmdlet.ShouldProcess($publicFile, 'Create a local code signing certificate and export its public part')) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($publicFile)) -Force | Out-Null
        $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $testSubject `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 3072 `
            -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(1)
        Export-Certificate -Cert $certificate -FilePath $publicFile -Type CERT -NoClobber | Out-Null
        [pscustomobject]@{ Subject = $certificate.Subject; Thumbprint = $certificate.Thumbprint; PublicCertificate = $publicFile }
    }
    return
}

if (-not $Thumbprint) {
    throw "Supply -Thumbprint for $Action."
}

if ($Action -eq 'TrustLocalCertificate') {
    $publicFile = Resolve-FileSystemPath $CertificatePath
    $localCert = Get-CodeSigningCertificate 'CurrentUser' $Thumbprint
    $publicBytes = [IO.File]::ReadAllBytes($publicFile)
    if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($publicBytes) -ne 'Cert') {
        throw 'Supply the exported public .cer certificate.'
    }
    $publicCert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicBytes)
    try {
        if ($localCert.Subject -ne $testSubject -or $localCert.Issuer -ne $testSubject -or
            $publicCert.Thumbprint -ne $localCert.Thumbprint -or $publicCert.HasPrivateKey) {
            throw 'The .cer file must match the local test certificate and contain only its public part.'
        }
        if ($PSCmdlet.ShouldProcess("LocalMachine Root and TrustedPublisher for $Thumbprint", 'Trust this local test certificate on this computer')) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Run this step in an elevated PowerShell window under the same Windows account.'
            }
            foreach ($name in 'Root', 'TrustedPublisher') {
                $destination = "Cert:\LocalMachine\$name"
                if (-not (Test-Path -LiteralPath "$destination\$Thumbprint")) {
                    # Add the bytes already checked above, rather than reopening the file.
                    $store = [Security.Cryptography.X509Certificates.X509Store]::new($name, 'LocalMachine')
                    try {
                        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                        $store.Add($publicCert)
                    } finally {
                        $store.Dispose()
                    }
                    if (-not (Test-Path -LiteralPath "$destination\$Thumbprint")) {
                        throw "The certificate was not found in $destination after import."
                    }
                }
                Write-Output "Trusted in $destination"
            }
        }
    } finally {
        $publicCert.Dispose()
    }
    return
}

if (-not $TimestampUrl.IsAbsoluteUri -or $TimestampUrl.Scheme -notin 'http', 'https') {
    throw 'Supply an HTTP or HTTPS RFC 3161 timestamp server URL.'
}
$signTool = Find-SignTool
$release = $Action -eq 'Release'
if ($release -and $AppendToExisting) {
    throw 'Release replaces development signatures. Omit -AppendToExisting.'
}
if ($release -and -not $PSBoundParameters.ContainsKey('OutputPath')) {
    $OutputPath = Join-Path $PSScriptRoot ('..\Output\Windows-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$source = Get-Item -LiteralPath (Resolve-FileSystemPath $SourcePath) -Force
$output = Resolve-FileSystemPath $OutputPath
if (-not $source.PSIsContainer -or
    -not (Test-Path -LiteralPath (Join-Path $source.FullName 'Code - OSS.exe') -PathType Leaf)) {
    throw 'The source must be the Code-OSS Windows application directory.'
}
if ((Test-Path -LiteralPath $output) -or
    $output.StartsWith($source.FullName.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a new output directory outside the source.'
}
$items = @(Get-ChildItem -LiteralPath $source.FullName -Force -Recurse)
if ($source.Attributes -band [IO.FileAttributes]::ReparsePoint -or
    @($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'The application directory contains a junction or symbolic link.'
}
$extensions = '.exe', '.dll', '.node'
$binaries = @($items | Where-Object { -not $_.PSIsContainer -and $_.Extension -in $extensions })
$operation = "Copy the application and sign or verify $($binaries.Count) Windows binaries"
if ($release) {
    $operation = 'Inventory and sign the staged binaries and PowerShell scripts, then build and verify an Inno Setup candidate'
}
if (-not $PSCmdlet.ShouldProcess($output, $operation)) {
    return
}

$certificate = Get-CodeSigningCertificate $StoreLocation $Thumbprint
if ($release) {
    Confirm-PublicSigningCertificate $certificate
    $compiler = Find-InnoCompiler
    $node = (Get-Command node.exe -CommandType Application).Source
    $installerScript = Join-Path $PSScriptRoot '..\installer.iss'
    $verifyScript = Join-Path $PSScriptRoot '..\clone-tools\verify-windows.mjs'
}
$parent = [IO.Path]::GetDirectoryName($output)
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$stage = Join-Path $parent ('.code-oss-signing-' + [guid]::NewGuid().ToString('N'))
$payload = $stage
$signed = 0
$preserved = 0
try {
    if ($release) {
        New-Item -ItemType Directory -Path $stage | Out-Null
        $payload = Join-Path $stage 'payload'
    }
    Copy-Item -LiteralPath $source.FullName -Destination $payload -Recurse -Force
    $signingPaths = if ($release) {
        $reportJson = & $node $verifyScript --bundle $payload --check-only --release-inventory
        if ($LASTEXITCODE -ne 0) {
            throw 'The packaged application failed its static integrity checks.'
        }
        $report = ($reportJson -join "`n") | ConvertFrom-Json
        $report.binaries
        $report.scripts
    } else {
        foreach ($original in $binaries) {
            $original.FullName.Substring($source.FullName.TrimEnd('\').Length + 1)
        }
    }
    foreach ($relative in $signingPaths) {
        $file = Get-Item -LiteralPath (Join-Path $payload $relative) -Force
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        $existing = $signature.SignerCertificate
        # Catalog signatures can mask the embedded signer on this computer.
        if ($release -and $signature.SignatureType -eq 'Catalog') {
            $existing = Get-EmbeddedSigningCertificate $file.FullName
        }
        $replaceLocal = $release -and $existing -and ($existing.GetCertHashString() -eq $localDevThumbprint -or
            ($existing.Subject -eq $testSubject -and $existing.Issuer -eq $testSubject))
        if ($signature.Status -notin 'Valid', 'NotSigned' -and
            -not ($replaceLocal -and $signature.Status -eq 'NotTrusted')) {
            throw "Existing signature requires review ($($signature.Status)): $relative"
        }
        if ($signature.Status -eq 'Valid' -and $existing -and -not $replaceLocal) {
            if (-not $signature.TimeStamperCertificate) {
                throw "Existing signature has no timestamp and requires review: $relative"
            }
            if ($release) {
                if ($existing.GetCertHashString() -ne $certificate.Thumbprint -and
                    ($existing.Subject -notmatch '^CN=Microsoft Windows, O=Microsoft Corporation(,|$)' -or
                     $existing.Issuer -notmatch '^CN=Microsoft Windows Production PCA ')) {
                    throw "Unexpected existing signer requires review: $relative ($($existing.Subject))"
                }
                & $signTool verify /pa /all /tw $file.FullName
                if ($LASTEXITCODE -ne 0) {
                    throw "Embedded signature verification failed: $relative"
                }
            }
            if (-not $AppendToExisting) {
                $preserved++
                continue
            }
        }
        $signArguments = @('sign', '/s', 'My', '/sha1', $certificate.Thumbprint,
            '/fd', 'SHA256', '/tr', $TimestampUrl.AbsoluteUri, '/td', 'SHA256')
        if ($StoreLocation -eq 'LocalMachine') {
            $signArguments += '/sm'
        }
        if ($AppendToExisting -and $signature.Status -eq 'Valid') {
            $signArguments += '/as'
        }
        if ($file.IsReadOnly) {
            $file.IsReadOnly = $false
        }
        & $signTool @signArguments $file.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Signing or RFC 3161 timestamping failed: $relative"
        }
        # /tw makes a missing timestamp a warning, which also fails this step.
        & $signTool verify /pa /all /tw $file.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Authenticode verification failed: $relative"
        }
        if ($release -or $signature.Status -eq 'NotSigned') {
            Confirm-EmbeddedSigner $file.FullName $certificate.Thumbprint
        }
        $signed++
    }
    if ($release) {
        $exe = Join-Path $payload 'Code - OSS.exe'
        $report.PSObject.Properties.Remove('binaries')
        $report.PSObject.Properties.Remove('scripts')
        $report.executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $payload '.code-oss-build-complete.json'), ($report | ConvertTo-Json))

        $storeSwitch = if ($StoreLocation -eq 'LocalMachine') { ' /sm' } else { '' }
        $signCommand = '$q{0}$q sign{1} /sha1 {2} /fd SHA256 /tr $q{3}$q /td SHA256 $f' -f
            $signTool.Replace('$', '$$'), $storeSwitch, $certificate.Thumbprint, $TimestampUrl.AbsoluteUri.Replace('$', '$$')
        $log = Join-Path $stage 'inno-build.log'
        & $compiler "/O$stage" "/DCodeOSSPayloadDir=$payload" "/DCodeOSSAppVersion=$($report.version)" "/SCodeOSSPublicSign=$signCommand" $installerScript *> $log
        if ($LASTEXITCODE -ne 0) {
            throw "Installer build or signing failed. See $log."
        }
        $setup = Join-Path $stage 'Code-OSS-Setup.exe'
        & $signTool verify /pa /all /tw $setup
        if ($LASTEXITCODE -ne 0) {
            throw 'Installer signature verification failed.'
        }
        Confirm-EmbeddedSigner $setup $certificate.Thumbprint
    }
    # Rename within the same parent. Directory.Move fails if the destination already exists.
    [IO.Directory]::Move($stage, $output)
} catch {
    throw "Signing stopped. Inspect the staging directory before packaging: $stage. $($_.Exception.Message)"
}
[pscustomobject]@{ Output = $output; NewlySigned = $signed; ExistingSignaturesPreserved = $preserved; Thumbprint = $certificate.Thumbprint }
if ($release) {
    $setup = Join-Path $output 'Code-OSS-Setup.exe'
    [pscustomobject]@{ Installer = $setup; SHA256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash }
}
