<#
    Lifecycle tool for the board system (board seq 368, verbs added seq 1092).

    The system is TWO PROCESSES - the board service and the herdr_sync.py
    sidecar - plus four standing agents in herdr panes. Every verb below acts
    on the two processes; only `up` spawns agents, because a pane outlives a
    board restart and killing one is a decision, not a side effect.

      run.ps1 [verb]        default verb is `up`

      up        board + sidecar + the fleet (Fable/Opus/Sonnet/Haiku),
                each in its own herdr pane carrying its role as an APPENDED
                system prompt (roles/*.md) so it knows its responsibility for
                the whole session, not just its first turn. The reboot drill.
      start     board + sidecar, no agents
      status    what is actually running, and whether it is the code on disk.
                Exits 1 if the board is not answering, so it can gate a script.
      stop      stop board + sidecar (announced first). Panes are left alone.
      restart   stop, then start. No rebuild - same binary comes back.
      rebuild   THE DEPLOY DRILL: refuse on a dirty tree, stop both processes,
                build with the commit stamped in, start, then the fleet.
      logs      tail the four runtime logs (-Tail N, default 20)
      help      this list

    Run it from anywhere:  pwsh -File message_board\run.ps1 <verb>

    IF A VERB THAT STARTS THE SIDECAR DOES NOT RETURN, IT PROBABLY WORKED.
    Through a pipeline (a tool harness, `| cat`) the script can start the
    sidecar and then sit, while the same command run directly returns in
    seconds - measured at 30s once and past a 120s tool timeout once. The
    work is done; the caller's stdout is held. `restart` and `up` are the
    verbs that hit it because they always start a sidecar. Do not verify by
    waiting - run `status` from another shell and read the uptime and pid.
    Full measurement in the Start-BoardSidecar comment block below.

    Building is THIS script's job, not a command to memorise. A missing binary
    is built automatically by `up`/`start`. Either way the commit hash is
    stamped in, so GET /build can answer "is the running server the code we
    reviewed" without anyone having to remember two -define flags.
    Windows PowerShell 5 and pwsh 7 both work.

    Safe to run twice: `up` skips an agent whose topic is already active on
    the board rather than duplicating it, and skips a board that is already
    answering.

    The codex coordinator is NOT spawned here - Glenn drives that one.
#>
[CmdletBinding()]
param(
    # What to do. Positional, so `run.ps1 status` works; defaults to `up`,
    # which is what the bare invocation has always meant.
    [Parameter(Position = 0)]
    [ValidateSet('up', 'start', 'status', 'stop', 'restart', 'rebuild', 'logs', 'help')]
    [string]$Command = 'up',

    # PRE-VERB SPELLINGS, STILL LOAD-BEARING. CLAUDE.md, AGENTS.md, the
    # board-monitor skill and every agent that has read them type these, and
    # a session that starts by failing its check-in is the exact outage this
    # script exists to prevent. They are normalised to verbs below so there is
    # ONE code path underneath and not two that can drift apart.
    #   -ServiceOnly  == start        -Rebuild               == rebuild
    #                                 -Rebuild -ServiceOnly  == rebuild, no fleet
    [switch]$ServiceOnly,
    [switch]$Rebuild,

    # Lines per log for the `logs` verb.
    [int]$Tail = 20
)

$ErrorActionPreference = 'Stop'
$board = 'http://127.0.0.1:7666'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path

# The service resolves roles/ and spawn_prompts/ relative to its working
# directory, and board.jsonl lives beside the exe - so it must run from here.
Set-Location $here

$exe = Join-Path $here 'message_board.exe'

# ── flags → verbs ───────────────────────────────────────────────────────
# Done once, here, before anything reads $Command. The switches only ever
# CHOOSE a verb; nothing below this block tests $Rebuild, so there is no
# second definition of what -Rebuild means waiting to disagree with the first.
if ($Rebuild) {
    if ($Command -eq 'start') { $Command = 'rebuild'; $ServiceOnly = $true }
    elseif ($Command -eq 'up') { $Command = 'rebuild' }
} elseif ($ServiceOnly -and $Command -eq 'up') {
    $Command = 'start'
}
# -ServiceOnly alongside `rebuild` means rebuild and come back without agents.
$doFleet = ($Command -eq 'up') -or ($Command -eq 'rebuild' -and -not $ServiceOnly)

# ── shared helpers ──────────────────────────────────────────────────────

# THE ONLY WAY THE SERVICE SHOULD EVER BE BUILT.
#
# The binary reports its own commit through BUILD_HASH/BUILD_TIME, which are
# compile-time defines - so a build that forgets them produces a binary that
# honestly says "unstamped" and cannot answer the one question the stamp
# exists for. Leaving those flags to human memory would make the mechanism
# that catches "nobody remembered to deploy" depend on remembering to build
# it right, which is the same failure one level down.
#
# So the flags live here, in the ordinary path, and nobody has to know them.
function Build-Board {
    $root = Split-Path -Parent $here
    $hash = (& git -C $root rev-parse --short HEAD 2>$null)
    $time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
    Push-Location $root
    try {
        if (-not $hash) {
            # No git, no honest hash. Build anyway and let the binary say
            # "unstamped" - never invent a plausible one, because a confident
            # wrong hash is worse than none: it would be believed.
            Write-Warning "[build] no git commit available - binary will report 'unstamped'"
            & odin build message_board -out:message_board/message_board.exe
        } else {
            Write-Host "[build] $hash ($time)"
            # SINGLE QUOTES, NOT DOUBLE - Odin's -define parser tries bool,
            # then int/float, before ever considering a string, and only
            # strips '' (not "") as a string delimiter (odin/src/main.cpp,
            # build_param_to_exact_value). An unquoted short hash that is
            # all-digit, or digit-then-'e'-then-non-numeric (like 1ea0bf5,
            # a real hash this repo has had), silently becomes an integer -
            # X-Board-Build would then read "%!s(int=...)" and the deploy
            # check this stamp exists for goes quietly blind. Board seq
            # 1403/1405/1407 (Yggdrasil task #103): found live on Yggdrasil's
            # own build.ps1, confirmed latent here too.
            & odin build message_board -out:message_board/message_board.exe "-define:BUILD_HASH='$hash'" "-define:BUILD_TIME='$time'"
        }
    } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "odin build failed with exit code $LASTEXITCODE" }
}

function Test-Board {
    try { $null = Invoke-RestMethod -Uri "$board/agents" -TimeoutSec 2; return $true }
    catch { return $false }
}

# THE STAMP DESCRIBES HEAD. THE COMPILER READS THE WORKING TREE.
#
# Build-Board takes its hash from `git rev-parse HEAD` and then compiles
# whatever is on disk. Those are the same thing only when the tree is clean,
# and in a shared tree with concurrent agents they disagree BY DEFAULT - one
# agent mid-edit is the normal state here, not an edge case. A -Rebuild in
# that window ships half-finished uncommitted code wearing a clean commit
# hash: precisely the lie the stamp exists to prevent, produced by the stamp,
# and believed because the stamp is what everyone checks.
#
# It cannot be caught afterwards. The artifact carries no trace of the tree it
# was built from - a fresh compile of a dirty tree has a newer mtime than the
# commit, exactly like an honest one - so `git status` AT BUILD TIME is the
# only moment the fact exists. That is why this is in the tool and not in a
# checklist: both rung checks in use (live /build vs HEAD, and exe-newer-than-
# commit) are structurally blind to it.
#
# --porcelain covers tracked modifications, staged changes AND untracked files
# in one pass, which is what "what will the compiler actually read" requires:
# an untracked scratch .odin compiles exactly like a tracked one.
function Get-DirtyCompileInputs {
    $root = Split-Path -Parent $here
    return @(& git -C $root status --porcelain -- '*.odin' 2>$null | Where-Object { $_ })
}

# NO OVERRIDE FLAG, AND THAT IS THE DESIGN. A -Force here would be taken every
# time it appeared, because it appears exactly when someone is in a hurry. The
# bare `odin build` below IS the valve: it produces a working binary that
# answers "unstamped" on every /build and every X-Board-Build header, so the
# honesty is loud and travels with the artifact instead of living in the
# memory of whoever bypassed the check.
function Deny-DirtyBuild($dirty) {
    Write-Warning "[build] REFUSING TO BUILD - uncommitted changes to compiled sources"
    Write-Host   "  The stamp comes from git HEAD; the compiler reads the working tree."
    Write-Host   "  Building now yields a binary reporting a commit it does not contain:"
    foreach ($d in $dirty) { Write-Host "      $d" }
    Write-Host   "  Three ways on, all of them honest:"
    Write-Host   "      commit      - HEAD and tree agree, the stamp is true"
    Write-Host   "      git stash   - the same, temporarily"
    Write-Host   "      odin build message_board -out:message_board/message_board.exe"
    Write-Host   "                  - no -define flags, so the binary says 'unstamped'"
    Write-Host   "  Only *.odin is checked. Dirt in run.ps1, board_check.py or docs does"
    Write-Host   "  not refuse - the binary is still exactly HEAD's code and the stamp is true."
}

# Names of agents herdr currently has a pane for. The board's own "active" flag
# is a CHATTINESS measure - it goes false after 20 minutes of silence - and a
# standing agent waiting for work is silent by design. Pane liveness is the
# honest answer to "is this agent already running?".
function Get-LivePaneNames {
    try {
        $snap = Get-BoardJson '/herdr'
        return @($snap | Where-Object { $_.name } | ForEach-Object { $_.name })
    } catch { return @() }
}

# EVERY JSON ARRAY THIS SCRIPT READS GOES THROUGH HERE, and the reason is a
# one-character difference that silently reports the wrong number:
#
#     @(Invoke-RestMethod $url).Count   ->  1     (any array, any length)
#     $x = Invoke-RestMethod $url; @($x).Count  ->  52
#
# Invoke-RestMethod writes a JSON array to the pipeline as ONE object without
# enumerating it, so the array subexpression wraps it instead of unrolling it.
# Nothing throws: `status` cheerfully reported "1 active of 1 known" against a
# 52-agent roster, and the pane check it feeds decides whether four agents get
# spawned. A count that is wrong but plausible is worse than a crash, so the
# unwrapping lives in one function rather than at four call sites.
function Get-BoardJson([string]$path, [int]$timeout = 5) {
    $r = Invoke-RestMethod -Uri "$board$path" -TimeoutSec $timeout
    return @($r)
}

# The sidecar is a SEPARATE PROCESS, so finding it means asking the OS, not
# the board. Get-CimInstance and not pkill/pgrep: those cannot see Windows
# processes here at all, and every cleanup built on them has been a silent
# no-op that reported success.
#
# One implementation, every caller - the stop path, the rebuild stop, the
# already-running check and `status`. This file already carries the reason
# (see the POST /spawn note in section 3): two implementations of one rule is
# how the rule drifts, and a stop that matched a different set than the
# detect would either kill nothing or start a second sidecar.
function Get-SidecarProcess {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -match 'herdr_sync\.py' })
}

function Get-BoardProcess {
    return @(Get-Process message_board -ErrorAction SilentlyContinue)
}

# SAY IT ON THE BOARD BEFORE DOING IT. The board is how the fleet coordinates,
# so taking it away unannounced is the one outage nobody can be told about
# afterwards. A bare `catch { }` here once swallowed the announcement whole:
# the drill that exists to make restarts VISIBLE could fail invisibly. Say so
# and carry on - the stop is still the right thing to do, but nobody should
# have to infer that it happened.
function Send-BoardNote($text) {
    if (-not (Test-Board)) { return $false }
    $note = @{ agent = 'run.ps1'; kind = 'status'; text = $text } | ConvertTo-Json -Compress
    try { $null = Invoke-RestMethod -Uri "$board/post" -Method Post -Body $note -TimeoutSec 5; return $true }
    catch {
        Write-Warning "[board] could not announce '$text' ($($_.Exception.Message)) - proceeding anyway"
        return $false
    }
}

function Stop-BoardService($announce) {
    if (Test-Board) {
        if ($announce) { $null = Send-BoardNote $announce; Start-Sleep -Seconds 5 }
    } elseif (-not (Get-BoardProcess)) {
        Write-Host "[board] not running"
        return
    }
    Write-Host "[board] stopping"
    Get-BoardProcess | Stop-Process -Force -ErrorAction SilentlyContinue
    # CONFIRM THE PORT IS FREE, do not assume Stop-Process was instant. A start
    # that races a dying process gets "address in use" and dies hidden behind
    # -WindowStyle Hidden, which reads exactly like "the board never came up".
    foreach ($i in 1..10) {
        Start-Sleep -Milliseconds 300
        if (-not (Get-BoardProcess) -and -not (Test-Board)) { return }
    }
    if (Test-Board) { Write-Warning "[board] still answering after the stop - something else is serving $board" }
}

function Stop-BoardSidecar {
    $procs = Get-SidecarProcess
    if ($procs.Count -eq 0) { Write-Host "[sidecar] not running"; return }
    foreach ($p in $procs) {
        Write-Host "[sidecar] stopping (pid $($p.ProcessId))"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# ── 1. Board service ────────────────────────────────────────────────────
# Everything downstream depends on this: an agent that cannot reach the
# board fails its check-in and comes up unaware of the rest of the fleet.
function Start-BoardService {
    if (Test-Board) {
        Write-Host "[board] already up"
        return
    }
    if (-not (Test-Path $exe)) {
        Write-Host "[board] no binary yet - building"
        Build-Board
    }
    Write-Host "[board] starting..."
    # KEEP WHAT THE SERVICE SAYS. This used to start with no redirection at
    # all, so anything the process printed went nowhere - and when it died
    # unexplained, the reason died with it. One redirect is the difference
    # between "the board crashed" and "the board crashed, and here is what it
    # said on the way out".
    # Both names end in .log so the existing *.log gitignore rule covers them.
    # A runtime file the SOURCE does not declare is invisible to the gitignore
    # check in board_check.py, so a log written by this script must not need a
    # new rule that nothing would enforce.
    $log = Join-Path $here 'service.log'
    Start-Process -WindowStyle Hidden -FilePath $exe -WorkingDirectory $here `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $here 'service.err.log')

    $up = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 500
        if (Test-Board) { $up = $true; break }
    }
    if (-not $up) { throw "board did not answer on $board within 10s - start it by hand and check its window" }
    # Report what actually came up, not what we think we built. This is the
    # deploy check in one line: 'unstamped', or a hash you do not recognise,
    # means the running service is not the code you meant to ship.
    try {
        $b = Invoke-RestMethod -Uri "$board/build" -TimeoutSec 5
        Write-Host "[board] up - running $($b.commit) built $($b.built)"
    } catch {
        $b = $null
        Write-Host "[board] up (no /build endpoint - binary predates build identity)"
    }
    # WE ACTUALLY STARTED SOMETHING, so say so on the board. Only the rebuild
    # path announced before, because that is the path that STOPS a running
    # board - but a restore after an unexplained outage is exactly when the
    # board most needs to say it is back, and it said nothing. Finding it
    # already up stays silent; that is not an event.
    $null = Send-BoardNote "board started - running $(if ($b) { $b.commit } else { 'an unstamped binary' })"
}

# ── 2. herdr sidecar ────────────────────────────────────────────────────
# Feeds live pane state into the roster badges and warns about spawns that
# never check in. Optional: the fleet works without it, just blinder.
function Start-BoardSidecar {
    if ((Get-SidecarProcess).Count -gt 0) {
        Write-Host "[sidecar] already running"
        return
    }
    if (-not (Test-Path (Join-Path $here 'herdr_sync.py'))) {
        Write-Warning "[sidecar] herdr_sync.py not found - skipping (roster badges will be blank)"
        return
    }
    Write-Host "[sidecar] starting herdr_sync.py"
    # KEEP WHAT THE SIDECAR SAYS, for the same reason the service got this
    # treatment above: unredirected, everything it printed went nowhere, so a
    # sidecar that died took its explanation with it. Its whole job is
    # reporting on other processes, and it is the one we cannot ask.
    #
    # THIS LINE IS NEUTRAL FOR THE COLD-BOOT HANG - it neither causes it nor
    # cures it - and the measurements are recorded here because #55 was
    # written expecting it to be the cure and I twice reported it settled.
    #
    # WITHOUT A PIPELINE, nothing holds: the committed script with the sidecar
    # killed returned in 3s from a direct `pwsh -File`, and a minimal probe
    # returned in ~1s with a child that had 39s left - identically with and
    # without redirection.
    #
    # THROUGH A PIPELINE IT IS A DIFFERENT STORY, and this is the part I got
    # wrong the first time by measuring only the direct case: with the board
    # already up, `run.ps1 start | cat` starts the sidecar and then does
    # NOT return - held to a 30s ceiling, with this redirect already in place.
    # So the caller's stdout genuinely can be held open past our exit, and the
    # redirect does not prevent it.
    #
    # BUT THE HOLDER IS NOT Start-Process AND SO NOT THIS LINE: the same
    # minimal probe through the same pipeline, redirected and unredirected,
    # both released in under a second. A plain hidden child does not hold the
    # pipe; herdr_sync.py does. It shells out to `herdr agent list` on every
    # tick, so it has grandchildren of its own, and those are the untested
    # part. Whoever chases this should start there and not here.
    #
    # Both names end in .log so the blanket *.log rule already covers them -
    # deliberately NOT a new gitignore rule, because a runtime file this
    # SCRIPT writes is invisible to board_check.py's declared-runtime-file
    # scan (that derives from main.odin), so a bespoke rule here would be one
    # nothing enforces. Verified with `git check-ignore -v` rather than
    # assumed: both resolve to .gitignore:7 *.log.
    Start-Process -WindowStyle Hidden -FilePath 'python' -ArgumentList 'herdr_sync.py' -WorkingDirectory $here `
        -RedirectStandardOutput (Join-Path $here 'sidecar.log') `
        -RedirectStandardError  (Join-Path $here 'sidecar.err.log')
}

# ── reporting verbs ─────────────────────────────────────────────────────

function Format-Age([double]$sec) {
    if ($sec -lt 0)     { return '?' }
    if ($sec -lt 60)    { return ("{0:n0}s" -f $sec) }
    if ($sec -lt 3600)  { return ("{0:n0}m" -f ($sec / 60)) }
    if ($sec -lt 86400) { return ("{0:n0}h{1:n0}m" -f [math]::Floor($sec / 3600), [math]::Floor(($sec % 3600) / 60)) }
    return ("{0:n0}d{1:n0}h" -f [math]::Floor($sec / 86400), [math]::Floor(($sec % 86400) / 3600))
}

# WHAT IS RUNNING, AND IS IT THE CODE ON DISK. Those are two questions and the
# second is the one that has cost evenings here: a board answering happily on
# a binary six commits behind looks identical, from the outside, to a healthy
# one. So this reports the running commit against HEAD and against the working
# tree, and never says "healthy" on the strength of a 200 alone.
#
# Returns 0 if the board answers, 1 if it does not, so `run.ps1 status` can
# gate a script instead of being read by a human every time.
function Show-Status {
    $root = Split-Path -Parent $here
    $now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # --- the board ---
    $b = $null
    try { $b = Invoke-RestMethod -Uri "$board/build" -TimeoutSec 5 } catch { }
    $bproc = Get-BoardProcess
    $answering = [bool]$b
    if (-not $b -and (Test-Board)) {
        # Answers /agents but not /build: an older binary, still a live board.
        $answering = $true
        Write-Host "[board]   up   $board  (no /build endpoint - binary predates build identity)"
    } elseif ($b) {
        Write-Host "[board]   up   $board  commit $($b.commit)  built $($b.built)  uptime $(Format-Age ($now - $b.started))"
    } elseif ($bproc.Count -gt 0) {
        # THE WORST CASE TO MISREPORT: the process exists, so a naive check
        # calls it up, while every agent's check-in is failing.
        Write-Warning "[board]   process alive (pid $($bproc[0].Id)) but NOT answering $board - see service.err.log"
    } else {
        Write-Warning "[board]   DOWN - nothing listening on $board  (run.ps1 start)"
    }

    # --- is it the code on disk ---
    $head = (& git -C $root rev-parse --short HEAD 2>$null)
    if ($b -and $head) {
        if ($b.commit -eq 'unstamped') {
            Write-Host "          running an UNSTAMPED binary - it cannot say what code it is (HEAD is $head)"
        } elseif ($b.commit -ne $head) {
            # A STAMP MISMATCH IS NOT A DEPLOY GAP BY ITSELF, and this line
            # used to claim it was. Caught within the hour by the state it
            # misreported: b501d57 landed the watchdog fix, which touches only
            # herdr_sync.py and board_check.py, and `restart` had already
            # deployed it correctly - a sidecar runs its source, it is not
            # compiled. The binary was byte-for-byte right for HEAD and this
            # line called it "not this tree's code".
            #
            # The stamp names the commit the binary was BUILT from; what makes
            # it stale is a change to something the compiler reads. So ask
            # exactly that, and only cry drift when a rebuild would actually
            # produce a different binary. A checker that cries wolf on every
            # docs commit is one nobody reads by the time it is right.
            $null = & git -C $root cat-file -e "$($b.commit)^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "          running $($b.commit), git HEAD is $head - $($b.commit) is not a commit here, so the two cannot be compared"
            } else {
                $changed = @(& git -C $root diff --name-only "$($b.commit)..HEAD" -- '*.odin' 2>$null | Where-Object { $_ })
                if ($changed.Count -eq 0) {
                    Write-Host "          running $($b.commit), git HEAD is $head - no compiled source changed between them,"
                    Write-Host "          so the running binary is still HEAD's code and only the label is behind"
                } else {
                    Write-Host "          DRIFT: running $($b.commit), git HEAD is $head - $($changed.Count) compiled source(s) changed since (run.ps1 rebuild):"
                    foreach ($c in $changed) { Write-Host "              $c" }
                }
            }
        } else {
            Write-Host "          stamp matches git HEAD ($head)"
        }
    }
    $dirty = Get-DirtyCompileInputs
    if ($dirty) {
        # Deliberately said even when the stamp matches: a matching hash on a
        # dirty tree proves the binary was built from THAT COMMIT, not from
        # what the compiler would read now. That gap is the whole reason
        # `rebuild` refuses.
        Write-Host "          $($dirty.Count) uncommitted *.odin change(s) - a rebuild would refuse:"
        foreach ($d in $dirty) { Write-Host "              $d" }
    }
    if (Test-Path $exe) {
        $age = (Get-Date).ToUniversalTime() - (Get-Item $exe).LastWriteTimeUtc
        Write-Host "          binary  $exe  built $(Format-Age $age.TotalSeconds) ago"
    } else {
        Write-Host "          binary  not built yet"
    }

    # --- the sidecar ---
    $sc = Get-SidecarProcess
    if ($sc.Count -gt 0) {
        Write-Host "[sidecar] running (pid $(($sc | ForEach-Object { $_.ProcessId }) -join ', '))"
    } else {
        Write-Host "[sidecar] not running - roster badges and the dead-spawn watchdog are blind (run.ps1 start)"
    }

    if (-not $answering) { return 1 }

    # --- panes and roster ---
    # Two different signals, reported separately because they answer different
    # questions: a pane says a session EXISTS, board activity says it has
    # spoken in the last 20 minutes. A standing agent waiting for work is
    # silent by design, so neither one alone is "the fleet is fine".
    $panes = Get-LivePaneNames
    Write-Host "[panes]   $($panes.Count) named herdr pane(s)$(if ($panes.Count) { ': ' + ($panes -join ', ') })"

    try {
        $agents = @(Get-BoardJson '/agents')
        $live   = @($agents | Where-Object { $_.active })
        Write-Host "[agents]  $($live.Count) active of $($agents.Count) known (active = spoke within 20m)"
        foreach ($a in ($live | Sort-Object -Property last_seen -Descending)) {
            $tag = if ($a.model) { " [$($a.model)]" } else { '' }
            $f   = if ($a.files) { "  files: $($a.files -join ', ')" } else { '' }
            Write-Host "            $($a.agent)$tag  $(Format-Age ($now - $a.last_seen)) ago$f"
        }
    } catch {
        Write-Warning "[agents]  could not read the roster ($($_.Exception.Message))"
    }

    # One line, because an open task nobody owns is the fleet's idle capacity
    # and it is invisible from the process list.
    try {
        $tasks = @(Get-BoardJson '/tasks')
        $open  = @($tasks | Where-Object { $_.state -notin @('Done', 'Superseded') })
        $byState = ($open | Group-Object state | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        Write-Host "[tasks]   $($open.Count) open of $($tasks.Count)$(if ($byState) { " - $byState" })"
    } catch {
        Write-Warning "[tasks]   could not read the task list ($($_.Exception.Message))"
    }

    return 0
}

# The four runtime logs, in one place, because "check its window" is useless
# advice for a process started with -WindowStyle Hidden.
function Show-Logs([int]$n) {
    foreach ($name in @('service.log', 'service.err.log', 'sidecar.log', 'sidecar.err.log')) {
        $p = Join-Path $here $name
        if (-not (Test-Path $p)) { Write-Host "--- $name (absent)"; continue }
        $len = (Get-Item $p).Length
        if ($len -eq 0) { Write-Host "--- $name (empty)"; continue }
        Write-Host "--- $name (last $n of $len bytes)"
        Get-Content -Path $p -Tail $n | ForEach-Object { Write-Host "    $_" }
    }
}

function Show-Usage {
    Write-Host "run.ps1 [verb]   - lifecycle for the board service + herdr sidecar"
    Write-Host ""
    Write-Host "  up        board + sidecar + the standing fleet   (default)"
    Write-Host "  start     board + sidecar, no agents             (was -ServiceOnly)"
    Write-Host "  status    what is running, and whether it is the code on disk"
    Write-Host "  stop      stop board + sidecar, announced first; panes untouched"
    Write-Host "  restart   stop, then start - same binary comes back"
    Write-Host "  rebuild   the deploy drill: refuse on a dirty tree, build stamped,"
    Write-Host "            restart both processes, then the fleet   (was -Rebuild)"
    Write-Host "  logs      tail service/sidecar logs (-Tail N, default 20)"
    Write-Host "  help      this list"
    Write-Host ""
    Write-Host "  -ServiceOnly and -Rebuild still work; they select the verbs above."
    Write-Host "  status exits 1 when the board is not answering."
}

# ── dispatch ────────────────────────────────────────────────────────────
# The verbs that do not lead into a start fall out here with an exit code.
switch ($Command) {
    'help' {
        Show-Usage
        exit 0
    }
    'status' {
        # Take the LAST value, not the whole stream. Show-Status prints with
        # Write-Host precisely so its pipeline stays clean, but one stray
        # uncaptured expression in there would turn $code into an array and
        # `exit` would throw - reporting a broken script instead of a broken
        # board, which is the one substitution this verb must never make.
        $code = @(Show-Status)[-1]
        exit ([int]$code)
    }
    'logs' {
        Show-Logs $Tail
        exit 0
    }
    'stop' {
        Stop-BoardService 'board stopping (run.ps1 stop) - hold writes until it is back'
        # BOTH PROCESSES, ALWAYS. Tonight measured the cost of forgetting the
        # second one: two board rebuilds (528f48b, 4f3f28f), zero sidecar
        # restarts, so herdr_sync.py edits sat on disk while the old code kept
        # running and nothing served said otherwise. A stop that leaves half
        # the system up is the same bug wearing a different verb.
        Stop-BoardSidecar
        # SAY WHAT WE DID NOT STOP. The agents are herdr panes and they are
        # still there, still holding their file claims, now talking to a board
        # that is gone. Whoever ran `stop` should know that before they walk
        # away from it.
        Write-Host "[done] board and sidecar stopped. herdr panes are untouched - the agents"
        Write-Host "       are still running and their next board call will fail until 'run.ps1 start'."
        exit 0
    }
}

if ($Command -eq 'rebuild') {
    # REFUSE BEFORE ANNOUNCING, AND BEFORE STOPPING ANYTHING. The order is the
    # whole point: a refusal that has already posted "hold writes for a minute"
    # and killed the board has cost the fleet an outage to tell someone their
    # tree was dirty. Nothing below this line has run yet, so the board serves
    # straight through the refusal and the only casualty is the deploy.
    $dirty = Get-DirtyCompileInputs
    if ($dirty) { Deny-DirtyBuild $dirty; exit 1 }

    Stop-BoardService 'rebuilding and restarting the board - hold writes for a minute'
    # STOP THE SIDECAR TOO - it is a second process and rebuilding the board
    # does not touch it. `rebuild` is THE deploy drill, so it covers both
    # processes by construction rather than by anyone remembering the second
    # one.
    #
    # Deliberately OUTSIDE any "is the board up" guard: that asks whether the
    # BOARD is up, and the sidecar can be running when it is not. Guarding it
    # would skip the sidecar restart on exactly the path where the board had
    # already died - which is when the fleet is most confused about what is
    # running.
    #
    # Nothing restarts it here; Start-BoardSidecar below finds no running
    # sidecar and brings it back, which is why this is a stop and not a
    # stop-and-start pair.
    Stop-BoardSidecar
    Build-Board
} elseif ($Command -eq 'restart') {
    Stop-BoardService 'restarting the board (run.ps1 restart) - hold writes for a few seconds'
    Stop-BoardSidecar
}

Start-BoardService
Start-BoardSidecar

if (-not $doFleet) {
    Write-Host "[done] $Command - service and sidecar only, fleet not spawned"
    return
}

# ── 3. The fleet ────────────────────────────────────────────────────────
# One POST /spawn each, through the same endpoint the board's own spawn
# button uses: unique -<hex> names, prompt files, board announcement and
# herdr panes all come from there. `role` names a roles/<role>.md file the
# server resolves to an absolute path and appends to the system prompt;
# `model` is always explicit, because Glenn's global claude default is
# haiku and would otherwise silently apply to all four.
$fleet = @(
    @{ topic = 'fable';  model = 'fable';  role = 'fable'
       task  = 'Standing planner. Watch the board for asks from glenn or the coordinator, produce read-only plans and create the board tasks. Check GET /tasks for open work.' }
    @{ topic = 'opus';   model = 'opus';   role = 'opus'
       task  = 'Standing implementer. Wait for the coordinator to hand you an approved plan, then claim its tasks and exact files and implement. Check GET /tasks for open work.' }
    @{ topic = 'sonnet'; model = 'sonnet'; role = 'sonnet'
       task  = 'Standing reviewer and fallback implementer. Review completed work read-only when asked; take implementation lanes only when the coordinator reassigns them.' }
    @{ topic = 'haiku';  model = 'haiku';  role = 'haiku'
       task  = 'Standing verifier. Run builds, tests, greps and lookups on request and report counts and failures promptly.' }
)

# The endpoint decides whether a topic is already held - this script does not.
# It used to keep its own duplicate checks (live pane, then board activity),
# and they worked, but coordinator-first spawning calls POST /spawn directly
# and routes around anything that lives out here. Two implementations of one
# rule is how the rule drifts, so there is one, and it is the one every caller
# reaches. See topic_holder() in main.odin.
#
# Still worth giving a just-started sidecar its first tick: the server treats
# an empty pane snapshot as unknown rather than free, so it falls back to
# board activity - correct, but the pane signal is the honest one and it costs
# seconds to wait for it.
if ((Get-LivePaneNames).Count -eq 0) {
    # SAY WHAT WE ARE WAITING FOR AND FOR HOW LONG. This loop can burn 24
    # seconds before the first spawn line appears, and 24 seconds of silence
    # on a cold boot is indistinguishable from a hang to the person watching.
    # That is not hypothetical: this section is why a bootstrap that was
    # working got reported as a ~2 minute hang, and the diagnosis went to the
    # sidecar - a part of the script that was never involved - because the
    # part that WAS involved said nothing while it ran.
    Write-Host "[fleet] waiting up to 24s for the sidecar's first pane snapshot..."
    foreach ($i in 1..8) {
        Start-Sleep -Seconds 3
        if ((Get-LivePaneNames).Count -gt 0) {
            Write-Host "[fleet] panes visible after $($i * 3)s"
            break
        }
        if ($i -eq 8) {
            Write-Host "[fleet] no panes after 24s - carrying on; /spawn falls back to board activity"
        }
    }
}

# The per-spawn ceiling, named rather than buried in the call, because it is
# the number that sets this section's worst case: four members at $SpawnTimeout
# each, plus the pane wait above and the 2s settle after each real spawn.
$SpawnTimeout = 30
$fleetStart   = Get-Date
$n            = 0

foreach ($a in $fleet) {
    $n++
    # ANNOUNCE BEFORE THE CALL, NOT AFTER IT. Every line in this loop used to
    # print on COMPLETION, so a /spawn that sits for its full timeout produced
    # no output at all while it sat - and four of those in a row is two silent
    # minutes with nothing on screen naming which member is stuck. A progress
    # line that only appears once the wait is over reports history, not state.
    # Printed before, it means the last line on screen is always the thing we
    # are currently waiting for.
    Write-Host "[$($a.topic)] spawning ($n of $($fleet.Count), up to ${SpawnTimeout}s)..."
    $t0 = Get-Date
    $body = @{ name = $a.topic; model = $a.model; role = $a.role; prompt = $a.task } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "$board/spawn" -Method Post -Body $body -TimeoutSec $SpawnTimeout
        $took = [int]((Get-Date) - $t0).TotalSeconds
        if ($r.reused) {
            Write-Host "[$($a.topic)] already up as $($r.agent) (by $($r.signal)) [${took}s]"
        } else {
            Write-Host "[$($a.topic)] spawned as $($r.agent) (model $($a.model), role $($a.role)) [${took}s]"
            Start-Sleep -Seconds 2   # let herdr finish one pane before the next
        }
    } catch {
        # The elapsed time is the diagnosis here. A spawn that fails in under a
        # second is a refusal the server chose to send; one that fails at the
        # ceiling is a timeout, and those want opposite fixes.
        $took = [int]((Get-Date) - $t0).TotalSeconds
        Write-Warning "[$($a.topic)] spawn failed after ${took}s: $($_.Exception.Message)"
    }
}

# STATE THE BUDGET WE ACTUALLY SPENT. The whole reason this section was blamed
# for a hang is that nobody could tell a slow bootstrap from a stuck one after
# the fact - and the total is the one number that settles it in the report.
$fleetTook = [int]((Get-Date) - $fleetStart).TotalSeconds
Write-Host ""
Write-Host "[done] board $board - fleet section took ${fleetTook}s. Open it to watch them check in."
