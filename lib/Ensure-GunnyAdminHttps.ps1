[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PublicHost,
    [string]$SiteName = 'Default Web Site',
    [int]$Port = 443,
    [string]$FirewallRuleName = 'Gunny Admin HTTPS 443',
    [int]$CertYears = 3
)
$ErrorActionPreference='Stop'
Import-Module WebAdministration

if(-not(Get-Website -Name $SiteName -ErrorAction SilentlyContinue)){
    throw "IIS site not found: $SiteName"
}

$friendly="Gunny Admin HTTPS $PublicHost"
$leaf=@(Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.FriendlyName -eq $friendly -and
    $_.Subject -eq "CN=$PublicHost" -and
    $_.Issuer -eq $_.Subject -and
    $_.HasPrivateKey -and
    $_.NotAfter -gt (Get-Date).AddDays(30)
} | Sort-Object NotAfter -Descending)[0]

if(-not$leaf){
    $parsed=$null
    $san=if([Net.IPAddress]::TryParse($PublicHost,[ref]$parsed)){
        "2.5.29.17={text}IPAddress=$PublicHost"
    }else{
        "2.5.29.17={text}DNS=$PublicHost"
    }
    $leaf=New-SelfSignedCertificate -Type Custom -Subject "CN=$PublicHost" -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyUsage DigitalSignature,KeyEncipherment -TextExtension @($san,'2.5.29.37={text}1.3.6.1.5.5.7.3.1') -NotAfter (Get-Date).AddYears($CertYears) -FriendlyName $friendly
}

$certDir='C:\ProgramData\Gunny\certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
$fileHost=$PublicHost -replace '[^A-Za-z0-9._-]','_'
$leafExport=Join-Path $certDir ("Gunny-Admin-$fileHost.cer")
Export-Certificate -Cert $leaf -FilePath $leafExport -Force | Out-Null

if(-not(Get-ChildItem Cert:\LocalMachine\Root | Where-Object {$_.Thumbprint -eq $leaf.Thumbprint})){
    Import-Certificate -FilePath $leafExport -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
}

$bindingInfo="$($PublicHost):$($Port):"
$binding=@(Get-WebBinding -Name $SiteName -Protocol https | Where-Object {
    $_.bindingInformation -eq $bindingInfo
})[0]
if(-not$binding){
    New-WebBinding -Name $SiteName -Protocol https -IPAddress $PublicHost -Port $Port -HostHeader ''
    $binding=@(Get-WebBinding -Name $SiteName -Protocol https | Where-Object {
        $_.bindingInformation -eq $bindingInfo
    })[0]
}
$binding.AddSslCertificate($leaf.Thumbprint,'My')

if(-not(Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue)){
    New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
}else{
    Get-NetFirewallRule -DisplayName $FirewallRuleName | Set-NetFirewallRule -Enabled True -Action Allow | Out-Null
}

$verify=@(Get-WebBinding -Name $SiteName -Protocol https | Where-Object {
    $_.bindingInformation -eq $bindingInfo
})[0]
if(-not$verify){throw "HTTPS binding missing after apply: $bindingInfo"}
if(([string]$verify.certificateHash).ToUpperInvariant() -ne $leaf.Thumbprint.ToUpperInvariant()){
    throw 'HTTPS certificate binding mismatch.'
}
$listener=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
if($listener.Count-eq0){throw "HTTPS listener not ready on port $Port"}

$r=Invoke-WebRequest -Uri "https://$PublicHost/AdminGunny/" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
if([int]$r.StatusCode-ne200){throw "AdminGunny HTTPS probe expected 200 after redirects; got $($r.StatusCode)"}
Write-Host "GUNNY_ADMIN_HTTPS=PASS host=$PublicHost port=$Port cert=$($leaf.Thumbprint) export=$leafExport"
