# uia3.ps1 -- bring the SDD dialog to the foreground, dump its text + buttons.
# Reports 3 ways: console Write-Host, webhook content (json), webhook file.
$ErrorActionPreference = 'Continue'
$WH = 'https://discord.com/api/webhooks/1495923230614229024/Uf2BDYaB9-WlIHWGzilU3Tb4pvi0JlVN0ZW1kqbUjAkMZV79fCHQoVlBZpZgvmlltWtE'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class W {
 public delegate bool EP(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h,StringBuilder s,int m);
 [DllImport("user32.dll",CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int m);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 public static List<long> wins; static uint wp;
 public static List<long> TopOf(uint pid){ wins=new List<long>(); wp=pid; EnumWindows(Cb,IntPtr.Zero); return wins; }
 static bool Cb(IntPtr h,IntPtr l){ uint p; GetWindowThreadProcessId(h,out p); if(p==wp && IsWindowVisible(h)) wins.Add(h.ToInt64()); return true; }
 public static string Cls(IntPtr h){ var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
 public static string Txt(IntPtr h){ var s=new StringBuilder(512); GetWindowText(h,s,512); return s.ToString(); }
}
'@

$lines = New-Object System.Collections.ArrayList
function A($t){ [void]$lines.Add([string]$t); Write-Host $t }

function Walk($el, $depth) {
    if ($null -eq $el -or $depth -gt 12) { return }
    $ind = '  ' * $depth
    try {
        $nm = $el.Current.Name
        $ct = $el.Current.ControlType.ProgrammaticName -replace 'ControlType\.',''
        $cl = $el.Current.ClassName
        $en = $el.Current.IsEnabled
    } catch { A "$ind[err]"; return }
    $b = ''
    if ($cl -match 'BUTTON') { $b = ' <<BUTTON>>' }
    $e = ''; if (-not $en) { $e = ' [disabled]' }
    $n = ''; if ($nm) { $n = " `"$nm`"" }
    A "$ind$ct$n$e$b"
    try {
        $wk = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $c = $wk.GetFirstChild($el)
        while ($null -ne $c) { Walk $c ($depth+1); $c = $wk.GetNextSibling($c) }
    } catch {}
}

$proc = Get-Process -Name 'Schwab.SI.SI2Desktop.Container' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { A 'ERROR: SDD not running'; }
else {
    $main = $proc.MainWindowHandle.ToInt64()
    $tops = [W]::TopOf([uint32]$proc.Id)
    A "SDD pid=$($proc.Id) main=$main visibleTopWindows=$($tops.Count)"
    $dialog = 0
    foreach ($h in $tops) {
        $cls = [W]::Cls([IntPtr]$h); $txt = [W]::Txt([IntPtr]$h)
        A "  win hwnd=$h class=$cls text=`"$txt`""
        if ($h -ne $main -and $cls -like 'WindowsForms10.Window*') { $dialog = $h }
    }
    if ($dialog -ne 0) {
        A "--- DIALOG hwnd=$dialog : bringing to foreground ---"
        [W]::ShowWindow([IntPtr]$dialog, 5) | Out-Null
        [W]::BringWindowToTop([IntPtr]$dialog) | Out-Null
        [W]::SetForegroundWindow([IntPtr]$dialog) | Out-Null
        Start-Sleep -Milliseconds 600
        try {
            $del = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$dialog)
            A "=== DIALOG UIA TREE ==="
            Walk $del 0
        } catch { A "dialog walk error: $_" }
    } else {
        A 'NO secondary WindowsForms dialog window found (only the main window is visible).'
    }
}

# exfil 1: webhook content (json) -- robust, small payloads
$txtBody = ($lines -join "`n")
if ($txtBody.Length -gt 1850) { $txtBody = $txtBody.Substring(0,1850) }
$json = @{ content = ("``````" + "`n" + $txtBody + "`n" + "``````") } | ConvertTo-Json -Compress
$bf = Join-Path $env:TEMP 'uia3_body.json'
Set-Content -LiteralPath $bf -Value $json -Encoding UTF8
& curl.exe -s -o NUL -w "EXFIL-content http=%{http_code}`n" -A 'DiscordBot (clawcode,1.0)' -H 'Content-Type: application/json' -X POST -d "@$bf" $WH | Write-Host
# exfil 2: file
$rf = Join-Path $env:TEMP 'uia3_dialog.txt'
Set-Content -LiteralPath $rf -Value ($lines -join "`r`n") -Encoding UTF8
& curl.exe -s -o NUL -w "EXFIL-file http=%{http_code}`n" -A 'DiscordBot (clawcode,1.0)' -F "file=@$rf" $WH | Write-Host
Write-Host 'done'
