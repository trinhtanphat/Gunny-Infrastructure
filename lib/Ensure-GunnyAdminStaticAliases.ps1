[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AdminRoot,
    [string]$SiteName = 'Default Web Site',
    [string]$ProbeBaseUrl = ''
)
$ErrorActionPreference='Stop'
Import-Module WebAdministration

if(-not(Test-Path -LiteralPath $AdminRoot -PathType Container)){throw "AdminGunny root missing: $AdminRoot"}
foreach($name in @('Scripts','Images')){
    $physical=Join-Path $AdminRoot $name
    if(-not(Test-Path -LiteralPath $physical -PathType Container)){throw "AdminGunny static directory missing: $physical"}
    $existing=@(Get-WebVirtualDirectory -Site $SiteName | Where-Object {$_.Path -eq "/$name"})[0]
    if($existing){
        $current=[Environment]::ExpandEnvironmentVariables([string]$existing.PhysicalPath).TrimEnd('\')
        $wanted=[Environment]::ExpandEnvironmentVariables($physical).TrimEnd('\')
        if(-not $current.Equals($wanted,[StringComparison]::OrdinalIgnoreCase)){
            throw "Root /$name virtual directory already exists with different target: $current"
        }
    }else{
        New-WebVirtualDirectory -Site $SiteName -Name $name -PhysicalPath $physical | Out-Null
    }
}
if($ProbeBaseUrl){
    foreach($path in @('/Scripts/jquery-1.7.min.js','/Images/ga.png')){
        $r=Invoke-WebRequest -Uri ($ProbeBaseUrl.TrimEnd('/')+$path) -Method Head -UseBasicParsing -TimeoutSec 10
        if([int]$r.StatusCode-ne200){throw "Admin static alias probe failed: $path status=$($r.StatusCode)"}
        Write-Host "ADMIN_STATIC_ALIAS_PROBE=PASS status=200 path=$path"
    }
}
Write-Host "GUNNY_ADMIN_STATIC_ALIASES=PASS site=$SiteName root=$AdminRoot"
