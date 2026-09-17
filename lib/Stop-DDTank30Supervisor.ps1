param(
  [string]$TaskName='DDTank30-Stack',
  [string]$RuntimeRoot='C:\Gunny-DDTank30\runtime'
)
$ErrorActionPreference='Stop'
$task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if($task){Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue}
Start-Sleep -Seconds 1
$prefix=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')+'\'
function Get-RuntimeProcesses{
  @(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{
    $_.ExecutablePath -and [IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
  })
}
$targets=Get-RuntimeProcesses
foreach($p in $targets|Sort-Object ProcessId -Descending){Write-Host ("Stopping DDTank30 pid=$($p.ProcessId) path=$($p.ExecutablePath)");Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}
$deadline=(Get-Date).AddSeconds(10)
do{Start-Sleep -Milliseconds 250;$remaining=Get-RuntimeProcesses}while($remaining.Count-gt0 -and (Get-Date)-lt$deadline)
if($remaining.Count-gt0){throw "DDTank30 runtime processes remain: $($remaining.ProcessId -join ',')"}
$busy=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue|Where-Object{$_.LocalPort-in 9300,9302,9308})
if($busy.Count-gt0){throw "DDTank30 ports still listening: $($busy.LocalPort -join ',')"}
Write-Host 'PASS: DDTank30 supervisor and runtime children stopped.'