[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\Gunny\GunnyFileExe',
    [switch]$Apply,
    [string]$CacheRoot = 'C:\Gunny-Infra\resource-cache',
    [string]$HttpBaseUrl = '',
    [switch]$SkipHttpProbe,
    [string]$ManifestRoot = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestRoot)) { $ManifestRoot = $PSScriptRoot }
$webRoot = Join-Path $TargetRoot 'gunny'
if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) { throw "Gunny web root missing: $webRoot" }
$sets = @(
    [pscustomobject]@{Name='map';Manifest=(Join-Path $ManifestRoot 'v389-map-assets-manifest.tsv');Package='gunny-v389-map-assets-20260917.zip';Uri='https://github.com/trinhtanphat/Resource/releases/download/runtime-v389-map-assets-20260917/gunny-v389-map-assets-20260917.zip';Sha='2788692DD5315DE5DCDFF7166FFB4F50462A07E1BD450A2D491326760D6FFECD';Script=(Join-Path $PSScriptRoot 'Sync-GunnyV389MapAssets.ps1')},
    [pscustomobject]@{Name='audio';Manifest=(Join-Path $ManifestRoot 'v389-map-audio-manifest.tsv');Package='gunny-v389-map-audio-20260917.zip';Uri='https://github.com/trinhtanphat/Resource/releases/download/runtime-v389-map-audio-20260917/gunny-v389-map-audio-20260917.zip';Sha='B0D5BDE9B741273AD2A66777D81DDFB4C0C9F932AF2ABB3436AD54EEE44529AB';Script=(Join-Path $PSScriptRoot 'Sync-GunnyV389MapAudio.ps1')},
    [pscustomobject]@{Name='recovery';Manifest=(Join-Path $ManifestRoot 'v389-ruffle-recovery-manifest.tsv');Package='gunny-v389-ruffle-recovery-assets-20260917.zip';Uri='https://github.com/trinhtanphat/Resource/releases/download/runtime-v389-ruffle-recovery-assets-20260917/gunny-v389-ruffle-recovery-assets-20260917.zip';Sha='8C0DF2BE3D8ECBE8F26944621D1DEF0FD787DC52CC833A372C79E902E6C08382';Script=(Join-Path $PSScriptRoot 'Sync-GunnyV389RuffleRecovery.ps1')},
    [pscustomobject]@{Name='farm';Manifest=(Join-Path $ManifestRoot 'v389-farm-pet-manifest.tsv');SourceRef='43c21f53343cef61cf91180438bf594b2c8bd51b';Script=(Join-Path $PSScriptRoot 'Sync-GunnyV389FarmAssets.ps1')},
    [pscustomobject]@{Name='observed';Manifest=(Join-Path $ManifestRoot 'v389-observed-ruffle-manifest.tsv');SourceRef='303eab6ab6c17cc7ed6cd11bd8bab3331970cd6e';Script=(Join-Path $PSScriptRoot 'Sync-GunnyV389ObservedAssets.ps1')}
)
function Test-ResourceSet($Set) {
    if (-not (Test-Path -LiteralPath $Set.Manifest -PathType Leaf)) { throw "Resource manifest missing: $($Set.Manifest)" }
    $rows = @(Import-Csv -LiteralPath $Set.Manifest -Delimiter "`t")
    $missing=0;$sizeMismatch=0;$hashMismatch=0
    foreach ($row in $rows) {
        $dst = Join-Path $webRoot ([string]$row.path)
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { $missing++; continue }
        if ((Get-Item -LiteralPath $dst).Length -ne [int64]$row.bytes) { $sizeMismatch++; continue }
        if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne ([string]$row.sha256).ToUpperInvariant()) { $hashMismatch++ }
    }
    [pscustomobject]@{Name=$Set.Name;Rows=$rows;Count=$rows.Count;Missing=$missing;SizeMismatch=$sizeMismatch;HashMismatch=$hashMismatch;Healthy=(($missing+$sizeMismatch+$hashMismatch)-eq0)}
}
function Get-VerifiedPackage($Set) {
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    $packagePath = Join-Path $CacheRoot $Set.Package
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        $actual = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $Set.Sha) { Remove-Item -LiteralPath $packagePath -Force }
    }
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        Write-Host "RESOURCE_PACKAGE_DOWNLOAD name=$($Set.Name) uri=$($Set.Uri)"
        Invoke-WebRequest -Uri $Set.Uri -OutFile $packagePath -UseBasicParsing
    }
    $hash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hash -ne $Set.Sha) { throw "Resource package SHA256 mismatch for $($Set.Name): got $hash expected $($Set.Sha)" }
    $packagePath
}
function Invoke-HttpSamples($Audits) {
    if ($SkipHttpProbe -or [string]::IsNullOrWhiteSpace($HttpBaseUrl)) { return }
    foreach ($audit in $Audits) {
        $samples = @($audit.Rows | Where-Object { ([string]$_.path) -match '^[\x20-\x7E]+$' } | Select-Object -First 2)
        foreach ($row in $samples) {
            $segments = ([string]$row.path).Replace('\','/').Split('/') | ForEach-Object {[uri]::EscapeDataString($_)}
            $uri = $HttpBaseUrl.TrimEnd('/') + '/Gunny/' + ($segments -join '/')
            $resp = Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing -TimeoutSec 15
            if ([int]$resp.StatusCode -ne 200) { throw "Resource HTTP probe expected 200: $uri got $($resp.StatusCode)" }
            Write-Host "RESOURCE_HTTP_200 set=$($audit.Name) uri=$uri"
        }
    }
}
$audits = @($sets | ForEach-Object { Test-ResourceSet $_ })
foreach ($a in $audits) { Write-Host "RESOURCE_AUDIT name=$($a.Name) files=$($a.Count) missing=$($a.Missing) size=$($a.SizeMismatch) hash=$($a.HashMismatch) healthy=$($a.Healthy)" }
$bad = @($audits | Where-Object { -not $_.Healthy })
if ($bad.Count -gt 0) {
    if (-not $Apply) { throw "Gunny v389 resource drift detected: $(@($bad.Name) -join ', '). Re-run with -Apply to self-heal from pinned releases." }
    foreach ($a in $bad) {
        $set = @($sets | Where-Object { $_.Name -eq $a.Name })[0]
        if (@('farm','observed') -contains $set.Name) {
            & $set.Script -TargetRoot $TargetRoot -ManifestPath $set.Manifest -SourceRef $set.SourceRef
            continue
        }
        $packagePath = Get-VerifiedPackage $set
        switch ($set.Name) {
            'map' { & $set.Script -TargetRoot $TargetRoot -PackagePath $packagePath -ExpectedSha256 $set.Sha -ExpectedMapDirs 378 -ExpectedFiles 1719 }
            'audio' { & $set.Script -TargetRoot $TargetRoot -PackagePath $packagePath -ExpectedSha256 $set.Sha -ExpectedFiles 179 }
            'recovery' { & $set.Script -TargetRoot $TargetRoot -PackagePath $packagePath -ExpectedSha256 $set.Sha -ExpectedFiles 453 }
        }
    }
    $audits = @($sets | ForEach-Object { Test-ResourceSet $_ })
    $bad = @($audits | Where-Object { -not $_.Healthy })
    if ($bad.Count -gt 0) { throw "Gunny v389 resource drift remains after repair: $(@($bad.Name) -join ', ')" }
}
$residualManifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'resources\gunny-v389-residual-recovery.json'
$residualRestore = Join-Path $PSScriptRoot 'Restore-GunnyV389ResidualAssets.ps1'
if (-not (Test-Path -LiteralPath $residualManifestPath -PathType Leaf)) { throw "Residual resource manifest missing: $residualManifestPath" }
if (-not (Test-Path -LiteralPath $residualRestore -PathType Leaf)) { throw "Residual restore tool missing: $residualRestore" }
$residualManifest = Get-Content -LiteralPath $residualManifestPath -Raw | ConvertFrom-Json
$residualBad = @()
foreach ($asset in @($residualManifest.assets)) {
    $dst = Join-Path $webRoot ([string]$asset.target)
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { $residualBad += $asset; continue }
    if ((Get-Item -LiteralPath $dst).Length -ne [int64]$asset.size) { $residualBad += $asset; continue }
    if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne ([string]$asset.sha256).ToUpperInvariant()) { $residualBad += $asset }
}
Write-Host "RESOURCE_AUDIT name=residual files=$(@($residualManifest.assets).Count) drift=$($residualBad.Count) healthy=$($residualBad.Count -eq 0)"
if ($residualBad.Count -gt 0) {
    if (-not $Apply) { throw "Gunny v389 residual resource drift detected: $($residualBad.Count) file(s). Re-run with -Apply." }
    & $residualRestore -WebRoot $webRoot -ManifestPath $residualManifestPath -Force
    foreach ($asset in @($residualManifest.assets)) {
        $dst = Join-Path $webRoot ([string]$asset.target)
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw "Residual resource still missing after repair: $($asset.target)" }
        if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne ([string]$asset.sha256).ToUpperInvariant()) { throw "Residual resource hash mismatch after repair: $($asset.target)" }
    }
}
Invoke-HttpSamples $audits
if (-not $SkipHttpProbe -and -not [string]::IsNullOrWhiteSpace($HttpBaseUrl)) {
    foreach ($asset in @($residualManifest.assets)) {
        $uri = $HttpBaseUrl.TrimEnd('/') + [string]$asset.requestPath
        $resp = Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing -TimeoutSec 15
        if ([int]$resp.StatusCode -ne 200) { throw "Residual resource HTTP probe expected 200: $uri got $($resp.StatusCode)" }
    }
    Write-Host "RESOURCE_HTTP_RESIDUAL=PASS probes=$(@($residualManifest.assets).Count)"
}
Write-Host "GUNNY_V389_RESOURCE_GUARD=PASS sets=$($audits.Count + 1) files=$((($audits | Measure-Object Count -Sum).Sum) + @($residualManifest.assets).Count) apply=$Apply"