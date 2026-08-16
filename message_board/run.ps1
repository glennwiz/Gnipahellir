<#
    Reboot bootstrap for Glenn's four standing agents (board seq 368).

    Brings the whole fleet up in one command after a machine restart:
    the board service, the herdr sidecar, then Fable / Opus / Sonnet /
    Haiku, each in its own herdr pane carrying its role as an APPENDED
    system prompt (roles/*.md) so it knows its responsibility for the
    whole session, not just its first turn.

    Run it from anywhere:  pwsh -File message_board\run.ps1
    Windows PowerShell 5 and pwsh 7 both work.

    Safe to run twice: an agent whose topic is already active on the
    board is skipped rather than duplicated.

    The codex coordinator is NOT spawned here - Glenn drives that one.
#>
[CmdletBinding()]
param(
    # Skip the fleet and only bring the service + sidecar up.
    [switch]$ServiceOnly
)

$ErrorActionPreference = 'Stop'
$board = 'http://127.0.0.1:7666'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path

# The service resolves roles/ and spawn_prompts/ relative to its working
# directory, and board.jsonl lives beside the exe - so it must run from here.
Set-Location $here

function Test-Board {
    try { $null = Invoke-RestMethod -Uri "$board/agents" -TimeoutSec 2; return $true }
    catch { return $false }
}

function Get-BoardAgents {
    try { return @(Invoke-RestMethod -Uri "$board/agents" -TimeoutSec 5) }
    catch { return @() }
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
if (Test-Board) {
    Write-Host "[board] already up"
} else {
    $exe = Join-Path $here 'message_board.exe'
    if (-not (Test-Path $exe)) {
        throw "message_board.exe missing - build it first: odin build message_board -out:message_board/message_board.exe"
    }
    Write-Host "[board] starting..."
    Start-Process -WindowStyle Hidden -FilePath $exe -WorkingDirectory $here

    $up = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 500
        if (Test-Board) { $up = $true; break }
    }
    if (-not $up) { throw "board did not answer on $board within 10s - start it by hand and check its window" }
    Write-Host "[board] up"
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

# Bind the roster to a variable BEFORE filtering. Piping a function's returned
# array straight into Where-Object does not reliably unroll it, and an
# un-unrolled array makes `$_.agent -like ...` filter the array instead of
# testing one agent - which is truthy, so every topic would look "already
# active" and the whole fleet would silently never spawn.
$agents = Get-BoardAgents
$active = @($agents | Where-Object { $_.active })

# The pane snapshot is what the guard leans on, so give a just-started sidecar
# its first tick - without it every standing agent looks absent and the fleet
# doubles.
$panes = Get-LivePaneNames
if ($panes.Count -eq 0) {
    foreach ($i in 1..8) {
        Start-Sleep -Seconds 3
        $panes = Get-LivePaneNames
        if ($panes.Count -gt 0) { break }
    }
}
if ($panes.Count -eq 0) {
    Write-Warning "no herdr pane snapshot - falling back to board activity alone, which can duplicate a quiet agent"
}

foreach ($a in $fleet) {
    # Idempotence: names carry a random suffix, so a second run would
    # otherwise fork a duplicate fleet rather than collide visibly. Check BOTH
    # signals: a live pane (running, however quiet) and board activity (spoke
    # recently, pane snapshot maybe stale).
    $existing = @($active | Where-Object { $_.agent -like "claude-$($a.topic)-*" })
    $running  = @($panes  | Where-Object { $_ -like "claude-$($a.topic)-*" })
    if ($running.Count -gt 0) {
        Write-Warning "[$($a.topic)] pane already running as $($running[0]) - skipping"
        continue
    }
    if ($existing.Count -gt 0) {
        Write-Warning "[$($a.topic)] already active as $($existing[0].agent) - skipping"
        continue
    }
    $body = @{ name = $a.topic; model = $a.model; role = $a.role; prompt = $a.task } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "$board/spawn" -Method Post -Body $body -TimeoutSec 30
        Write-Host "[$($a.topic)] spawned as $($r.agent) (model $($a.model), role $($a.role))"
    } catch {
        Write-Warning "[$($a.topic)] spawn failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2   # let herdr finish one pane before the next
}

Write-Host ""
Write-Host "[done] board $board - open it to watch them check in."
