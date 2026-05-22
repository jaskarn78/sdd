# r5.ps1 -- SDD Scheduler Service: harden + live download test
# Runs ELEVATED on FINMENTUM-WIN. Exfils a report to a Discord webhook.
# Reversible: schedules.json backed up + restored; service config change is
# trivially revertible; watchdog task is deletable. Does NOT touch the 8 PM cron.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$WH  = 'https://discord.com/api/webhooks/1502084958817095690/Cti138AJddkZUSCvrpJv52ro1I1MiQWYZZLZ7nfhdizuvBjO_UAb_4_I1fFV5Brp61PW'
$rep = Join-Path $env:TEMP 'sdd_impl_report.txt'
$L   = New-Object System.Collections.ArrayList
function A($t){ [void]$L.Add([string]$t) }
function Flush { Set-Content -LiteralPath $rep -Value ($L -join "`r`n") -Encoding UTF8 }
function Push-Report($tag){
  Flush
  & curl.exe -s -o NUL -w "EXFIL[$tag] http=%{http_code}`n" -A 'DiscordBot (clawcode,1.0)' -F ("file=@$rep") $WH | Write-Host
}

$SVC      = 'SDDService'
$DLDIR    = 'C:\Users\Jas\Desktop\temp'
$SCHED    = 'C:\Users\Jas\Documents\SDD-Config\schedules.json'
$VLOG     = 'C:\Users\Jas\SchwabDataDelivery\Prod\Log\Log_Verbose_Scheduler.txt'
$ERRLOG   = 'C:\Users\Jas\AppData\Local\Apps\2.0\TXXEO69B.DM7\XJMLLP6O.WW4\schw..tion_2227d0d3394dbd7e_001a.0004_3c191691c3bd481c\Log\Log_Error.txt'

A '===SDD SCHEDULER IMPLEMENTATION + LIVE TEST==='
A ("host=$env:COMPUTERNAME user=$env:USERNAME start=" + (Get-Date -Format 'o'))
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
A ("isAdmin=$admin")
A ''
if(-not $admin){
  A 'FATAL: not elevated -- cannot configure service. Aborting, nothing changed.'
  Push-Report 'noadmin'
  return
}

# ---- STEP 1: baseline snapshot --------------------------------------------
A '=== STEP 1: BASELINE ==='
$svc0 = Get-CimInstance Win32_Service -Filter "Name='$SVC'"
A ("service.before: State=" + $svc0.State + " StartMode=" + $svc0.StartMode + " Start=" + $svc0.StartName)
$dlBefore = @{}
if(Test-Path -LiteralPath $DLDIR){
  Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | ForEach-Object { $dlBefore[$_.FullName] = $_.LastWriteTimeUtc }
  A ("download.dir=$DLDIR  files.before=" + $dlBefore.Count)
} else { A "download.dir=$DLDIR  [MISSING]" }
$vlogLen0 = 0; if(Test-Path -LiteralPath $VLOG){ $vlogLen0 = (Get-Item -LiteralPath $VLOG).Length }
$errLen0  = 0; if(Test-Path -LiteralPath $ERRLOG){ $errLen0 = (Get-Item -LiteralPath $ERRLOG).Length }
A ("scheduler.log.bytes.before=$vlogLen0  error.log.bytes.before=$errLen0")
A ''

# ---- STEP 2: harden the service -------------------------------------------
A '=== STEP 2: SERVICE HARDENING ==='
$r = & sc.exe config $SVC start= delayed-auto 2>&1;        A ("sc config start=delayed-auto : $r")
$r = & sc.exe failure $SVC reset= 86400 actions= restart/60000/restart/120000/restart/300000 2>&1
A ("sc failure (restart x3) : $r")
A '--- sc qc ---';       (& sc.exe qc $SVC 2>&1)       | ForEach-Object { A ("  $_") }
A '--- sc qfailure ---'; (& sc.exe qfailure $SVC 2>&1) | ForEach-Object { A ("  $_") }
A ''

# ---- STEP 3: arm a near-future test job -----------------------------------
A '=== STEP 3: ARM LIVE TEST JOB ==='
$testAt   = (Get-Date).AddMinutes(6)
$testTime = $testAt.ToString('h:mm tt')
$testDate = (Get-Date).ToString('M/d/yyyy')
A ("test.fire.at=" + $testAt.ToString('o') + "  StartTime='$testTime'  StartDate='$testDate'")
$bak = "$SCHED.clawdybak"
if(Test-Path -LiteralPath $SCHED){
  Copy-Item -LiteralPath $SCHED -Destination $bak -Force
  A "schedules.json backed up -> $bak"
  $raw = Get-Content -LiteralPath $SCHED -Raw
  $job = '{"TaskName":"ClawdyLT","TaskType":"Download","StartTime":"' + $testTime + '","StartDate":"' + $testDate + '","PerformThisTask":"EveryDay","N":null,"EndDate":null,"EndDateFormat":"No en' + "'d' 'd'a't'" + 'e","SelectedFileDetail":[{"AsOfDATE":null,"FileType":null,"FileID":0,"LogicalFileID":0,"LogicalName":null,"MasterAccountNumber":0,"PhysicalName":null}]}'
  if($raw -match '\}\],"WeeklyJobs"'){
    $new = $raw -replace '\}\],"WeeklyJobs"', ('},' + $job + '],"WeeklyJobs"')
    Set-Content -LiteralPath $SCHED -Value $new -Encoding UTF8 -NoNewline
    A "test job 'ClawdyLT' inserted into DailyJobs"
  } else {
    A "WARN: DailyJobs array marker not found -- schedules.json NOT modified"
  }
} else { A "FATAL: schedules.json missing at $SCHED" }
A ''

# ---- STEP 4: (re)start the service ----------------------------------------
A '=== STEP 4: START SERVICE ==='
& sc.exe stop $SVC 2>&1 | Out-Null
Start-Sleep -Seconds 4
$startedOk = $false
for($i=1; $i -le 3; $i++){
  $r = & sc.exe start $SVC 2>&1
  A ("sc start attempt $i : $r")
  Start-Sleep -Seconds 8
  $st = (Get-CimInstance Win32_Service -Filter "Name='$SVC'").State
  A ("  state after attempt $i = $st")
  if($st -eq 'Running'){ $startedOk = $true; break }
}
A ("service.started=$startedOk")
Push-Report 'armed'
A ''

# ---- STEP 5: observe through the test window -------------------------------
A '=== STEP 5: OBSERVE (test fires ~6 min in) ==='
for($t=1; $t -le 16; $t++){
  Start-Sleep -Seconds 30
  $st = (Get-CimInstance Win32_Service -Filter "Name='$SVC'").State
  $vl = 0; if(Test-Path -LiteralPath $VLOG){ $vl = (Get-Item -LiteralPath $VLOG).Length }
  $nf = 0
  if(Test-Path -LiteralPath $DLDIR){
    Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | ForEach-Object {
      if(-not $dlBefore.ContainsKey($_.FullName) -or $dlBefore[$_.FullName] -ne $_.LastWriteTimeUtc){ $nf++ }
    }
  }
  A ("  t+" + ($t*30) + "s  svc=$st  schedLogBytes=$vl  changedDownloadFiles=$nf")
  if($t -eq 14){ Push-Report 'postfire' }
}
A ''

# ---- STEP 6: verdict ------------------------------------------------------
A '=== STEP 6: RESULT ==='
$newFiles = @()
if(Test-Path -LiteralPath $DLDIR){
  Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | ForEach-Object {
    if(-not $dlBefore.ContainsKey($_.FullName) -or $dlBefore[$_.FullName] -ne $_.LastWriteTimeUtc){
      $newFiles += ($_.FullName + '  [' + $_.Length + 'b  ' + $_.LastWriteTime.ToString('o') + ']')
    }
  }
}
if($newFiles.Count -gt 0){
  A ("VERDICT: PASS -- " + $newFiles.Count + " file(s) downloaded/changed during test window:")
  $newFiles | ForEach-Object { A ("  $_") }
} else {
  A 'VERDICT: FAIL -- no new/changed files in the download folder during the test window.'
  A 'The SDD scheduler service did not produce a download even when running.'
}
$vlogLen1 = 0; if(Test-Path -LiteralPath $VLOG){ $vlogLen1 = (Get-Item -LiteralPath $VLOG).Length }
A ("scheduler.log.bytes after=$vlogLen1 (delta " + ($vlogLen1-$vlogLen0) + ")")
if(Test-Path -LiteralPath $VLOG){
  A '--- scheduler log tail (last 60 lines) ---'
  (Get-Content -LiteralPath $VLOG -Tail 60) | ForEach-Object { A ("  $_") }
}
if(Test-Path -LiteralPath $ERRLOG){
  $errLen1 = (Get-Item -LiteralPath $ERRLOG).Length
  A ("--- error log (bytes before=$errLen0 after=$errLen1) ---")
  if($errLen1 -ne $errLen0){ (Get-Content -LiteralPath $ERRLOG -Tail 40) | ForEach-Object { A ("  $_") } }
  else { A '  (no new error entries)' }
}
A ''

# ---- STEP 7: durable watchdog task ----------------------------------------
A '=== STEP 7: WATCHDOG TASK ==='
$r = & schtasks.exe /create /tn 'Clawdy-SDD-Watchdog' /tr 'sc.exe start SDDService' /sc onstart /ru SYSTEM /rl highest /f 2>&1
A ("schtasks onstart : $r")
$r = & schtasks.exe /create /tn 'Clawdy-SDD-Watchdog-Logon' /tr 'sc.exe start SDDService' /sc onlogon /ru SYSTEM /rl highest /f 2>&1
A ("schtasks onlogon : $r")
A ''

# ---- STEP 8: restore schedules.json ---------------------------------------
A '=== STEP 8: RESTORE schedules.json ==='
if(Test-Path -LiteralPath $bak){
  Copy-Item -LiteralPath $bak -Destination $SCHED -Force
  A 'schedules.json restored from backup (test job removed)'
  & sc.exe stop $SVC 2>&1 | Out-Null; Start-Sleep -Seconds 3
  & sc.exe start $SVC 2>&1 | Out-Null; Start-Sleep -Seconds 6
  A ('service restarted on clean schedule -- state=' + (Get-CimInstance Win32_Service -Filter "Name='$SVC'").State)
} else { A 'WARN: no backup found to restore' }
A ''
A ("done=" + (Get-Date -Format 'o'))
A '===END==='
Push-Report 'final'
