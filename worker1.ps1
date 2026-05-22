# worker1.ps1 -- SDD UIA worker v1: prove the click.
# Finds the "Download all new files" WinForms button by class+text, posts BM_CLICK
# to its HWND, then watches for: files downloaded / SDD error / modal / timeout.
# Exfils a verdict. No scheduling, no durable install -- this run only.

$ErrorActionPreference = 'Continue'
$WH  = 'https://discord.com/api/webhooks/1495923230614229024/Uf2BDYaB9-WlIHWGzilU3Tb4pvi0JlVN0ZW1kqbUjAkMZV79fCHQoVlBZpZgvmlltWtE'
$rep = Join-Path $env:TEMP 'sdd_worker1_report.txt'
$L   = New-Object System.Collections.ArrayList
function A($t){ [void]$L.Add([string]$t) }
function Flush { Set-Content -LiteralPath $rep -Value ($L -join "`r`n") -Encoding UTF8 }
function Push-Report($tag){
  Flush
  & curl.exe -s -o NUL -w "EXFIL[$tag] http=%{http_code}`n" -A 'DiscordBot (clawcode,1.0)' -F ("file=@$rep") $WH | Write-Host
}

$BTN_CLASS = 'WindowsForms10.BUTTON'
$BTN_TEXT  = 'Download all new files'
$DLDIR     = 'C:\Users\Jas\Desktop\temp'
$BM_CLICK  = 0xF5

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Win {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  public static List<IntPtr> hits;
  static string cpfx, wtxt;
  public static List<IntPtr> FindChildren(IntPtr parent, string classPrefix, string text){
    hits = new List<IntPtr>(); cpfx = classPrefix; wtxt = text;
    EnumChildWindows(parent, ChildCb, IntPtr.Zero);
    return hits;
  }
  static bool ChildCb(IntPtr h, IntPtr l){
    StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
    StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
    if(c.ToString().StartsWith(cpfx) && t.ToString() == wtxt) hits.Add(h);
    return true;
  }
  public static List<string> topList;
  static uint wantPid;
  public static List<string> TopWindows(uint pid){
    topList = new List<string>(); wantPid = pid;
    EnumWindows(TopCb, IntPtr.Zero);
    return topList;
  }
  static bool TopCb(IntPtr h, IntPtr l){
    uint p; GetWindowThreadProcessId(h, out p);
    if(p == wantPid){
      StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
      StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
      topList.Add(h.ToInt64() + "|" + (IsWindowVisible(h)?"vis":"hid") + "|" + c.ToString() + "|" + t.ToString());
    }
    return true;
  }
}
'@

A '===SDD UIA WORKER v1 -- PROVE THE CLICK==='
A ("host=$env:COMPUTERNAME user=$env:USERNAME start=" + (Get-Date -Format 'o'))
A ''

# --- locate SDD ---
$proc = Get-Process -Name 'Schwab.SI.SI2Desktop.Container' -ErrorAction SilentlyContinue | Select-Object -First 1
if(-not $proc){
  A 'FATAL: SDD (Schwab.SI.SI2Desktop.Container) is not running. Cannot proceed.'
  Push-Report 'no-sdd'; return
}
$pid32 = [uint32]$proc.Id
A ("SDD pid=$($proc.Id) mainWindow=$($proc.MainWindowHandle) title=$($proc.MainWindowTitle)")

# --- find the button ---
$btns = [Win]::FindChildren($proc.MainWindowHandle, $BTN_CLASS, $BTN_TEXT)
A ("button matches found=" + $btns.Count)
foreach($b in $btns){ A ("  hwnd=" + $b.ToInt64()) }
if($btns.Count -ne 1){
  A "FATAL: expected exactly 1 button match, got $($btns.Count). Aborting (no click sent)."
  Push-Report 'btn-ambiguous'; return
}
$btnHwnd = $btns[0]
A ("target button hwnd=" + $btnHwnd.ToInt64())
A ''

# --- baseline ---
A '=== BASELINE ==='
$dlBefore = @{}
if(Test-Path -LiteralPath $DLDIR){
  Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | ForEach-Object { $dlBefore[$_.FullName] = $_.LastWriteTimeUtc }
}
A ("download.dir=$DLDIR files.before=" + $dlBefore.Count)
$errlog = Get-ChildItem 'C:\Users\Jas\AppData\Local\Apps\2.0' -Recurse -Filter 'Log_Error.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$errLen0 = 0; if($errlog){ $errLen0 = $errlog.Length }
A ("error.log=" + $(if($errlog){$errlog.FullName}else{'(none)'}) + " bytes.before=$errLen0")
$top0 = [Win]::TopWindows($pid32)
A ("SDD top-level windows before click=" + $top0.Count)
foreach($w in $top0){ A ("  $w") }
A ''

# --- fire the click (PostMessage BM_CLICK -- async, non-blocking) ---
A '=== CLICK ==='
$posted = [Win]::PostMessage($btnHwnd, [uint32]$BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
A ("PostMessage BM_CLICK to button hwnd=" + $btnHwnd.ToInt64() + " returned=$posted at " + (Get-Date -Format 'o'))
Push-Report 'clicked'
A ''

# --- observe ---
A '=== OBSERVE (up to 5 min) ==='
$verdict = 'TIMEOUT'
for($t=1; $t -le 10; $t++){
  Start-Sleep -Seconds 30
  $nf = 0
  if(Test-Path -LiteralPath $DLDIR){
    Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | ForEach-Object {
      if(-not $dlBefore.ContainsKey($_.FullName) -or $dlBefore[$_.FullName] -ne $_.LastWriteTimeUtc){ $nf++ }
    }
  }
  $errLen = 0; $eItem = Get-ChildItem 'C:\Users\Jas\AppData\Local\Apps\2.0' -Recurse -Filter 'Log_Error.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if($eItem){ $errLen = $eItem.Length }
  $topN = [Win]::TopWindows($pid32)
  A ("  t+" + ($t*30) + "s  changedFiles=$nf  errLogBytes=$errLen  topWindows=" + $topN.Count)
  if($nf -gt 0){ $verdict = 'PASS'; break }
  if($errLen -ne $errLen0){ $verdict = 'CLICK-FIRED-BUT-SDD-ERRORED'; break }
  if($topN.Count -gt $top0.Count){ $verdict = 'MODAL'; break }
}
A ''

# --- verdict ---
A '=== VERDICT ==='
A ("RESULT: $verdict")
$newFiles = @()
if(Test-Path -LiteralPath $DLDIR){
  Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | ForEach-Object {
    if(-not $dlBefore.ContainsKey($_.FullName) -or $dlBefore[$_.FullName] -ne $_.LastWriteTimeUtc){
      $newFiles += ($_.FullName + '  [' + $_.Length + 'b  ' + $_.LastWriteTime.ToString('o') + ']')
    }
  }
}
if($newFiles.Count -gt 0){ A "new/changed files:"; $newFiles | ForEach-Object { A "  $_" } }
$topF = [Win]::TopWindows($pid32)
A ("SDD top-level windows after=" + $topF.Count)
foreach($w in $topF){ A "  $w" }
$eF = Get-ChildItem 'C:\Users\Jas\AppData\Local\Apps\2.0' -Recurse -Filter 'Log_Error.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if($eF -and $eF.Length -ne $errLen0){
  A ("--- Log_Error.txt grew (before=$errLen0 after=" + $eF.Length + "), tail: ---")
  (Get-Content -LiteralPath $eF.FullName -Tail 40) | ForEach-Object { A "  $_" }
}
A ("done=" + (Get-Date -Format 'o'))
A '===END==='
Push-Report 'final'
