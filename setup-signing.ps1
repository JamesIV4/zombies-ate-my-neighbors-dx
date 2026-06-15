[CmdletBinding()]
param(
    [string]$PfxPath,
    [string]$CertificateThumbprint
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ToolsDirectory = Join-Path $Root ".tools"
$ConfigPath = Join-Path $ToolsDirectory "signing-certificate.json"
$now = Get-Date

function Get-UsableCodeSigningCertificates {
    @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object {
            $_.HasPrivateKey -and
            $_.NotBefore -le $now -and
            $_.NotAfter -gt $now
        } |
        Sort-Object NotAfter -Descending)
}

function Select-Certificate([object[]]$Certificates) {
    if ($Certificates.Count -eq 1) {
        return $Certificates[0]
    }

    Write-Host "Available code-signing certificates:"
    for ($index = 0; $index -lt $Certificates.Count; $index++) {
        $certificate = $Certificates[$index]
        Write-Host (
            "  [{0}] {1} (expires {2:yyyy-MM-dd}, {3})" -f
            ($index + 1),
            $certificate.Subject,
            $certificate.NotAfter,
            $certificate.Thumbprint)
    }
    $selection = Read-Host "Select a certificate"
    $selectedIndex = 0
    if (-not [int]::TryParse($selection, [ref]$selectedIndex) -or
        $selectedIndex -lt 1 -or
        $selectedIndex -gt $Certificates.Count) {
        throw "Invalid certificate selection."
    }
    return $Certificates[$selectedIndex - 1]
}

[System.IO.Directory]::CreateDirectory($ToolsDirectory) | Out-Null

$certificate = $null
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $normalizedThumbprint = $CertificateThumbprint.Replace(" ", "").ToUpperInvariant()
    $certificate = Get-UsableCodeSigningCertificates |
        Where-Object Thumbprint -eq $normalizedThumbprint |
        Select-Object -First 1
    if ($null -eq $certificate) {
        throw "That thumbprint does not identify a usable code-signing certificate."
    }
} elseif (-not [string]::IsNullOrWhiteSpace($PfxPath)) {
    $resolvedPfxPath = (Resolve-Path -LiteralPath $PfxPath).Path
    $password = Read-Host "PFX password" -AsSecureString
    $imported = Import-PfxCertificate `
        -FilePath $resolvedPfxPath `
        -CertStoreLocation Cert:\CurrentUser\My `
        -Password $password `
        -Exportable:$false
    $importedThumbprints = @($imported | ForEach-Object Thumbprint)
    $certificate = Get-UsableCodeSigningCertificates |
        Where-Object { $importedThumbprints -contains $_.Thumbprint } |
        Select-Object -First 1
    if ($null -eq $certificate) {
        throw "The PFX does not contain a valid code-signing certificate with a private key."
    }
} else {
    $certificates = Get-UsableCodeSigningCertificates
    if ($certificates.Count -eq 0) {
        throw @"
No usable code-signing certificate is installed.

Obtain a trusted code-signing certificate as a PFX, then run:

  .\setup-signing.ps1 -PfxPath "C:\path\certificate.pfx"
"@
    }
    $certificate = Select-Certificate $certificates
}

$config = [ordered]@{
    thumbprint = $certificate.Thumbprint
    subject = $certificate.Subject
    expires_utc = $certificate.NotAfter.ToUniversalTime().ToString("o")
}
$config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

Write-Host ""
Write-Host "Signing certificate configured:"
Write-Host "  Subject: $($certificate.Subject)"
Write-Host "  Thumbprint: $($certificate.Thumbprint)"
Write-Host "  Expires: $($certificate.NotAfter)"
Write-Host ""
Write-Host "Build a signed release with:"
Write-Host "  .\build-signed-release.ps1 -Version 1.0.1"
