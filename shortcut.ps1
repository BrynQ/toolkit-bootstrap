<#
    BrynQ AI Toolkit - Desktop shortcut generator.

    Puts a "BrynQ Agents" shortcut on your Windows desktop that starts the
    orchestrator dashboard inside a persistent tmux session in WSL and attaches
    to it. Closing the window leaves the dashboard running; clicking again
    re-attaches to the same session instead of starting a second one.

    Run in a NORMAL PowerShell - no administrator rights needed:
        irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/shortcut.ps1 | iex

    Requires the toolkit to be installed in WSL already (see bootstrap.sh).
    Re-running is safe: it overwrites the same shortcut.

    Contains no secrets; access to the private toolkit is gated by your GitHub login.
#>

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "  -> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "  !  $msg" -ForegroundColor Yellow }

Write-Host "BrynQ AI Toolkit - desktop shortcut" -ForegroundColor Green

# ── 1. The command the shortcut runs ────────────────────────────────────────
# `tmux new-session -A` is attach-or-create in one call: it attaches when the
# session exists and creates it otherwise, which is what makes repeat clicks
# re-attach rather than start a second dashboard. The `|| exec bash -l` keeps
# the pane open if the dashboard exits (most likely: port 8420 already taken by
# a hand-started instance or the watchdog) so the error stays readable instead
# of the window vanishing.
#
# Deliberately free of semicolons: wt.exe treats `;` as its own argument
# separator, so a `;` here would need escaping as `\;` and only in the wt
# branch. Keeping the payload semicolon-free means both branches below can pass
# the identical string through untouched.
$inner   = "tmux new-session -A -s agents 'brynq-orchestrate-web || exec bash -l'"
$wslArgs = "-- bash -lc `"$inner`""

# `wsl` with no `-d` uses the caller's default distro, so the distro name never
# has to be guessed or passed in (a `param()` block would be unreachable through
# `irm | iex` anyway).

# ── 2. Refuse to create a shortcut that would fail on click ─────────────────
Write-Step "Checking the toolkit is installed in WSL ..."
# `throw`, not `Write-Error` + `exit`: this script is normally run as
# `irm ... | iex`, which evaluates in the caller's session, so a bare `exit`
# would close the user's PowerShell window instead of just aborting.
try {
    # Probe exactly what the shortcut invokes. A login shell is required: the
    # toolkit puts ~/.local/bin on PATH from .profile, which a non-login
    # `bash -c` never reads.
    $probe = & wsl.exe -- bash -lc "command -v brynq-orchestrate-web && command -v tmux" 2>$null
} catch {
    throw "Could not run wsl.exe. Install WSL first - see https://github.com/BrynQ/toolkit-bootstrap"
}
if ($LASTEXITCODE -ne 0 -or -not $probe) {
    throw @"
The toolkit is not installed in your default WSL distro (brynq-orchestrate-web
and/or tmux not found on PATH). Install it first, in a WSL shell:

    curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash
"@
}

# ── 3. Icon ─────────────────────────────────────────────────────────────────
# A .lnk can only point at a local icon file, so the dashboard's own favicon
# (the blue hub-and-spoke node graph) is fetched to a stable path. Best-effort:
# a failure here leaves the shortcut with the terminal's default icon rather
# than aborting an otherwise-working install.
#
# $env:BRYNQ_SHORTCUT_ICON_URL overrides the source. An env var rather than a
# `param()` because parameters are unreachable through `irm | iex` — this is how
# you test the script from a branch, whose assets/ is not on main yet.
$iconDir  = Join-Path $env:LOCALAPPDATA "BrynQ"
$iconPath = Join-Path $iconDir "agents.ico"
$iconUrl  = if ($env:BRYNQ_SHORTCUT_ICON_URL) { $env:BRYNQ_SHORTCUT_ICON_URL } `
            else { "https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/assets/agents.ico" }
$icon     = $null
try {
    Write-Step "Fetching icon ..."
    New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $iconUrl -OutFile $iconPath
    $icon = "$iconPath,0"
} catch {
    Write-Warn "Could not fetch the icon - the shortcut will use the terminal's default."
}

# ── 4. Target: Windows Terminal when present, plain wsl.exe otherwise ───────
# Same probe order the toolkit itself uses to pick a GUI terminal under WSL
# (agents/orchestrator/web/services/poller.py `_detect_viewer`). wt.exe is a
# per-user WindowsApps alias so it can legitimately be missing; wsl.exe is in
# System32 and always is not.
$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue)
if ($wt) {
    $target    = $wt.Source
    $arguments = "--title agents -- wsl $wslArgs"
    Write-Step "Using Windows Terminal ($($wt.Source))"
} else {
    $target    = Join-Path $env:SystemRoot "System32\wsl.exe"
    $arguments = $wslArgs
    Write-Warn "wt.exe not found - falling back to wsl.exe (plain console window)."
}

# ── 5. Write the shortcut ───────────────────────────────────────────────────
# GetFolderPath rather than "$env:USERPROFILE\Desktop": a OneDrive-redirected
# Desktop is common and the literal path silently puts the shortcut somewhere
# the user never looks.
$desktop  = [Environment]::GetFolderPath("Desktop")
$lnkPath  = Join-Path $desktop "BrynQ Agents.lnk"

Write-Step "Writing $lnkPath ..."
$shell = New-Object -ComObject WScript.Shell
$lnk   = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath       = $target
$lnk.Arguments        = $arguments
$lnk.Description      = "Start / attach the BrynQ orchestrator dashboard (WSL, tmux session 'agents')"
$lnk.WorkingDirectory = $env:USERPROFILE
if ($icon) { $lnk.IconLocation = $icon }
$lnk.Save()

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Double-click 'BrynQ Agents' on your desktop." -ForegroundColor Yellow
Write-Host "  First click starts the dashboard on http://127.0.0.1:8420 and attaches;" -ForegroundColor Yellow
Write-Host "  closing the window leaves it running; clicking again re-attaches." -ForegroundColor Yellow
Write-Host "  Detach without stopping it: Ctrl-b then d" -ForegroundColor Yellow
