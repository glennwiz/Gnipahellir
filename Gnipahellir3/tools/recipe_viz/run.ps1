# Recipe DAG viewer — live watcher.
#
#   .\tools\recipe_viz\run.ps1
#
# Builds and opens the viewer, then watches src\*.odin: any save rebuilds the
# tool and swaps the window for one showing the new graph.  A failed build
# leaves the old window up and prints the errors here.  Close the window to
# stop watching.  (Two alternating exe names so the running exe never blocks
# the next link.)

$root = Resolve-Path "$PSScriptRoot\..\.."
$proc = $null
$slot = 0
$last = $null

function Src-Stamp {
    (Get-ChildItem "$root\src\*.odin" |
        Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
}

while ($true) {
    $now = Src-Stamp
    if ($now -ne $last) {
        $last = $now
        $exe = "$PSScriptRoot\recipe_viz$slot.exe"
        Write-Host "[recipe_viz] building..." -ForegroundColor Cyan
        odin build "$root\tools\recipe_viz" "-out:$exe" -subsystem:windows
        if ($LASTEXITCODE -eq 0) {
            $old = $proc
            $proc = Start-Process $exe -WorkingDirectory $PSScriptRoot -PassThru
            if ($old -and -not $old.HasExited) { Stop-Process -Id $old.Id -Force }
            $slot = 1 - $slot
            Write-Host "[recipe_viz] up to date." -ForegroundColor Green
        } else {
            Write-Host "[recipe_viz] build failed - old graph stays up; fix and save again." -ForegroundColor Yellow
        }
    }
    if ($proc -and $proc.HasExited) { break }
    Start-Sleep -Milliseconds 500
}
