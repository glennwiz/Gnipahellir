<#
    Reboot bootstrap for Glenn's four standing agents (board seq 368).

    Brings the whole fleet up in one command after a machine restart:
    the board service, the herdr sidecar, then Fable / Opus / Sonnet /
    Haiku, each in its own herdr pane carrying its role as an APPENDED
    system prompt (roles/*.md) so it knows its responsibility for the
    whole session, not just its first turn.

    Run it from anywhere:  pwsh -File message_board\run.ps1

    Building is THIS script's job, not a command to memorise:
      -Rebuild       rebuild the service from source and restart it
    A missing binary is built automatically. Either way the commit
    hash is stamped in, so GET /build can answer "is the running
    server the code we reviewed" without anyone having to remember
    two -define flags.
    Windows PowerShell 5 and pwsh 7 both work.

    Safe to run twice: an agent whose topic is already active on the
    board is skipped rather than duplicated.

    The codex coordinator is NOT spawned here - Glenn drives that one.
#>
[CmdletBinding()]
param(
    # Skip the fleet and only bring the service + sidecar up.
    [switch]$ServiceOnly,

    # Rebuild the service from source and restart it, then carry on. This is
    # the deploy drill: a server fix is not finished when it is committed, it
    # is finished when the RUNNING process reports its hash.
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$board = 'http://127.0.0.1:7666'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path

# The service resolves roles/ and spawn_prompts/ relative to its working
# directory, and board.jsonl lives beside the exe - so it must run from here.
Set-Location $here

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
            & odin build message_board -out:message_board/message_board.exe "-define:BUILD_HASH=$hash" "-define:BUILD_TIME=$time"
        }
    } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "odin build failed with exit code $LASTEXITCODE" }
}

function Test-Board {
    try { $null = Invoke-RestMethod -Uri "$board/agents" -TimeoutSec 2; return $true }
    catch { return $false }
}

# Names of agents herdr currently has a pane for. The board's own "active" flag
# is a CHATTINESS measure - it goes false after 20 minutes of silence - and a
# standing agent waiting for work is silent by design. Pane liveness is the
# honest answer to "is this agent already running?".
function Get-LivePaneNames {
    try {
        $snap = @(Invoke-RestMethod -Uri "$board/herdr" -TimeoutSec 5)
        return @($snap | Where-Object { $_.name } | ForEach-Object { $_.name })
    } catch { return @() }
}

# ── 1. Board service ────────────────────────────────────────────────────
# Everything downstream depends on this: an agent that cannot reach the
# board fails its check-in and comes up unaware of the rest of the fleet.
$exe = Join-Path $here 'message_board.exe'

if ($Rebuild) {
    # Announce BEFORE stopping it. The board is how the fleet coordinates, so
    # taking it away unannounced is the one outage nobody can be told about
    # afterwards.
    if (Test-Board) {
        $note = @{ agent = 'run.ps1'; kind = 'status'
                   text  = 'rebuilding and restarting the board - hold writes for a minute' } | ConvertTo-Json -Compress
        try { $null = Invoke-RestMethod -Uri "$board/post" -Method Post -Body $note -TimeoutSec 5 } catch { }
        Start-Sleep -Seconds 5
        Write-Host "[board] stopping for rebuild"
        Get-Process message_board -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 1200
    }
    Build-Board
}

if (Test-Board) {
    Write-Host "[board] already up"
} else {
    if (-not (Test-Path $exe)) {
        Write-Host "[board] no binary yet - building"
        Build-Board
    }
    Write-Host "[board] starting..."
    Start-Process -WindowStyle Hidden -FilePath $exe -WorkingDirectory $here

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
        Write-Host "[board] up (no /build endpoint - binary predates build identity)"
    }
}

# ── 2. herdr sidecar ────────────────────────────────────────────────────
# Feeds live pane state into the roster badges and warns about spawns that
# never check in. Optional: the fleet works without it, just blinder.
$sidecarRunning = $false
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue)) {
    if ($p.CommandLine -and $p.CommandLine -match 'herdr_sync\.py') { $sidecarRunning = $true; break }
}
if ($sidecarRunning) {
    Write-Host "[sidecar] already running"
} elseif (Test-Path (Join-Path $here 'herdr_sync.py')) {
    Write-Host "[sidecar] starting herdr_sync.py"
    Start-Process -WindowStyle Hidden -FilePath 'python' -ArgumentList 'herdr_sync.py' -WorkingDirectory $here
} else {
    Write-Warning "[sidecar] herdr_sync.py not found - skipping (roster badges will be blank)"
}

if ($ServiceOnly) {
    Write-Host "[done] service only, fleet not spawned"
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
    foreach ($i in 1..8) {
        Start-Sleep -Seconds 3
        if ((Get-LivePaneNames).Count -gt 0) { break }
    }
}

foreach ($a in $fleet) {
    $body = @{ name = $a.topic; model = $a.model; role = $a.role; prompt = $a.task } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "$board/spawn" -Method Post -Body $body -TimeoutSec 30
        if ($r.reused) {
            Write-Host "[$($a.topic)] already up as $($r.agent) (by $($r.signal))"
        } else {
            Write-Host "[$($a.topic)] spawned as $($r.agent) (model $($a.model), role $($a.role))"
            Start-Sleep -Seconds 2   # let herdr finish one pane before the next
        }
    } catch {
        Write-Warning "[$($a.topic)] spawn failed: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "[done] board $board - open it to watch them check in."
