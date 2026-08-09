# Gnipa Studio — live watcher.
#
#   .\tools\gnipa_studio\run.ps1
#
# Builds and opens the studio, then watches src\*.odin: any save rebuilds the
# tool and swaps the window for one compiled with the new data.  Saves from
# the studio itself write 3-4 gen files, so rebuilds are debounced until the
# stamps have been quiet for ~400 ms.  A failed build leaves the old window up
# and prints the errors here.  Close the window to stop watching.
#
# The alternating slot exes are GUI-subsystem (no stray console); the console
# modes (--extract / --emit-check) use a plain `odin build tools/gnipa_studio`.

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
        # Debounce: wait for the stamps to sit still before building.
        do {
            $prev = $now
            Start-Sleep -Milliseconds 400
            $now = Src-Stamp
        } while ($now -ne $prev)
        $last = $now

        $exe = "$PSScriptRoot\gnipa_studio$slot.exe"
        Write-Host "[gnipa_studio] building..." -ForegroundColor Cyan
        odin build "$root\tools\gnipa_studio" "-out:$exe" -subsystem:windows
        if ($LASTEXITCODE -eq 0) {
            $old = $proc
            $proc = Start-Process $exe -WorkingDirectory $PSScriptRoot -PassThru
            if ($old -and -not $old.HasExited) { Stop-Process -Id $old.Id -Force }
            $slot = 1 - $slot
            Write-Host "[gnipa_studio] up to date." -ForegroundColor Green
        } else {
            Write-Host "[gnipa_studio] build failed - old window stays up; fix and save again." -ForegroundColor Yellow
        }
    }
    if ($proc -and $proc.HasExited) { break }
    Start-Sleep -Milliseconds 500
}
