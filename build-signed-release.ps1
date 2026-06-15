[CmdletBinding()]
param(
    [string]$Version,
    [string]$CertificateThumbprint,
    [string]$TimestampServer = "http://timestamp.digicert.com",
    [int]$SigningTimeoutSeconds = 120,
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root ".tools\signing-certificate.json"
$ProjectPath = Join-Path $Root "launcher\ZamndxLauncher\ZamndxLauncher.csproj"
$ReleaseScript = Join-Path $Root "tools\build_release.ps1"

if ([string]::IsNullOrWhiteSpace($Version)) {
    [xml]$project = Get-Content -Raw -LiteralPath $ProjectPath
    $Version = [string]$project.Project.PropertyGroup.Version
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must resemble 1.2.3 or 1.2.3-beta.1."
}

if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw @"
Signing is not configured. Run this once with your trusted PFX:

  .\setup-signing.ps1 -PfxPath "C:\path\certificate.pfx"
"@
    }
    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    $CertificateThumbprint = [string]$config.thumbprint
}

$certificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object {
        $_.Thumbprint -eq $CertificateThumbprint.Replace(" ", "").ToUpperInvariant() -and
        $_.HasPrivateKey -and
        $_.NotBefore -le (Get-Date) -and
        $_.NotAfter -gt (Get-Date)
    } |
    Select-Object -First 1
if ($null -eq $certificate) {
    throw "The configured certificate is unavailable or expired. Run .\setup-signing.ps1 again."
}

$arguments = @{
    Version = $Version
    SigningCertificateThumbprint = $certificate.Thumbprint
    TimestampServer = $TimestampServer
    SigningTimeoutSeconds = $SigningTimeoutSeconds
    RequireSignature = $true
}
if ($SkipDownload) {
    $arguments.SkipDownload = $true
}

Write-Host "Building signed ZAMN DX v$Version..."
Write-Host "Certificate: $($certificate.Subject)"
& $ReleaseScript @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
