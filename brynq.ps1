# BrynQ Toolkit - one-command install for Windows (via WSL).
#
#   irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/brynq.ps1 | iex
#
# Runs as a normal (non-admin) user in Windows PowerShell 5.1 or PowerShell 7.
# Installs what is missing and opens the BrynQ Toolkit app: WSL (one admin
# prompt and one restart that resumes by itself), one named distro (never the
# default one), the toolkit inside it, the Windows git credential bridge, the
# app. Afterwards you only click the BrynQ Toolkit icon.
#
# -Dev      You develop the toolkit itself (bootstrap.sh --dev).
# -NoSdk    Skip the SDK feed sign-in ("I'm a PM"; bootstrap.sh --no-sdk).
# `irm | iex` cannot pass switches: set $env:BRYNQ_DEV = '1' or
# $env:BRYNQ_NO_SDK = '1' first.
#
# Test and E2E settings (environment):
#   BRYNQ_BOOTSTRAP_DRYRUN=1          print the probe and the plan, change nothing
#   BRYNQ_BOOTSTRAP_NONINTERACTIVE=1  never ask; a needed answer ends with exit 20
#   BRYNQ_AUTO_RESTART=1              restart without asking (the E2E reboot loop)
#   BRYNQ_BOOTSTRAP_BASE_URL          where brynq.ps1 (the copy that resumes
#                                     after the restart) and bootstrap.sh
#                                     (phase B) come from (default the public
#                                     toolkit-bootstrap repo; file:///C:/brynq-test
#                                     for E2E, read as /mnt/c/... in the distro)
#   BRYNQ_DISTRO                      the distro to use (a name, or `new`)
#   BRYNQ_LINUX_USER                  the Linux user name for a new distro
#   BRYNQ_TOOLKIT_REPO_URL            passed to bootstrap.sh (git bundle, E2E);
#                                     also windows-bridge --no-github (the
#                                     bridge skips its GitHub checks)
#   BRYNQ_RETIRE_SHORTCUT=yes|no      remove the old shortcut.ps1 leftovers
#
# Uninstall: $env:BRYNQ_ACTION = 'uninstall' before the same one-liner. It
# lists what it removes and asks first (nothing goes without a yes): the app
# (its own uninstaller), Windows git's GitHub sign-in through WSL and the logon
# anchor (bd toolkit windows-bridge --remove in the distro), the old
# shortcut.ps1 files, %LOCALAPPDATA%\BrynQ and a leftover resume file. It asks
# separately before %APPDATA%\brynq-toolkit-desktop (the app's sign-ins) and
# offers `wsl --unregister` only for the distro this script created, after you
# type its name. WSL and Virtual Machine Platform stay on. Test-mode answers:
# BRYNQ_UNINSTALL=yes, BRYNQ_REMOVE_APP_DATA=yes|no,
# BRYNQ_UNREGISTER_DISTRO=<the distro name>|no (a missing one: exit 20 before
# anything is removed). Exit 1: a removal step failed (named; the rest ran).
# Run through iex, the script never calls `exit` (that would close the
# window): the result code is left in $LASTEXITCODE (exit codes: BOOT D10).
#
# Phase A (Windows): language-mode check, Windows probe, one admin prompt that
# turns on WSL, the restart and its resume. Then the distro step (listing, a
# read-only probe per distro, the choice, create + first user) and phase B
# inside the distro: the GitHub sign-in when the probe found none
# (bootstrap.sh --sign-in: the toolkit's Claude plugin comes from a private
# GitHub repository), bootstrap.sh --no-wizard, bd toolkit windows-bridge,
# the old shortcut.ps1 files (asks), the logon anchor (bd toolkit
# windows-bridge --anchor: a Startup link that keeps the distro running), bd
# toolkit desktop install / open.
# Get-BrynqPlan turns a probe into the list of actions; every external
# program goes through Invoke-Native and every other outside effect through a
# small Brynq function, so the tests can mock them. Every wsl.exe call into a
# distro passes -d (Invoke-BrynqWsl; bootstrap/tests/check_wsl_d.py).
# Decisions (backlog program, batch X): published by default; any toolkit distro is reused and updated in
# place, there is no "outdated" class).
#
# Registry: reads only (install state, pending restart). Never a write: the
# resume after the restart is a file in the Startup folder, not RunOnce.
#
# Must stay Windows PowerShell 5.1 compatible (no ?., ??, ternary, &&/||;
# Join-Path takes two arguments) and ASCII (5.1 reads a BOM-less file as ANSI):
# bootstrap/tests/pssa-ps51.psd1 and Analyzer.Tests.ps1 check it.
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$NoSdk
)

# The distro the install creates when there is nothing to reuse.
$script:BrynqNewDistro = 'BrynQ'

# Reusing an empty distro is only offered for these (install_prereqs.sh is apt-based).
$script:BrynqReusableOs = @('ubuntu', 'debian')

# Every action Get-BrynqPlan can return. `fail` ends a plan that cannot go on:
# a plan that contains it contains nothing else, so it changes nothing.
$script:BrynqActions = @(
    'enable-wsl', 'reboot', 'create-distro', 'create-user', 'choose-distro',
    'github-sign-in', 'run-bootstrap', 'bridge', 'retire-shortcut', 'anchor', 'desktop-install',
    'desktop-open', 'fail'
)

# One Windows command line from separate arguments (the quoting rules of the
# Microsoft C runtime, which wsl.exe and the other programs here parse with).
# Used where a program is started through .NET (Invoke-Native -Console or
# -TimeoutSeconds): .NET Framework takes a single argument string.
function Join-BrynqArgument {
    [OutputType([string])]
    param([string[]]$ArgumentList = @())
    $parts = foreach ($a in $ArgumentList) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') { [void]$sb.Append('\' * (2 * $slashes + 1)) }
            else { [void]$sb.Append('\' * $slashes) }
            [void]$sb.Append($ch)
            $slashes = 0
        }
        [void]$sb.Append('\' * (2 * $slashes))
        [void]$sb.Append('"')
        $sb.ToString()
    }
    @($parts) -join ' '
}

# Run an external program and return its exit code and output lines (stderr
# included). The single place where brynq.ps1 starts a program: tests mock it.
# Windows PowerShell 5.1 mangles embedded quotes in native arguments, so callers
# pass plain arguments only (the distro probe goes in base64, BOOT D3). A
# program that does not exist (no wsl.exe on an old Windows 10) gives exit code
# 9009, like cmd.exe, instead of an error.
#   -Console         the program uses this console (password, sudo and device
#                    code prompts, progress): nothing is captured, Output is empty
#   -TimeoutSeconds  captured, but stopped after that long: exit code 124
function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Console,
        [int]$TimeoutSeconds = 0
    )
    $command = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return [pscustomobject]@{ ExitCode = 9009; Output = @("$FilePath was not found.") }
    }
    if (-not $Console -and $TimeoutSeconds -le 0) {
        $lines = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($lines)
        }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $command.Path
    $info.Arguments = Join-BrynqArgument $ArgumentList
    $info.UseShellExecute = $false
    if ($Console) {
        $p = [Diagnostics.Process]::Start($info)
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = @() }
    }
    $utf8 = New-Object Text.UTF8Encoding $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $p = [Diagnostics.Process]::Start($info)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { Write-Verbose "could not stop $FilePath`: $_" }
        return [pscustomobject]@{ ExitCode = 124; Output = @("$FilePath did not finish within $TimeoutSeconds s.") }
    }
    $p.WaitForExit()
    $text = $stdout.Result + $stderr.Result
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Output   = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    }
}

# A wsl.exe call into one named distro: always `-d <distro>`, never the
# default one (X D4). bootstrap/tests/check_wsl_d.py checks that every other
# wsl.exe call is --list, --status, --version, --install, --terminate <name>
# or --unregister <name>.
function Invoke-BrynqWsl {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [string[]]$ArgumentList = @(),
        [switch]$Console,
        [int]$TimeoutSeconds = 0
    )
    Invoke-Native -FilePath 'wsl.exe' -ArgumentList (@('-d', $Distro) + $ArgumentList) -Console:$Console -TimeoutSeconds $TimeoutSeconds
}

# The environment variables Get-BrynqOption reads.
$script:BrynqOptionVariables = @(
    'BRYNQ_DEV', 'BRYNQ_NO_SDK', 'BRYNQ_BOOTSTRAP_NONINTERACTIVE', 'BRYNQ_DISTRO', 'BRYNQ_LINUX_USER',
    'BRYNQ_RETIRE_SHORTCUT'
)

# The install options from the switches and the environment (`irm | iex` cannot
# pass switches, so BRYNQ_DEV=1 / BRYNQ_NO_SDK=1 do the same). Non-interactive
# test mode never asks: a question without an answer ends the plan with exit 20.
function Get-BrynqOption {
    [CmdletBinding()]
    param(
        [switch]$Dev,
        [switch]$NoSdk,
        [hashtable]$Environment
    )
    if ($null -eq $Environment) {
        $Environment = @{}
        foreach ($name in $script:BrynqOptionVariables) {
            $Environment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
    }
    $distro = $Environment['BRYNQ_DISTRO']
    $linuxUser = $Environment['BRYNQ_LINUX_USER']
    $retire = "$($Environment['BRYNQ_RETIRE_SHORTCUT'])".Trim().ToLowerInvariant()
    [pscustomobject]@{
        dev            = [bool]($Dev -or $Environment['BRYNQ_DEV'] -eq '1')
        no_sdk         = [bool]($NoSdk -or $Environment['BRYNQ_NO_SDK'] -eq '1')
        noninteractive = [bool]($Environment['BRYNQ_BOOTSTRAP_NONINTERACTIVE'] -eq '1')
        distro         = $(if ($distro) { $distro } else { $null })
        linux_user     = $(if ($linuxUser) { $linuxUser } else { $null })
        # yes / no, or $null (asked; exit 20 in test mode)
        retire_shortcut = $(if ($retire -eq 'yes' -or $retire -eq 'no') { $retire } else { $null })
    }
}

# A boot time (ISO 8601 text, or the DateTime PowerShell 7's ConvertFrom-Json
# makes of it) as UTC, or $null.
function ConvertTo-BrynqUtc {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# Same boot: equal boot times. WMI's LastBootUpTime can move by a second when
# the clock syncs, so up to 60 s apart counts as equal; a restart moves it by
# at least the time Windows ran before it.
function Test-BrynqSameBoot {
    [OutputType([bool])]
    param($Recorded, $Current)
    $a = ConvertTo-BrynqUtc $Recorded
    $b = ConvertTo-BrynqUtc $Current
    if ($null -eq $a -or $null -eq $b) { return "$Recorded" -eq "$Current" }
    return [math]::Abs(($a - $b).TotalSeconds) -le 60
}

# Why a restart is still pending, or $null. Three signals, first match wins
# (BOOT D2.4): our own state file says a restart is needed and Windows has not
# booted since; Windows servicing has a reboot pending (may be Windows Update);
# `wsl.exe --status` says Virtual Machine Platform is not active yet.
function Get-BrynqRebootReason {
    [CmdletBinding()]
    [OutputType([string])]
    param($Windows, $State)
    if ($null -ne $State -and $State.reboot_required -and (Test-BrynqSameBoot $State.boot_time $Windows.boot_time)) {
        return 'bootstrap'
    }
    if ($Windows.cbs_reboot_pending) { return 'windows' }
    if ($Windows.wsl_vmp_error) { return 'vmp' }
    return $null
}

# The oldest bd that has every bd command this script runs (bd toolkit
# windows-bridge, --anchor, --no-github: release 2.1.25). An older bd makes a
# distro partial, so run-bootstrap updates it before the bridge step.
$script:BrynqMinBdVersion = '2.1.25'

# True when the probed bd version is at least $script:BrynqMinBdVersion.
# Compared on its leading major.minor.patch, so a local or dev suffix
# (2.1.25+dev, 2.1.25.dev0) counts as that release. Missing or unparsable:
# false (it cannot be shown to be current).
function Test-BrynqBdCurrent {
    [OutputType([bool])]
    param($Version)
    $m = [regex]::Match("$Version", '^(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $m.Success) { return $false }
    $v = New-Object Version ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value)
    return $v -ge [version]$script:BrynqMinBdVersion
}

# Class of one listed distro from its read-only probe (BOOT D3 minus `outdated`):
#   unusable  WSL 1, the probe failed (no schema-1 JSON) or no apt-get
#   no-user   only root (the first-run user was never created)
#   ready     toolkit mode, bd (at least $script:BrynqMinBdVersion), the
#             plugin, gh signed in, claude, interop
#   partial   toolkit traces but not ready (an interrupted run, an older bd):
#             reused, repaired
#   empty     a user, no toolkit
function Get-BrynqDistroClass {
    [CmdletBinding()]
    [OutputType([string])]
    param($Distro)
    $p = $Distro.probe
    if ("$($Distro.version)" -ne '2' -or $null -eq $p -or "$($p.schema)" -ne '1' -or -not $p.apt) {
        return 'unusable'
    }
    if ("$($p.uid)" -eq '0') { return 'no-user' }
    $traces = [bool]($p.mode -or $p.bd -or $p.plugin)
    if ($p.mode -and $p.bd -and $p.plugin -and $p.gh_auth.ok -and $p.tools.claude -and $p.interop -and (Test-BrynqBdCurrent $p.bd.version)) {
        return 'ready'
    }
    if ($traces) { return 'partial' }
    return 'empty'
}

# Why Get-BrynqDistroClass calls a distro 'unusable' (for the exit 21/30
# message), else $null.
function Get-BrynqUnusableReason {
    [OutputType([string])]
    param($Distro)
    if ("$($Distro.version)" -ne '2') { return 'it is WSL 1' }
    if ($Distro.probe_error -eq 'timeout') { return "it did not answer within $script:BrynqProbeTimeoutSeconds s" }
    if ($Distro.probe_error) { return "its probe failed ($($Distro.probe_error))" }
    $p = $Distro.probe
    if ($null -eq $p -and "$($Distro.name)" -notmatch $script:BrynqDistroNamePattern) {
        return 'its name has characters other than letters, digits, . _ and -, so it was not probed'
    }
    if ($null -eq $p) { return 'it was not probed' }
    if ("$($p.schema)" -ne '1') { return "its probe answered schema $($p.schema), not 1" }
    if (-not $p.apt) { return 'it has no apt-get' }
    $null
}

function New-BrynqAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes nothing.')]
    param([string]$Action, [hashtable]$Fields = @{})
    $o = [ordered]@{ action = $Action }
    foreach ($key in 'distro', 'args', 'options', 'reason', 'code', 'env', 'message') {
        if ($Fields.ContainsKey($key)) { $o[$key] = $Fields[$key] }
    }
    [pscustomobject]$o
}

function New-BrynqFail {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes nothing.')]
    param([int]$Code, [string]$Message, [string]$EnvName)
    $fields = @{ code = $Code; message = $Message }
    if ($EnvName) { $fields['env'] = $EnvName }
    New-BrynqAction 'fail' $fields
}

function Find-BrynqDistro {
    param($Distros, [string]$Name)
    foreach ($d in $Distros) {
        if ($d.name -ieq $Name) { return $d }
    }
    return $null
}

# A menu answer (or the menu itself, or the exit 20 that replaces it in test mode).
function Resolve-BrynqMenu {
    param($Probe, $Distros, [string[]]$Options, [string]$Question)
    $answer = $Probe.answers.distro
    if ($answer) {
        if ($answer -eq 'new') { return @{ create = $true } }
        if ($Options -contains $answer) { return @{ distro = (Find-BrynqDistro $Distros $answer) } }
        return @{ fail = (New-BrynqFail -Code 21 -Message "Distro '$answer' is not one of the choices ($($Options -join ', ')).") }
    }
    if ($Probe.options.noninteractive) {
        return @{ fail = (New-BrynqFail -Code 20 -Message "Set BRYNQ_DISTRO to answer: $Question ($($Options -join ', '))" -EnvName 'BRYNQ_DISTRO') }
    }
    return @{ menu = (New-BrynqAction 'choose-distro' @{ options = $Options }) }
}

# Which distro to use (BOOT D3 choosing table with the owner's D11 reuse rule),
# first rule that applies:
#   1 BRYNQ_DISTRO=<name> (or `new`)        4 several toolkit distros: menu once
#   2 the app's wsl.json names one          5 only empty/no-user Ubuntu/Debian:
#   3 exactly one toolkit distro             menu "new BrynQ" or reuse
#     (ready or partial): no question       6 nothing usable: create BrynQ
# Returns @{distro}, @{create}, @{menu} or @{fail}. Never the default distro
# just because it is the default.
function Select-BrynqDistro {
    param($Probe, $Distros)
    $wanted = $Probe.options.distro
    if ($wanted) {
        if ($wanted -eq 'new') { return @{ create = $true } }
        $d = Find-BrynqDistro $Distros $wanted
        if ($null -eq $d) {
            return @{ fail = (New-BrynqFail -Code 21 -Message "Distro '$wanted' does not exist (see wsl -l -v). Set BRYNQ_DISTRO=<name> or BRYNQ_DISTRO=new.") }
        }
        return @{ distro = $d }
    }
    $recorded = $Probe.app.distro
    if ($recorded) {
        $d = Find-BrynqDistro $Distros $recorded
        if ($null -eq $d) {
            return @{ fail = (New-BrynqFail -Code 21 -Message "Distro '$recorded' (the BrynQ app's distro) does not exist (see wsl -l -v). Set BRYNQ_DISTRO=<name> or BRYNQ_DISTRO=new.") }
        }
        return @{ distro = $d }
    }
    $toolkit = @($Distros | Where-Object { $_.class -eq 'ready' -or $_.class -eq 'partial' })
    if ($toolkit.Count -eq 1) { return @{ distro = $toolkit[0] } }
    if ($toolkit.Count -gt 1) {
        $options = @($toolkit | ForEach-Object { $_.name }) + 'new'
        return Resolve-BrynqMenu -Probe $Probe -Distros $Distros -Options $options -Question 'Which distro should BrynQ use?'
    }
    $reusable = @($Distros | Where-Object {
            ($_.class -eq 'empty' -or $_.class -eq 'no-user') -and $script:BrynqReusableOs -contains "$($_.probe.os_id)"
        })
    if ($reusable.Count -gt 0) {
        $options = @('new') + @($reusable | ForEach-Object { $_.name })
        return Resolve-BrynqMenu -Probe $Probe -Distros $Distros -Options $options -Question "Create a new distro '$script:BrynqNewDistro' (recommended) or install into an existing one?"
    }
    return @{ create = $true }
}

# probe -> the ordered actions for this run. Pure: reads only the probe.
#
# Probe (the JSON shape bootstrap/tests/cases/*.json use; Get-BrynqProbe):
#   options  Get-BrynqOption: dev, no_sdk, noninteractive, distro, linux_user
#   windows  wsl_installed, vmp_enabled, boot_time, cbs_reboot_pending,
#            wsl_vmp_error, anchor_links (distros with a logon anchor),
#            old_shortcut, old_keepalive (shortcut.ps1 leftovers; removed only
#            on a yes: options.retire_shortcut, else asked; exit 20 in test mode)
#   state    %LOCALAPPDATA%\BrynQ\bootstrap-state.json or $null
#   app      installed, distro (from the app's wsl.json)
#   distros  [{name, state, version, default, probe, probe_error}] (probe =
#            BOOT D3 contract; probe_error: why there is none, see Get-BrynqDistroProbe)
#   answers  distro: the menu answer given in this run, if any
#
# Phase A (WSL itself) comes first and ends the plan at the restart; the next
# run (resume or the same one-liner) plans again from a new probe. A plan that
# needs a menu answer ends at choose-distro; the caller asks, sets
# answers.distro and plans again. Ready distros are not re-bootstrapped (no
# sudo prompt, no change): the app's self-update at start keeps them current.
function Get-BrynqPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Probe)

    $reason = Get-BrynqRebootReason $Probe.windows $Probe.state
    if ($reason) {
        return New-BrynqAction 'reboot' @{ reason = $reason }
    }
    if (-not $Probe.windows.wsl_installed -or -not $Probe.windows.vmp_enabled) {
        New-BrynqAction 'enable-wsl'
        New-BrynqAction 'reboot' @{ reason = 'enable-wsl' }
        return
    }

    $distros = @($Probe.distros | Where-Object { $null -ne $_ } | ForEach-Object {
            [pscustomobject]@{ name = $_.name; class = (Get-BrynqDistroClass $_); probe = $_.probe; why = (Get-BrynqUnusableReason $_) }
        })
    $choice = Select-BrynqDistro $Probe $distros
    if ($choice.fail) { return $choice.fail }
    if ($choice.menu) { return $choice.menu }

    $create = [bool]$choice.create
    if ($create) {
        $name = $script:BrynqNewDistro
        if ($null -ne (Find-BrynqDistro $distros $name)) {
            return New-BrynqFail -Code 30 -Message "A distro named '$name' already exists but cannot be used: $((Find-BrynqDistro $distros $name).why). Remove or rename it, or set BRYNQ_DISTRO=<name>."
        }
        $class = 'new'
    }
    else {
        $name = $choice.distro.name
        $class = $choice.distro.class
        if ($class -eq 'unusable') {
            return New-BrynqFail -Code 21 -Message "Distro '$name' cannot be used: $($choice.distro.why). Set BRYNQ_DISTRO=<name> or BRYNQ_DISTRO=new."
        }
        if (-not $choice.distro.probe.interop) {
            # With bd the bridge's check names the cause; without bd (no toolkit yet,
            # K3f rerun S10) this is the fix itself: /etc/wsl.conf is what turns it off.
            if ($null -ne $choice.distro.probe.bd) {
                return New-BrynqFail -Code 41 -Message "Windows interop is off in '$name'. Run: wsl -d $name bd toolkit windows-bridge --check (it prints the fix), then run this again."
            }
            return New-BrynqFail -Code 41 -Message "Windows interop is off in '$name'. Turn it on: in /etc/wsl.conf set [interop] enabled=true (wsl -d $name -u root -- nano /etc/wsl.conf), then run: wsl --terminate $name. Then run this again."
        }
    }

    $needsUser = $create -or $class -eq 'no-user'
    if ($needsUser -and $Probe.options.noninteractive -and -not $Probe.options.linux_user) {
        return New-BrynqFail -Code 20 -Message "Set BRYNQ_LINUX_USER to answer: Linux user name for '$name'?" -EnvName 'BRYNQ_LINUX_USER'
    }
    # shortcut.ps1 leftovers (BOOT B7): removed only on a yes, asked when the step runs.
    $retire = ($Probe.windows.old_shortcut -or $Probe.windows.old_keepalive) -and $Probe.options.retire_shortcut -ne 'no'
    if ($retire -and $Probe.options.noninteractive -and $Probe.options.retire_shortcut -ne 'yes') {
        return New-BrynqFail -Code 20 -Message 'Set BRYNQ_RETIRE_SHORTCUT to answer: Remove the old BrynQ Agents shortcut and its keep-alive (yes or no)?' -EnvName 'BRYNQ_RETIRE_SHORTCUT'
    }
    $wantsDevSwitch = $Probe.options.dev -and "$($choice.distro.probe.mode.mode)" -ne 'local'
    $bootstrap = $class -ne 'ready' -or $wantsDevSwitch
    # A new distro or a new user has no gh login yet.
    $signIn = $bootstrap -and ($needsUser -or -not $choice.distro.probe.gh_auth.ok)

    $bootstrapArgs = @('--no-wizard')
    if ($Probe.options.dev) { $bootstrapArgs += '--dev' }
    if ($Probe.options.no_sdk) { $bootstrapArgs += '--no-sdk' }

    if ($create) { New-BrynqAction 'create-distro' @{ distro = $name } }
    if ($needsUser) { New-BrynqAction 'create-user' @{ distro = $name } }
    if ($signIn) { New-BrynqAction 'github-sign-in' @{ distro = $name } }
    if ($bootstrap) {
        $fields = @{ distro = $name; args = $bootstrapArgs }
        $bd = $choice.distro.probe.bd
        if (-not $create -and $null -ne $bd -and -not (Test-BrynqBdCurrent $bd.version)) {
            $from = "$($bd.version)"
            if (-not $from) { $from = 'of unknown version' }
            $fields['message'] = "updating bd $from to $script:BrynqMinBdVersion or newer"
            # bootstrap.sh then updates a stale local-mode checkout when it is clean,
            # or stops with exit 20 naming its local work (K3f rerun R2).
            $fields['args'] = @($bootstrapArgs) + "--min-bd=$script:BrynqMinBdVersion"
        }
        New-BrynqAction 'run-bootstrap' $fields
    }
    New-BrynqAction 'bridge' @{ distro = $name }
    if ($retire) { New-BrynqAction 'retire-shortcut' }
    if (@($Probe.windows.anchor_links) -notcontains $name) {
        New-BrynqAction 'anchor' @{ distro = $name }
    }
    if (-not $Probe.app.installed) { New-BrynqAction 'desktop-install' @{ distro = $name } }
    New-BrynqAction 'desktop-open' @{ distro = $name }
}


# ---------------------------------------------------------------------------
# Phase A (Windows): probe, the admin step that turns on WSL, the restart and
# its resume (BOOT D2). Everything below that touches the machine goes through
# a small function the tests mock.
# ---------------------------------------------------------------------------

# The default base URL brynq.ps1 is fetched from (same as bootstrap/brynq.sh).
$script:BrynqBaseUrl = 'https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main'

# The installed BrynQ Toolkit app (per-user NSIS) leaves this uninstall entry.
$script:BrynqAppName = 'BrynQ Toolkit'

# Windows servicing's pending-restart key (read only; CSS-Exchange documents it).
$script:BrynqCbsRebootKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'

function Write-BrynqLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console installer: progress and questions are for the person at the console, never pipeline output.')]
    param([string]$Text = '')
    Write-Host $Text
}

# The question at the console (mocked by the tests).
function Read-BrynqAnswer {
    param([string]$Prompt)
    Read-Host $Prompt
}

function Get-BrynqLanguageMode {
    "$($ExecutionContext.SessionState.LanguageMode)"
}

function Get-BrynqEnv {
    param([string]$Name)
    [Environment]::GetEnvironmentVariable($Name)
}

# Where phase A reads and writes on Windows. Folder paths come from Windows
# (OneDrive-redirected or non-ASCII profiles included), never built by hand.
function Get-BrynqPath {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    $startup = [Environment]::GetFolderPath('Startup')
    $dir = Join-Path $local 'BrynQ'
    [pscustomobject]@{
        dir      = $dir
        state    = Join-Path $dir 'bootstrap-state.json'
        self     = Join-Path $dir 'brynq.ps1'
        result   = Join-Path $dir 'enable-wsl-result.json'
        startup  = $startup
        resume   = Join-Path $startup 'BrynQ-resume.cmd'
        desktop  = [Environment]::GetFolderPath('Desktop')
        programs = [Environment]::GetFolderPath('Programs')
        app_wsl  = Join-Path (Join-Path $roaming 'brynq-toolkit-desktop') 'wsl.json'
        app_data = Join-Path $roaming 'brynq-toolkit-desktop'
    }
}

# --- small seams for the outside world (mocked by the tests) ----------------

function Get-BrynqCimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($Filter) { return Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction SilentlyContinue }
    Get-CimInstance -ClassName $ClassName -ErrorAction SilentlyContinue
}

function Test-BrynqRegistryKey {
    [OutputType([bool])]
    param([string]$Path)
    [bool](Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
}

# The app's uninstall entry (HKCU, read only), or $null.
function Get-BrynqAppEntry {
    $entries = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
    @($entries | Where-Object { "$($_.DisplayName)" -like "$script:BrynqAppName*" }) | Select-Object -First 1
}

# The app's uninstaller and folder from its uninstall entry. electron-builder's
# per-user NSIS install leaves InstallLocation empty (0.1.0 and 0.1.3 on a real
# laptop, K S09-A A5.2); UninstallString names the uninstaller:
# "<folder>\Uninstall BrynQ Toolkit.exe" /currentuser. String operations, not
# Split-Path, so the Windows path also parses under pwsh on macOS (Pester).
function Get-BrynqAppUninstaller {
    [OutputType([string])]
    param($Entry)
    $cmd = "$($Entry.UninstallString)".Trim()
    if ($cmd -match '^"([^"]+)"') { return $Matches[1] }
    if ($cmd -match '^(.+?\.exe)\b') { return $Matches[1] }
    $location = "$($Entry.InstallLocation)".Trim().TrimEnd('\')
    if ($location) { return $location + '\Uninstall BrynQ Toolkit.exe' }
    ''
}

function Get-BrynqAppFolder {
    [OutputType([string])]
    param($Entry)
    $location = "$($Entry.InstallLocation)".Trim().TrimEnd('\')
    if ($location) { return $location }
    $exe = Get-BrynqAppUninstaller $Entry
    $cut = $exe.LastIndexOf('\')
    if ($cut -gt 0) { return $exe.Substring(0, $cut) }
    ''
}

function Read-BrynqText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    [IO.File]::ReadAllText($Path)
}

# Write text as UTF-8 without a BOM (ASCII for everything we write), creating
# the folder. The single place phase A writes a file.
function Write-BrynqFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Remove-BrynqFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Installer step; BRYNQ_BOOTSTRAP_DRYRUN is the no-change mode.')]
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Delete($Path) }
}

function Remove-BrynqDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Uninstall step, only after a yes; BRYNQ_BOOTSTRAP_DRYRUN is the no-change mode.')]
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

# Run the app's own uninstaller silently and wait. Its path comes from the
# uninstall entry, so it cannot go through Invoke-Native (a literal program
# name only: bootstrap/tests/check_wsl_d.py); its own seam. Returns the exit code.
function Invoke-BrynqUninstaller {
    [OutputType([int])]
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 9009 }
    $p = Start-Process -FilePath $Path -ArgumentList '/S' -Wait -PassThru
    $p.ExitCode
}

# The text at a URL (http(s) or file://, for E2E). irm adds no Mark-of-the-Web.
function Get-BrynqRemoteText {
    param([string]$Url)
    $uri = [Uri]$Url
    if ($uri.IsFile) { return [IO.File]::ReadAllText($uri.LocalPath) }
    Invoke-RestMethod -Uri $Url -UseBasicParsing
}

# Start PowerShell elevated (the one UAC prompt) and wait for it. Throws when
# the prompt is declined. Start-Process -Verb RunAs cannot go through
# Invoke-Native (a plain call cannot elevate), so this is its own seam.
function Invoke-BrynqElevated {
    param([string]$EncodedCommand)
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $EncodedCommand)
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList $argv -ErrorAction Stop
}

# --- probe -------------------------------------------------------------------

# wsl.exe output: UTF-8 with WSL_UTF8=1, UTF-16 (NULs between the letters) when
# an older wsl.exe ignores it.
function ConvertFrom-BrynqWslOutput {
    param($Lines)
    @($Lines | ForEach-Object { "$_".Replace([string][char]0, '') })
}

function Read-BrynqState {
    param($Paths)
    $text = Read-BrynqText $Paths.state
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json }
    catch { return $null }
}

# The distro the app's wsl.json names (X step 3 format), or $null.
function Read-BrynqAppDistro {
    param($Paths)
    $text = Read-BrynqText $Paths.app_wsl
    if (-not $text) { return $null }
    try { $data = $text | ConvertFrom-Json }
    catch { return $null }
    if ("$($data.version)" -ne '1') { return $null }
    $name = "$($data.distro)".Trim()
    if ($name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $name }
    return $null
}

# What phase A needs to know about Windows. Read only, no admin, no distro
# started (BOOT D2.3-4). The distros: Get-BrynqDistroInventory.
function Get-BrynqWindowsProbe {
    param($Paths)
    $env:WSL_UTF8 = '1'
    $version = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--version'
    $installed = $version.ExitCode -eq 0
    $vmpError = $false
    if ($installed) {
        $status = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--status'
        $text = (ConvertFrom-BrynqWslOutput $status.Output) -join "`n"
        $vmpError = $status.ExitCode -ne 0 -and $text -match 'Virtual ?Machine ?Platform|HCS_E_HYPERV_NOT_INSTALLED'
    }
    $vmp = Get-BrynqCimInstance -ClassName 'Win32_OptionalFeature' -Filter "Name='VirtualMachinePlatform'"
    $os = Get-BrynqCimInstance -ClassName 'Win32_OperatingSystem'
    $boot = $null
    if ($null -ne $os -and $null -ne $os.LastBootUpTime) {
        $boot = ([datetime]$os.LastBootUpTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    $anchors = @()
    if ($Paths.startup -and (Test-Path -LiteralPath $Paths.startup)) {
        foreach ($f in Get-ChildItem -LiteralPath $Paths.startup -Filter 'BrynQ Toolkit (*).lnk' -ErrorAction SilentlyContinue) {
            if ($f.Name -match '^BrynQ Toolkit \((.+)\)\.lnk$') { $anchors += $Matches[1] }
        }
    }
    $oldShortcut = $false
    foreach ($dir in $Paths.desktop, $Paths.programs) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'BrynQ Agents.lnk'))) { $oldShortcut = $true }
    }
    [pscustomobject]@{
        wsl_installed      = $installed
        vmp_enabled        = ($null -ne $vmp -and "$($vmp.InstallState)" -eq '1')
        boot_time          = $boot
        cbs_reboot_pending = (Test-BrynqRegistryKey $script:BrynqCbsRebootKey)
        wsl_vmp_error      = [bool]$vmpError
        anchor_links       = $anchors
        old_shortcut       = $oldShortcut
        old_keepalive      = [bool]($Paths.startup -and (Test-Path -LiteralPath (Join-Path $Paths.startup 'BrynQ WSL keep-alive.vbs')))
    }
}

# --- distros: listing and the read-only probe (BOOT D3) ---------------------

# Distro names we pass to wsl.exe and into shell lines (wsl.exe's own rule is
# similar; anything else is listed but never probed or chosen).
$script:BrynqDistroNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'

# `wsl.exe --list --verbose` rows: [* ]NAME STATE VERSION. The header and any
# message line do not end in a WSL version, so they never match.
function ConvertFrom-BrynqWslList {
    param($Lines)
    foreach ($line in (ConvertFrom-BrynqWslOutput $Lines)) {
        $t = $line.Replace([string][char]0xFEFF, '').TrimEnd()
        if ($t -match '^\s*(\*?)\s*(\S+)\s+(\S.*?)\s+([12])$') {
            [pscustomobject]@{
                name    = $Matches[2]
                state   = $Matches[3]
                version = [int]$Matches[4]
                default = ($Matches[1] -eq '*')
            }
        }
    }
}

# The listed distros. Listing starts none of them. UTF-8 with WSL_UTF8=1, and
# NULs stripped in case an older wsl.exe ignores it and prints UTF-16 (W: the
# spaced-out S03 files). No distro at all: wsl.exe exits non-zero with a
# message, which is an empty list.
function Get-BrynqDistroList {
    $env:WSL_UTF8 = '1'
    $r = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--list', '--verbose'
    if ($r.ExitCode -ne 0) { return @() }
    @(ConvertFrom-BrynqWslList $r.Output)
}

# The probe that runs inside each WSL 2 distro (POSIX sh, as the distro's
# default user, `-e sh` so no login file runs). Read only: no bd, claude, apt
# or git fetch; `gh auth status` with a 5 s timeout. Prints one JSON line;
# files whose content is JSON go out as base64 and are parsed on this side, so
# a broken file never breaks the line. LF line endings, ASCII.
$script:BrynqProbeScript = @'
PATH="$HOME/.local/bin:$PATH"
j() { printf '%s' "$1" | tr -d '\r\n\t' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
b() { if [ -f "$1" ]; then base64 < "$1" | tr -d '\n'; fi; }
has() { if command -v "$1" >/dev/null 2>&1; then echo true; else echo false; fi; }
os_id=; os_version=
if [ -r /etc/os-release ]; then
  os_id=$(. /etc/os-release; echo "$ID")
  os_version=$(. /etc/os-release; echo "$VERSION_ID")
fi
# Interop: a Windows program actually runs. With [interop] enabled=false the
# WSLInterop binfmt entry is still registered (K3f S10d), so that is no test.
interop=false
if command -v timeout >/dev/null 2>&1; then
  if timeout 5 /mnt/c/Windows/System32/cmd.exe /c exit </dev/null >/dev/null 2>&1; then interop=true; fi
elif /mnt/c/Windows/System32/cmd.exe /c exit </dev/null >/dev/null 2>&1; then interop=true; fi
tools=
for t in git gh uv claude tmux python3 node curl; do tools="$tools\"$t\":$(has $t),"; done
tools=${tools%,}
gh_version=; gh_ok=false; gh_scopes=
if command -v gh >/dev/null 2>&1; then
  gh_version=$(gh --version 2>/dev/null | head -n 1 | sed -n 's/^gh version \([^ ]*\).*/\1/p')
  if out=$(timeout 5 gh auth status 2>&1); then gh_ok=true; fi
  gh_scopes=$(printf '%s\n' "$out" | sed -n 's/.*Token scopes: *//p' | head -n 1)
fi
mode_file="$HOME/.brynq/toolkit_mode.json"
checkout=
if [ -f "$mode_file" ]; then
  checkout=$(sed -n 's/.*"checkout"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$mode_file" | head -n 1)
fi
if [ -z "$checkout" ]; then checkout="$HOME/data_analytics/brynq-ai-toolkit"; fi
checkout_version=
if [ -f "$checkout/VERSION" ]; then checkout_version=$(head -n 1 "$checkout/VERSION"); fi
tag=
if [ -d "$HOME/.brynq/toolkit" ] && command -v git >/dev/null 2>&1; then
  tag=$(GIT_OPTIONAL_LOCKS=0 git -C "$HOME/.brynq/toolkit" describe --tags --exact-match 2>/dev/null)
fi
bd_path=; bd_version=
if [ -e "$HOME/.local/bin/bd" ]; then
  bd_path=$(readlink -f "$HOME/.local/bin/bd")
  for d in "$(dirname "$bd_path")"/../lib/python*/site-packages/brynq_devtools-*.dist-info; do
    if [ -d "$d" ]; then bd_version=$(basename "$d" .dist-info | sed 's/^brynq_devtools-//'); fi
  done
fi
wsl_distro_file=
if [ -f "$HOME/.brynq/wsl_distro" ]; then wsl_distro_file=$(head -n 1 "$HOME/.brynq/wsl_distro"); fi
last_use=
if [ -d "$HOME/.claude/projects" ]; then
  newest=$(find "$HOME/.claude/projects" -maxdepth 2 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 | cut -d. -f1)
  if [ -n "$newest" ]; then last_use=$(date -u -d "@$newest" +%Y-%m-%d 2>/dev/null); fi
fi
printf '{"schema":1,"uid":%s,"user":"%s","home":"%s","os_id":"%s","os_version":"%s","apt":%s,"interop":%s,"tools":{%s},"gh_version":"%s","gh_ok":%s,"gh_scopes":"%s","mode_b64":"%s","checkout_version":"%s","release_clone_tag":"%s","bd_path":"%s","bd_version":"%s","plugin_b64":"%s","wsl_distro_file":"%s","last_claude_use":"%s"}\n' \
  "$(id -u)" "$(j "$(id -un)")" "$(j "$HOME")" "$(j "$os_id")" "$(j "$os_version")" "$(has apt-get)" "$interop" \
  "$tools" "$(j "$gh_version")" "$gh_ok" "$(j "$gh_scopes")" "$(b "$mode_file")" "$(j "$checkout_version")" \
  "$(j "$tag")" "$(j "$bd_path")" "$(j "$bd_version")" "$(b "$HOME/.claude/plugins/installed_plugins.json")" \
  "$(j "$wsl_distro_file")" "$(j "$last_use")"
'@

# A shell script as one base64 word (LF endings): `echo <it> | base64 -d | sh`
# needs no quoting that Windows PowerShell 5.1 could mangle.
function ConvertTo-BrynqBase64Script {
    [OutputType([string])]
    param([string]$Script)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r`n", "`n")))
}

function ConvertFrom-BrynqBase64Json {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text)) | ConvertFrom-Json }
    catch { return $null }
}

function ConvertTo-BrynqNull {
    param($Value)
    if ("$Value" -eq '') { return $null }
    "$Value"
}

# The probe's output -> the BOOT D3 contract object, or $null when the output
# is not one schema-1 JSON line (= the probe failed for that distro).
function ConvertFrom-BrynqDistroProbe {
    param($Lines)
    $json = @(@($Lines) | ForEach-Object { "$_".Trim() } | Where-Object { $_.StartsWith('{"schema":') })
    if ($json.Count -ne 1) { return $null }
    try { $raw = $json[0] | ConvertFrom-Json }
    catch { return $null }
    if ("$($raw.schema)" -ne '1') { return $null }
    $tools = $raw.tools
    if ($null -ne $tools -and $raw.gh_version) { $tools.gh = "$($raw.gh_version)" }
    $scopes = @("$($raw.gh_scopes)" -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
    $plugin = $null
    $installed = ConvertFrom-BrynqBase64Json $raw.plugin_b64
    if ($null -ne $installed -and $null -ne $installed.plugins) {
        $entry = @($installed.plugins.'brynq-toolkit@brynq-tools') | Where-Object { $null -ne $_ } | Select-Object -First 1
        if ($null -ne $entry) {
            $plugin = [pscustomobject]@{ version = $entry.version; scope = $entry.scope; lastUpdated = $entry.lastUpdated }
        }
    }
    $mode = ConvertFrom-BrynqBase64Json $raw.mode_b64
    # The checkout's VERSION file holds `VERSION=2.1.27` (a bare version is read too).
    $checkoutVersion = ConvertTo-BrynqNull ("$($raw.checkout_version)" -replace '^VERSION=', '')
    $bd = $null
    if ($raw.bd_path) {
        $bdVersion = ConvertTo-BrynqNull $raw.bd_version
        # Local mode installs bd editable from the checkout: the dist-info name is
        # the version at the last install, the code is the checkout's (K3f rerun R3).
        if ("$($mode.mode)" -eq 'local' -and $checkoutVersion) { $bdVersion = $checkoutVersion }
        $bd = [pscustomobject]@{ path = "$($raw.bd_path)"; version = $bdVersion }
    }
    [pscustomobject]@{
        schema            = 1
        uid               = [int]$raw.uid
        user              = ConvertTo-BrynqNull $raw.user
        home              = ConvertTo-BrynqNull $raw.home
        os_id             = ConvertTo-BrynqNull $raw.os_id
        os_version        = ConvertTo-BrynqNull $raw.os_version
        apt               = [bool]$raw.apt
        interop           = [bool]$raw.interop
        tools             = $tools
        gh_auth           = [pscustomobject]@{ ok = [bool]$raw.gh_ok; scopes = $scopes }
        mode              = $mode
        checkout_version  = $checkoutVersion
        release_clone_tag = ConvertTo-BrynqNull $raw.release_clone_tag
        bd                = $bd
        plugin            = $plugin
        wsl_distro_file   = ConvertTo-BrynqNull $raw.wsl_distro_file
        last_claude_use   = ConvertTo-BrynqNull $raw.last_claude_use
    }
}

# A cold start with interop off takes ~20.5 s (WSL waits for the systemd user
# session; K3f S10d), so the probe gets 45 s.
$script:BrynqProbeTimeoutSeconds = 45

# Probe one listed distro: {probe (BOOT D3 contract or $null), error ($null,
# 'timeout', 'exit <n>' or 'no JSON')}. Probing starts a stopped distro, so one
# that was Stopped is stopped again afterwards, also when the probe failed.
function Get-BrynqDistroProbe {
    param($Row)
    $encoded = ConvertTo-BrynqBase64Script $script:BrynqProbeScript
    $r = Invoke-BrynqWsl -Distro $Row.name -ArgumentList '-e', 'sh', '-c', "echo $encoded | base64 -d | sh" -TimeoutSeconds $script:BrynqProbeTimeoutSeconds
    if ($Row.state -eq 'Stopped') {
        $null = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--terminate', $Row.name
    }
    if ($r.ExitCode -eq 124) { return [pscustomobject]@{ probe = $null; error = 'timeout' } }
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ probe = $null; error = "exit $($r.ExitCode)" } }
    $probe = ConvertFrom-BrynqDistroProbe $r.Output
    if ($null -eq $probe) { return [pscustomobject]@{ probe = $null; error = 'no JSON' } }
    [pscustomobject]@{ probe = $probe; error = $null }
}

# The listed distros with their probes (the `distros` part of the probe).
# Only WSL 2 distros with a plain name are probed. When BRYNQ_DISTRO or the
# app's wsl.json already names an existing distro, only that one is probed
# (choosing rules 1-2 look at no other, and no other distro is started);
# BRYNQ_DISTRO=new probes only a distro already called BrynQ.
function Get-BrynqDistroInventory {
    param($Options, [string]$AppDistro)
    $rows = @(Get-BrynqDistroList)
    $only = $null
    if ($Options.distro -eq 'new') { $only = $script:BrynqNewDistro }
    elseif ($Options.distro) { $only = $Options.distro }
    elseif ($AppDistro) { $only = $AppDistro }
    if ($only -and $null -eq (Find-BrynqDistro $rows $only)) {
        if ($Options.distro -ne 'new') { $only = $null }
    }
    foreach ($row in $rows) {
        $result = [pscustomobject]@{ probe = $null; error = $null }
        $wanted = (-not $only) -or ($row.name -ieq $only)
        if ($wanted -and $row.version -eq 2 -and $row.name -match $script:BrynqDistroNamePattern) {
            $result = Get-BrynqDistroProbe $row
        }
        [pscustomobject]@{
            name = $row.name; state = $row.state; version = $row.version; default = $row.default
            probe = $result.probe; probe_error = $result.error
        }
    }
}

# The full probe Get-BrynqPlan takes (shape documented there). Distros are
# listed and probed only once WSL works (no restart pending).
function Get-BrynqProbe {
    param($Options, $Paths, $State)
    $windows = Get-BrynqWindowsProbe $Paths
    $appDistro = Read-BrynqAppDistro $Paths
    $distros = @()
    if ($windows.wsl_installed -and $windows.vmp_enabled -and -not (Get-BrynqRebootReason $windows $State)) {
        $distros = @(Get-BrynqDistroInventory -Options $Options -AppDistro $appDistro)
    }
    [pscustomobject]@{
        options = $Options
        windows = $windows
        state   = $State
        app     = [pscustomobject]@{
            installed = ($null -ne (Get-BrynqAppEntry))
            distro    = $appDistro
        }
        distros = $distros
        answers = [pscustomobject]@{ distro = $null }
    }
}

# --- state file ----------------------------------------------------------------

# Merge fields into %LOCALAPPDATA%\BrynQ\bootstrap-state.json (keeps the fields
# other steps wrote, e.g. created_by_bootstrap). Written only when the text
# changes, so a run that changes nothing leaves the file's mtime alone.
function Save-BrynqState {
    param($Paths, $State, [hashtable]$Fields)
    $o = [ordered]@{ version = 1 }
    if ($null -ne $State) {
        foreach ($p in $State.PSObject.Properties) { $o[$p.Name] = $p.Value }
    }
    foreach ($k in $Fields.Keys) { $o[$k] = $Fields[$k] }
    $o['version'] = 1
    $text = ([pscustomobject]$o) | ConvertTo-Json -Depth 5
    if ($text -cne (Read-BrynqText $Paths.state)) { Write-BrynqFile $Paths.state $text }
    [pscustomobject]$o
}

# --- enable-wsl: the one admin prompt ----------------------------------------

# The script the elevated child runs: `wsl.exe --install --no-distribution`
# (Store WSL + Virtual Machine Platform; no distro in this run: that is the
# reboot bug of the old bootstrap-windows.ps1), then the VMP state, written as
# {rc, vmp_state, restart_needed, output} to the result file. The path is
# absolute: an over-the-shoulder admin has another %LOCALAPPDATA%. The feature
# state comes from Get-WindowsOptionalFeature (an enum, the same in every
# Windows language) rather than dism's translated text.
function New-BrynqEnableWslScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes nothing.')]
    [OutputType([string])]
    param([string]$ResultPath)
    $quoted = "'" + $ResultPath.Replace("'", "''") + "'"
    @(
        '$ErrorActionPreference = ''Continue'''
        '$env:WSL_UTF8 = ''1'''
        '$out = @(& wsl.exe --install --no-distribution 2>&1 | ForEach-Object { "$_".Replace([string][char]0, '''') })'
        '$rc = $LASTEXITCODE'
        '$state = ''unknown'''
        '$restart = $true'
        'try {'
        '    $f = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop'
        '    $state = "$($f.State)"'
        '    $restart = [bool]$f.RestartNeeded -or $state -ne ''Enabled'' -or $rc -eq 3010'
        '} catch { $out += "$_" }'
        '$result = [ordered]@{ rc = $rc; vmp_state = $state; restart_needed = $restart; output = @($out | Select-Object -Last 5) }'
        "[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($quoted))"
        "[IO.File]::WriteAllText($quoted, (ConvertTo-Json `$result -Compress), (New-Object Text.UTF8Encoding `$false))"
    ) -join "`r`n"
}

# Run the admin step. Returns @{code} (failed, exit code) or @{restart_needed}.
function Invoke-BrynqEnableWsl {
    param($Paths, $State, $Windows)
    Remove-BrynqFile $Paths.result
    # The child writes the result with plain WriteAllText: on a fresh machine
    # nothing has created %LOCALAPPDATA%\BrynQ yet, so the write failed and
    # the run stopped with "no result" although WSL was installed (K3f S1).
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Paths.result))
    Write-BrynqLine '  Windows asks for admin rights once (WSL and Virtual Machine Platform). Choose Yes.'
    $childScript = New-BrynqEnableWslScript -ResultPath $Paths.result
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    try {
        Invoke-BrynqElevated -EncodedCommand $encoded
    }
    catch {
        return @{ code = 11; message = "Windows needs admin rights once to turn on WSL. Run again and choose Yes, or ask IT. ($($_.Exception.Message))" }
    }
    $text = Read-BrynqText $Paths.result
    if (-not $text) {
        return @{ code = 11; message = 'The admin step did not finish (no result). Windows needs admin rights once to turn on WSL. Run again and choose Yes, or ask IT.' }
    }
    try { $result = $text | ConvertFrom-Json }
    catch { return @{ code = 11; message = 'The admin step left an unreadable result. Run again, or ask IT.' } }
    Remove-BrynqFile $Paths.result
    $rc = [int]$result.rc
    if ($rc -ne 0 -and $rc -ne 3010) {
        $tail = @($result.output) -join ' / '
        return @{ code = 11; message = "Turning on WSL failed (wsl.exe --install exit $rc): $tail. Run again, or ask IT." }
    }
    $restart = [bool]$result.restart_needed
    # The result file is removed above, so the state file counts the
    # `wsl --install` runs (the E2E harness checks it: one admin prompt).
    $runs = 1
    if ($null -ne $State -and $State.PSObject.Properties['wsl_install_runs']) { $runs += [int]$State.wsl_install_runs }
    $null = Save-BrynqState -Paths $Paths -State $State -Fields @{
        reboot_required  = $restart
        reboot_reason    = 'enable-wsl'
        boot_time        = $Windows.boot_time
        vmp_state        = "$($result.vmp_state)"
        wsl_install_runs = $runs
    }
    return @{ restart_needed = $restart }
}

# --- reboot: self copy, resume file, the question ---------------------------

# The BRYNQ_* lines the resume file sets (ordered, non-empty only). A value
# cmd.exe would interpret, or a URL with a user/password in it, is refused:
# nothing secret or unquotable is ever written to the Startup folder.
function Get-BrynqResumeVariable {
    param($Options)
    $values = [ordered]@{}
    if ($Options.dev) { $values['BRYNQ_DEV'] = '1' }
    if ($Options.no_sdk) { $values['BRYNQ_NO_SDK'] = '1' }
    if ($Options.noninteractive) { $values['BRYNQ_BOOTSTRAP_NONINTERACTIVE'] = '1' }
    if ($Options.distro) { $values['BRYNQ_DISTRO'] = "$($Options.distro)" }
    if ($Options.linux_user) { $values['BRYNQ_LINUX_USER'] = "$($Options.linux_user)" }
    if ($Options.retire_shortcut) { $values['BRYNQ_RETIRE_SHORTCUT'] = "$($Options.retire_shortcut)" }
    foreach ($name in 'BRYNQ_AUTO_RESTART', 'BRYNQ_BOOTSTRAP_BASE_URL', 'BRYNQ_TOOLKIT_REPO_URL') {
        $v = Get-BrynqEnv $name
        if ($v) { $values[$name] = $v }
    }
    foreach ($name in @($values.Keys)) {
        $v = $values[$name]
        if ($v -match '["%^&|<>!\r\n]') { throw "$name contains a character the restart file cannot carry (one of `" % ^ & | < > !). Use a plain value." }
        if ($v -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@') { throw "$name contains a user name or password; it would be written to the Startup folder. Use a URL without one." }
    }
    $values
}

# Startup\BrynQ-resume.cmd: the answers, then a new PowerShell window that
# runs the saved copy (iex of a string, so a GPO execution policy does not
# block it), then the file deletes itself. %LOCALAPPDATA% is expanded by that
# PowerShell, so a profile path with spaces, quotes or non-ASCII is never
# written into the file. CRLF line endings (cmd.exe).
function New-BrynqResumeText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes nothing.')]
    [OutputType([string])]
    param($Options)
    $values = Get-BrynqResumeVariable $Options
    $lines = @(
        '@echo off'
        'rem BrynQ Toolkit setup: continues after the restart, then deletes this file.'
        'set "BRYNQ_BOOTSTRAP_RESUMED=1"'
    )
    foreach ($name in $values.Keys) { $lines += "set `"$name=$($values[$name])`"" }
    $lines += 'start "" powershell.exe -NoProfile -NoExit -Command "iex (Get-Content -Raw -LiteralPath $env:LOCALAPPDATA\BrynQ\brynq.ps1)"'
    $lines += '(goto) 2>nul & del "%~f0"'
    ($lines -join "`r`n") + "`r`n"
}

# Save this script to %LOCALAPPDATA%\BrynQ\brynq.ps1 for the resume. Run
# through `irm | iex` it has no file of its own, so it is fetched again from
# the base URL. A resumed run keeps the copy it runs from (no network at logon).
function Save-BrynqSelf {
    param($Paths)
    if ((Get-BrynqEnv 'BRYNQ_BOOTSTRAP_RESUMED') -eq '1' -and (Test-Path -LiteralPath $Paths.self -PathType Leaf)) { return }
    $base = Get-BrynqEnv 'BRYNQ_BOOTSTRAP_BASE_URL'
    if (-not $base) { $base = $script:BrynqBaseUrl }
    $text = Get-BrynqRemoteText ($base.TrimEnd('/') + '/brynq.ps1')
    if (-not "$text".Contains('function Get-BrynqPlan')) {
        throw "$base/brynq.ps1 is not the BrynQ setup script."
    }
    Write-BrynqFile $Paths.self "$text"
}

$script:BrynqRebootText = @{
    'enable-wsl' = 'WSL is turned on; Windows needs a restart to finish it.'
    'bootstrap'  = 'Windows still needs the restart that turns on WSL.'
    'windows'    = 'Windows has a restart pending (this may be a Windows Update); it has to happen before WSL can be set up.'
    'vmp'        = 'Virtual Machine Platform is not active yet; Windows needs a restart.'
}

# Prepare the resume, then ask (or restart in E2E). Returns the exit code.
function Invoke-BrynqReboot {
    param($Paths, $State, $Windows, $Options, [string]$Reason)
    try {
        $resume = New-BrynqResumeText $Options
    }
    catch {
        Write-BrynqLine "  $($_.Exception.Message)"
        return 2
    }
    $null = Save-BrynqState -Paths $Paths -State $State -Fields @{ reboot_required = $true; reboot_reason = $Reason; boot_time = $Windows.boot_time }
    try {
        Save-BrynqSelf $Paths
    }
    catch {
        Write-BrynqLine "  Could not save the setup for after the restart: $($_.Exception.Message)"
        Write-BrynqLine '  Restart Windows, then run the same command again.'
        return 10
    }
    Write-BrynqFile $Paths.resume $resume
    Write-BrynqLine "  $($script:BrynqRebootText[$Reason])"
    Write-BrynqLine '  After you sign in again the setup continues by itself. If it does not (Startup apps turned off), run the same command again.'
    $restart = $false
    if ((Get-BrynqEnv 'BRYNQ_AUTO_RESTART') -eq '1') {
        $restart = $true
    }
    elseif ($Options.noninteractive) {
        Write-BrynqLine '  Set BRYNQ_AUTO_RESTART to answer: Restart now?'
        return 20
    }
    else {
        $answer = "$(Read-BrynqAnswer 'Restart now? [Y/n]')".Trim()
        $restart = $answer -eq '' -or $answer -match '^(y|yes|j|ja)$'
    }
    if (-not $restart) {
        Write-BrynqLine '  Restart Windows, then the setup continues by itself. If it does not, run the same command again.'
        return 10
    }
    $r = Invoke-Native -FilePath 'shutdown.exe' -ArgumentList '/r', '/t', '0'
    if ($r.ExitCode -ne 0) {
        Write-BrynqLine "  Windows did not restart ($(@($r.Output) -join ' ')). Restart Windows yourself; the setup continues after you sign in."
        return 10
    }
    Write-BrynqLine '  Restarting Windows...'
    return 0
}

# --- distro step and phase B (BOOT D3 create/user, D4, D5) -----------------

# The image `create-distro` installs (W live 8: --name/--no-launch/--web-download).
$script:BrynqNewDistroImage = 'Ubuntu-24.04'

# Linux user names the install accepts (useradd's portable set, 32 chars).
$script:BrynqLinuxUserPattern = '^[a-z_][a-z0-9_-]{0,31}$'

# The suggested Linux user name: the Windows user name in lower case, accents
# dropped, cut to [a-z_][a-z0-9_-]{0,31}. Empty when nothing usable is left.
function ConvertTo-BrynqLinuxUser {
    [OutputType([string])]
    param([string]$WindowsName)
    $plain = "$WindowsName".Normalize([Text.NormalizationForm]::FormD)
    $plain = ($plain.ToCharArray() | Where-Object {
            [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
        }) -join ''
    $name = ($plain.ToLowerInvariant() -replace '[^a-z0-9_-]', '') -replace '^[^a-z_]+', ''
    if ($name.Length -gt 32) { $name = $name.Substring(0, 32) }
    $name
}

# The Linux user name: BRYNQ_LINUX_USER, else asked (Enter accepts the
# suggestion), at most three tries. $null when no valid name was given.
function Read-BrynqLinuxUser {
    param($Options, [string]$Distro)
    if ($Options.linux_user) {
        if ("$($Options.linux_user)" -cmatch $script:BrynqLinuxUserPattern) { return "$($Options.linux_user)" }
        Write-BrynqLine "  BRYNQ_LINUX_USER '$($Options.linux_user)' is not a valid Linux user name (lower case letters, digits, _ and -; starts with a letter or _)."
        return $null
    }
    $suggestion = ConvertTo-BrynqLinuxUser (Get-BrynqEnv 'USERNAME')
    for ($try = 0; $try -lt 3; $try++) {
        $prompt = "  Linux user name for '$Distro'"
        if ($suggestion) { $prompt += " [$suggestion]" }
        $answer = "$(Read-BrynqAnswer $prompt)".Trim()
        if ($answer -eq '' -and $suggestion) { return $suggestion }
        if ($answer -cmatch $script:BrynqLinuxUserPattern) { return $answer }
        Write-BrynqLine '  Use lower case letters, digits, _ and - (starting with a letter or _), at most 32.'
    }
    return $null
}

# Root script that makes <user> the distro's default user in /etc/wsl.conf:
# replaces `default=` in an existing [user] section or appends the section;
# every other line ([boot] included) stays. POSIX sh + awk, no sed -i.
function New-BrynqWslConfScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes nothing.')]
    [OutputType([string])]
    param([string]$User, [string]$Path = '/etc/wsl.conf')
    if ($User -cnotmatch $script:BrynqLinuxUserPattern) { throw "not a Linux user name: $User" }
    @(
        "f='$Path'"
        'if [ ! -f "$f" ]; then : > "$f"; fi'
        't=$(mktemp)'
        "awk -v u='$User' '"
        '/^\[/ { if (s && !done) { print "default=" u; done = 1 } s = ($0 == "[user]"); print; next }'
        's && /^[[:space:]]*default[[:space:]]*=/ { next }'
        '{ print }'
        'END { if (s && !done) { print "default=" u; done = 1 } if (!done) { print ""; print "[user]"; print "default=" u } }'
        "' `"`$f`" > `"`$t`" && cat `"`$t`" > `"`$f`" && rm -f `"`$t`""
    ) -join "`n"
}

# The last lines of a wsl.exe output, for the one-line failure hints.
function Get-BrynqTail {
    [OutputType([string])]
    param($Output, [int]$Count = 5)
    (@(ConvertFrom-BrynqWslOutput $Output) | Where-Object { "$_".Trim() } | Select-Object -Last $Count) -join ' / '
}

# Firmware virtualization off shows as 0x80370102 when the distro first starts.
function Test-BrynqVirtualizationOff {
    [OutputType([bool])]
    param($Output)
    [bool]((@(ConvertFrom-BrynqWslOutput $Output) -join "`n") -match '0x80370102')
}

$script:BrynqVirtualizationText = 'Turn on virtualization (Intel VT-x / AMD-V) in BIOS/UEFI, then run the same command again.'

# create-distro: a new Ubuntu called <name> (never another name when it is
# taken: exit 30). Recorded in the state file for the uninstall (step 21).
function Invoke-BrynqCreateDistro {
    param([string]$Name, $Paths)
    Write-BrynqLine "  Downloading $script:BrynqNewDistroImage (a few minutes)."
    $r = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--install', $script:BrynqNewDistroImage, '--name', $Name, '--no-launch', '--web-download'
    if (Test-BrynqVirtualizationOff $r.Output) { return @{ code = 12; message = $script:BrynqVirtualizationText } }
    if ($r.ExitCode -ne 0) {
        return @{ code = 30; message = "Creating the distro '$Name' failed (wsl.exe exit $($r.ExitCode)): $(Get-BrynqTail $r.Output). Run the same command again." }
    }
    $null = Save-BrynqState -Paths $Paths -State (Read-BrynqState $Paths) -Fields @{ created_by_bootstrap = $true; distro = $Name }
    return $null
}

# create-user: the first-run user (uid 1000, sudo), its password at this
# console, `[user] default=` in /etc/wsl.conf, then the distro is stopped so
# the next start uses it. Ubuntu's own first-run prompt skips once uid 1000
# exists. Test mode (no console) sets no password (`passwd -d`).
function Invoke-BrynqCreateUser {
    param([string]$Name, $Options)
    $user = Read-BrynqLinuxUser -Options $Options -Distro $Name
    if (-not $user) { return @{ code = 31; message = "No valid Linux user name for '$Name'. Run the same command again." } }
    # Absolute path: on WSL 3.0.3 `wsl -e` does not find /usr/sbin binaries by
    # name (execvpe failed, K3f S3), although the distro PATH contains /usr/sbin.
    $r = Invoke-BrynqWsl -Distro $Name -ArgumentList '-u', 'root', '-e', '/usr/sbin/useradd', '-m', '-u', '1000', '-s', '/bin/bash', '-G', 'sudo', $user
    if (Test-BrynqVirtualizationOff $r.Output) { return @{ code = 12; message = $script:BrynqVirtualizationText } }
    if ($r.ExitCode -ne 0) {
        return @{ code = 31; message = "Creating the Linux user '$user' in '$Name' failed (exit $($r.ExitCode)): $(Get-BrynqTail $r.Output). Run the same command again." }
    }
    if ($Options.noninteractive) {
        $r = Invoke-BrynqWsl -Distro $Name -ArgumentList '-u', 'root', '-e', 'passwd', '-d', $user
        $ok = $r.ExitCode -eq 0
    }
    else {
        Write-BrynqLine "  Choose a password for '$user' (Linux asks for it with sudo)."
        $ok = $false
        for ($try = 0; $try -lt 3 -and -not $ok; $try++) {
            $ok = (Invoke-BrynqWsl -Distro $Name -ArgumentList '-u', 'root', '-e', 'passwd', $user -Console).ExitCode -eq 0
        }
    }
    if (-not $ok) { return @{ code = 31; message = "Setting the password for '$user' in '$Name' failed. Run the same command again." } }
    $conf = ConvertTo-BrynqBase64Script (New-BrynqWslConfScript -User $user)
    $r = Invoke-BrynqWsl -Distro $Name -ArgumentList '-u', 'root', '-e', 'sh', '-c', "echo $conf | base64 -d | sh"
    if ($r.ExitCode -ne 0) {
        return @{ code = 31; message = "Making '$user' the default user of '$Name' failed: $(Get-BrynqTail $r.Output). Run the same command again." }
    }
    $null = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--terminate', $Name
    return $null
}

# A value that goes into the phase-B shell line between single quotes: no
# quotes, backslashes, `$`, backticks or white space (the line also passes
# through wsl.exe's command line, BOOT D4).
function Assert-BrynqShellWord {
    param([string]$Name, [string]$Value)
    if ($Value -match "[\s'`"\\`$``]") {
        throw "$Name contains a character the setup cannot pass into WSL (quote, backslash, `$, backtick or space). Use a plain value."
    }
}

# The phase-B line: bootstrap.sh (the public copy of bootstrap-remote.sh, from
# the same base URL as brynq.ps1) piped into bash with the step-14 flags.
# file:///C:/... (E2E) is read through /mnt/c inside the distro. Test-mode
# answers ride along as variables.
function Get-BrynqBootstrapCommand {
    [OutputType([string])]
    param($Options, [string[]]$Arguments)
    $base = Get-BrynqEnv 'BRYNQ_BOOTSTRAP_BASE_URL'
    if (-not $base) { $base = $script:BrynqBaseUrl }
    $base = $base.TrimEnd('/')
    $uri = [Uri]$base
    if ($uri.IsFile) {
        if ($uri.LocalPath -notmatch '^([A-Za-z]):\\(.*)$') { throw "BRYNQ_BOOTSTRAP_BASE_URL must be a file:///<drive>:/ URL or http(s)." }
        $path = '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\', '/').TrimEnd('/') + '/bootstrap.sh'
        $path = $path.Replace('//', '/')
        Assert-BrynqShellWord 'BRYNQ_BOOTSTRAP_BASE_URL' $path
        $source = "cat '$path'"
    }
    else {
        Assert-BrynqShellWord 'BRYNQ_BOOTSTRAP_BASE_URL' $base
        $source = "curl -fsSL '$base/bootstrap.sh'"
    }
    $vars = ''
    if ($Options.noninteractive) { $vars += "BRYNQ_BOOTSTRAP_NONINTERACTIVE='1' " }
    $repo = Get-BrynqEnv 'BRYNQ_TOOLKIT_REPO_URL'
    if ($repo) {
        Assert-BrynqShellWord 'BRYNQ_TOOLKIT_REPO_URL' $repo
        $vars += "BRYNQ_TOOLKIT_REPO_URL='$repo' "
    }
    "$source | ${vars}bash -s -- $($Arguments -join ' ')"
}

# One phase-B command in the distro's home, through a login shell (PATH with
# ~/.local/bin), at this console (sudo, the GitHub and feed device codes).
function Invoke-BrynqInDistro {
    [OutputType([int])]
    param([string]$Distro, [string]$Command)
    (Invoke-BrynqWsl -Distro $Distro -ArgumentList '--cd', '~', '--', 'bash', '-lc', $Command -Console).ExitCode
}

# One menu line per choice.
function Format-BrynqDistroChoice {
    [OutputType([string])]
    param([string]$Option, $Probe)
    if ($Option -eq 'new') { return "create a new distro '$script:BrynqNewDistro' (Ubuntu 24.04)" }
    $d = Find-BrynqDistro $Probe.distros $Option
    $p = $d.probe
    $class = Get-BrynqDistroClass $d
    if ($class -eq 'ready' -or $class -eq 'partial') {
        $version = $p.bd.version
        if (-not $version) { $version = $p.checkout_version }
        if (-not $version) { $version = 'unknown version' }
        $text = "$Option (toolkit $version, $($p.mode.mode) mode"
        if ($p.last_claude_use) { $text += ", last used $($p.last_claude_use)" }
        if ($class -eq 'partial' -and $p.bd -and -not (Test-BrynqBdCurrent $p.bd.version)) { $text += ", bd older than ${script:BrynqMinBdVersion}: it is updated" }
        elseif ($class -eq 'partial') { $text += ', unfinished: it is repaired' }
        return "$text)"
    }
    $what = 'no Linux user yet'
    if ($class -eq 'empty') { $what = 'no toolkit yet' }
    "$Option ($($p.os_id) $($p.os_version), $what)"
}

# Ask the choose-distro menu: a number or a name, at most three tries. The
# answer goes into the probe and the plan is made again (the planner refuses
# an answer that is not a choice: exit 21).
function Read-BrynqDistroChoice {
    param($Action, $Probe)
    $options = @($Action.options)
    Write-BrynqLine '  Which WSL distro should BrynQ use?'
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-BrynqLine "    $($i + 1)) $(Format-BrynqDistroChoice $options[$i] $Probe)"
    }
    $answer = ''
    for ($try = 0; $try -lt 3; $try++) {
        $answer = "$(Read-BrynqAnswer "  Number [1-$($options.Count)]")".Trim()
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $options[$n - 1] }
        foreach ($o in $options) { if ($o -ieq $answer) { return $o } }
        Write-BrynqLine "  Type a number from 1 to $($options.Count)."
    }
    return $answer
}

$script:BrynqDistroLabel = @{
    'create-distro'   = 'Creating the WSL distro ''{0}'' (Ubuntu 24.04)'
    'create-user'     = 'Creating your Linux user in ''{0}'''
    'github-sign-in'  = 'Signing in to GitHub: the toolkit''s Claude plugin comes from a private GitHub repository'
    'run-bootstrap'   = 'Installing the toolkit in ''{0}'''
    'bridge'          = 'Connecting Windows to ''{0}'' (git sign-in, app settings)'
    'retire-shortcut' = 'Removing the old BrynQ Agents shortcut (asks first)'
    'anchor'          = 'Keeping ''{0}'' running after you close the app (sign-in link)'
    'desktop-install' = 'Installing the BrynQ Toolkit app'
    'desktop-open'    = 'Opening the BrynQ Toolkit app'
}

# Run one phase-B action. Returns $null or @{code; message} (BOOT D10).
function Invoke-BrynqDistroAction {
    param($Action, $Options, $Paths)
    $d = $Action.distro
    switch ($Action.action) {
        'create-distro' { return Invoke-BrynqCreateDistro -Name $d -Paths $Paths }
        'create-user' { return Invoke-BrynqCreateUser -Name $d -Options $Options }
        'github-sign-in' {
            # The sign-in step installs every system package before gh auth login
            # (one sudo prompt for the run); --no-sdk leaves azure-cli out.
            $signInArgs = @('--sign-in')
            if ($Options.no_sdk) { $signInArgs += '--no-sdk' }
            try { $command = Get-BrynqBootstrapCommand -Options $Options -Arguments $signInArgs }
            catch { return @{ code = 2; message = $_.Exception.Message } }
            $rc = Invoke-BrynqInDistro -Distro $d -Command $command
            if ($rc -eq 0) { return $null }
            if ($rc -eq 20) {
                # A resumed run got the variable from the restart file: this window keeps it.
                $again = if ((Get-BrynqEnv 'BRYNQ_BOOTSTRAP_RESUMED') -eq '1') { 'This window continued the setup after the restart with BRYNQ_BOOTSTRAP_NONINTERACTIVE set: open a new PowerShell window and run the same command again there.' }
                else { 'Run the same command again without BRYNQ_BOOTSTRAP_NONINTERACTIVE.' }
                return @{ code = 20; message = "Signing in to GitHub in '$d' needs an interactive console (see the line above). $again" }
            }
            return @{ code = 40; message = "Signing in to GitHub in '$d' failed (exit $rc). See the step above and the log it named, then run the same command again." }
        }
        'run-bootstrap' {
            try { $command = Get-BrynqBootstrapCommand -Options $Options -Arguments $Action.args }
            catch { return @{ code = 2; message = $_.Exception.Message } }
            $rc = Invoke-BrynqInDistro -Distro $d -Command $command
            if ($rc -eq 0) { return $null }
            if ($rc -eq 20) { return @{ code = 20; message = "The toolkit setup in '$d' stopped: it needs an answer or your action (see the line above)." } }
            return @{ code = 40; message = "The toolkit setup in '$d' failed (exit $rc). See the step and the log it named (~/.brynq/logs/bootstrap-*.log; open it with: wsl -d $d). Then run the same command again." }
        }
        'bridge' {
            # A bundle install (BRYNQ_TOOLKIT_REPO_URL, the E2E): the bridge skips
            # gh auth and its ls-remote check, and says so.
            $command = 'bd toolkit windows-bridge'
            if (Get-BrynqEnv 'BRYNQ_TOOLKIT_REPO_URL') { $command += ' --no-github' }
            $rc = Invoke-BrynqInDistro -Distro $d -Command $command
            if ($rc -eq 0) { return $null }
            if ($rc -eq 41) { return @{ code = 41; message = "Windows interop is off in '$d': run the command printed above, then run this again." } }
            return @{ code = 40; message = "Connecting Windows to '$d' failed (exit $rc). Check with: wsl -d $d bd toolkit windows-bridge --check" }
        }
        'anchor' {
            # The bridge writes the link too; this repeats it when the probe saw none (idempotent).
            $rc = Invoke-BrynqInDistro -Distro $d -Command 'bd toolkit windows-bridge --anchor'
            if ($rc -eq 0) { return $null }
            if ($rc -eq 41) { return @{ code = 41; message = "Windows interop is off in '$d': run the command printed above, then run this again." } }
            return @{ code = 40; message = "Writing the sign-in link for '$d' failed (exit $rc). Check with: wsl -d $d bd toolkit windows-bridge --check" }
        }
        'retire-shortcut' { return Invoke-BrynqRetireShortcut -Options $Options -Paths $Paths }
        'desktop-install' {
            $rc = Invoke-BrynqInDistro -Distro $d -Command 'bd toolkit desktop install'
            if ($rc -eq 0) { return $null }
            return @{ code = 50; message = "Installing the BrynQ Toolkit app failed (exit $rc). See: wsl -d $d bd toolkit desktop status" }
        }
        'desktop-open' {
            $rc = Invoke-BrynqInDistro -Distro $d -Command 'bd toolkit desktop open'
            if ($rc -eq 0) { return $null }
            return @{ code = 51; message = "Opening the BrynQ Toolkit app failed (exit $rc). See: wsl -d $d bd toolkit desktop status" }
        }
    }
    return @{ code = 1; message = "Unknown step '$($Action.action)'." }
}

# The distro step and phase B: the menu (if any), then each planned action
# with numbered progress. The choice is recorded by the bridge (the distro
# file in WSL and the app's wsl.json), so the next run asks nothing. Returns
# the exit code (BOOT D10).
function Invoke-BrynqDistroPhase {
    [OutputType([int])]
    param($Plan, $Probe, $Options, $Paths)
    $plan = @($Plan)
    if ($plan[0].action -eq 'choose-distro') {
        $Probe.answers.distro = Read-BrynqDistroChoice -Action $plan[0] -Probe $Probe
        $plan = @(Get-BrynqPlan -Probe $Probe)
    }
    if ($plan[0].action -eq 'fail') {
        Write-BrynqLine "  $($plan[0].message)"
        return [int]$plan[0].code
    }
    $steps = $plan
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $a = $steps[$i]
        $label = $script:BrynqDistroLabel[$a.action] -f $a.distro
        if ($a.action -eq 'run-bootstrap' -and $a.message) { $label += " ($($a.message))" }
        Write-BrynqLine ("[$($i + 1)/$($steps.Count)] " + $label + '...')
        $failed = Invoke-BrynqDistroAction -Action $a -Options $Options -Paths $Paths
        if ($null -ne $failed) {
            Write-BrynqLine "  $($failed.message)"
            return [int]$failed.code
        }
    }
    $null = Save-BrynqState -Paths $Paths -State (Read-BrynqState $Paths) -Fields @{ distro = $steps[0].distro }
    Write-BrynqLine 'BrynQ Toolkit is open. From now on use the BrynQ Toolkit icon.'
    return 0
}

$script:BrynqActionLabel = @{
    'enable-wsl' = 'Turning on WSL (one admin prompt)'
    'reboot'     = 'Restarting Windows'
}

# The options of this run (Get-BrynqOption over Get-BrynqEnv, so tests mock it).
function Get-BrynqRunOption {
    param([switch]$Dev, [switch]$NoSdk)
    $environment = @{}
    foreach ($name in $script:BrynqOptionVariables) { $environment[$name] = Get-BrynqEnv $name }
    Get-BrynqOption -Dev:$Dev -NoSdk:$NoSdk -Environment $environment
}

# The whole run. Returns the exit code (BOOT D10).
function Invoke-BrynqInstall {
    [CmdletBinding()]
    [OutputType([int])]
    param([switch]$Dev, [switch]$NoSdk)

    # First: constrained language mode (AppLocker/WDAC) blocks what follows.
    if ((Get-BrynqLanguageMode) -ne 'FullLanguage') {
        Write-BrynqLine 'Your IT policy blocks this script (PowerShell runs in Constrained Language Mode). Ask IT, or use the manual steps.'
        return 60
    }
    $options = Get-BrynqRunOption -Dev:$Dev -NoSdk:$NoSdk
    $paths = Get-BrynqPath
    $dryRun = (Get-BrynqEnv 'BRYNQ_BOOTSTRAP_DRYRUN') -eq '1'

    # The resume file runs at most once: removed before anything else.
    if (-not $dryRun) { Remove-BrynqFile $paths.resume }

    for ($pass = 0; $pass -lt 3; $pass++) {
        $state = Read-BrynqState $paths
        $probe = Get-BrynqProbe -Options $options -Paths $paths -State $state
        $plan = @(Get-BrynqPlan -Probe $probe)
        if ($dryRun) {
            Write-BrynqLine 'Probe:'
            Write-BrynqLine ($probe | ConvertTo-Json -Depth 8)
            Write-BrynqLine 'Plan:'
            Write-BrynqLine (ConvertTo-Json -InputObject $plan -Depth 5)
            Write-BrynqLine 'Dry run (BRYNQ_BOOTSTRAP_DRYRUN=1): nothing was changed.'
            return 0
        }
        $first = $plan[0].action
        if ($first -eq 'fail') {
            Write-BrynqLine "  $($plan[0].message)"
            return [int]$plan[0].code
        }
        if ($first -ne 'enable-wsl' -and $first -ne 'reboot') {
            # Restarted since the admin step: the state file no longer says so.
            if ($null -ne $state -and $state.reboot_required) {
                $null = Save-BrynqState -Paths $paths -State $state -Fields @{ reboot_required = $false }
            }
            return Invoke-BrynqDistroPhase -Plan $plan -Probe $probe -Options $options -Paths $paths
        }
        $total = $plan.Count
        for ($i = 0; $i -lt $total; $i++) {
            $a = $plan[$i]
            Write-BrynqLine "[$($i + 1)/$total] $($script:BrynqActionLabel[$a.action])..."
            if ($a.action -eq 'enable-wsl') {
                $r = Invoke-BrynqEnableWsl -Paths $paths -State $state -Windows $probe.windows
                if ($r.code) {
                    Write-BrynqLine "  $($r.message)"
                    return $r.code
                }
                # Only the Store package was missing: no restart, plan again.
                if (-not $r.restart_needed) { break }
                $state = Read-BrynqState $paths
            }
            elseif ($a.action -eq 'reboot') {
                return Invoke-BrynqReboot -Paths $paths -State $state -Windows $probe.windows -Options $options -Reason $a.reason
            }
        }
    }
    Write-BrynqLine '  WSL still is not ready after turning it on. Restart Windows and run the same command again.'
    return 10
}

# --- shortcut.ps1 clean-up and uninstall (BOOT B7, D9) ----------------------
# Nothing is removed without a yes: a y/yes typed at the console (Enter keeps),
# or in test mode the answer variable. A missing answer in test mode is exit 20
# before anything is removed.

# The old shortcut.ps1 files that exist: `BrynQ Agents.lnk` (Desktop, Start
# menu) and `Startup\BrynQ WSL keep-alive.vbs` (it runs wsl.exe without -d, so
# it keeps WSL's default distro running).
function Get-BrynqOldShortcutFile {
    param($Paths)
    $files = @()
    foreach ($dir in $Paths.desktop, $Paths.programs) {
        if ($dir) { $files += Join-Path $dir 'BrynQ Agents.lnk' }
    }
    if ($Paths.startup) { $files += Join-Path $Paths.startup 'BrynQ WSL keep-alive.vbs' }
    @($files | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}

# Our logon anchors in the Startup folder (`BrynQ Toolkit (<distro>).lnk`).
function Get-BrynqAnchorFile {
    param($Paths)
    if (-not $Paths.startup -or -not (Test-Path -LiteralPath $Paths.startup)) { return @() }
    @(Get-ChildItem -LiteralPath $Paths.startup -Filter 'BrynQ Toolkit (*).lnk' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^BrynQ Toolkit \(.+\)\.lnk$' } | ForEach-Object { $_.FullName })
}

# A question that removes something: $true only on y/yes/j/ja. $Value is the
# test-mode answer (yes / no) and answers without asking; in test mode without
# one the result is $null (the caller ends with exit 20 naming its variable).
function Get-BrynqYes {
    param($Options, $Value, [string]$Question)
    $v = "$Value".Trim().ToLowerInvariant()
    if ($v -eq 'yes') { return $true }
    if ($v -eq 'no') { return $false }
    if ($Options.noninteractive) { return $null }
    $answer = "$(Read-BrynqAnswer "  $Question [y/N]")".Trim()
    return [bool]($answer -match '^(?i)(y|yes|j|ja)$')
}

# The retire-shortcut step of the install. Declined: kept, the install goes on.
function Invoke-BrynqRetireShortcut {
    param($Options, $Paths)
    $found = @(Get-BrynqOldShortcutFile $Paths)
    if ($found.Count -eq 0) { return $null }
    Write-BrynqLine '  The old BrynQ Agents shortcut (shortcut.ps1) is still here. Its keep-alive starts WSL''s default distro at every sign-in; the BrynQ Toolkit app and its sign-in link replace both:'
    foreach ($f in $found) { Write-BrynqLine "    $f" }
    $yes = Get-BrynqYes -Options $Options -Value $Options.retire_shortcut -Question 'Remove them?'
    if ($null -eq $yes) {
        return @{ code = 20; message = 'Set BRYNQ_RETIRE_SHORTCUT to answer: Remove the old BrynQ Agents shortcut and its keep-alive (yes or no)?' }
    }
    if (-not $yes) {
        Write-BrynqLine '  Kept. You can delete the files above yourself later.'
        return $null
    }
    foreach ($f in $found) { Remove-BrynqFile $f }
    Write-BrynqLine '  Removed. A keep-alive that is already running stops when you sign out.'
    return $null
}

$script:BrynqHelperKey = 'credential.https://github.com.helper'

# The distro the uninstall runs `bd toolkit windows-bridge --remove` in:
# BRYNQ_DISTRO, else the app's wsl.json, else the state file. Never WSL's
# default distro; $null when none of them names one.
function Get-BrynqUninstallDistro {
    [OutputType([string])]
    param($Options, $Paths, $State)
    foreach ($candidate in $Options.distro, (Read-BrynqAppDistro $Paths), $State.distro) {
        if ($candidate -and "$candidate" -ne 'new' -and "$candidate" -match $script:BrynqDistroNamePattern) { return "$candidate" }
    }
    return $null
}

# BRYNQ_ACTION=uninstall (BOOT D9). Lists, asks every question, then removes.
# Returns 0 (done, or declined: nothing removed), 1 (a removal step failed,
# named; the rest still ran), 20 (test mode without an answer) or 60.
function Invoke-BrynqUninstall {
    [OutputType([int])]
    param()
    if ((Get-BrynqLanguageMode) -ne 'FullLanguage') {
        Write-BrynqLine 'Your IT policy blocks this script (PowerShell runs in Constrained Language Mode). Ask IT, or use the manual steps.'
        return 60
    }
    $options = Get-BrynqRunOption
    $paths = Get-BrynqPath
    $dryRun = (Get-BrynqEnv 'BRYNQ_BOOTSTRAP_DRYRUN') -eq '1'
    $state = Read-BrynqState $paths
    $entry = Get-BrynqAppEntry
    $listed = @(Get-BrynqDistroList | ForEach-Object { $_.name })
    $distro = Get-BrynqUninstallDistro -Options $options -Paths $paths -State $state
    $bridgeDistro = $null
    if ($distro -and ($listed -contains $distro)) { $bridgeDistro = @($listed | Where-Object { $_ -ieq $distro })[0] }
    $created = $null
    if ($null -ne $state -and $state.created_by_bootstrap -and $state.distro) {
        $created = @($listed | Where-Object { $_ -ieq "$($state.distro)" })[0]
    }

    $files = @(Get-BrynqOldShortcutFile $paths) + @(Get-BrynqAnchorFile $paths)
    if (Test-Path -LiteralPath $paths.resume -PathType Leaf) { $files += $paths.resume }
    $localDir = Test-Path -LiteralPath $paths.dir -PathType Container
    $appData = Test-Path -LiteralPath $paths.app_data -PathType Container

    $items = @()
    if ($null -ne $entry) { $items += "the BrynQ Toolkit app ($(Get-BrynqAppFolder $entry)), with its shortcuts" }
    if ($bridgeDistro) { $items += "Windows git's GitHub sign-in through WSL and the sign-in link (bd toolkit windows-bridge --remove in '$bridgeDistro')" }
    foreach ($f in $files) { $items += $f }
    if ($localDir) { $items += "$($paths.dir) (setup state and logs)" }

    Write-BrynqLine 'Uninstall BrynQ Toolkit (Windows side).'
    if ($items.Count -eq 0 -and -not $appData -and -not $created) {
        Write-BrynqLine '  Nothing of BrynQ Toolkit was found.'
        if ($distro -and -not $bridgeDistro) { Write-BrynqLine "  Distro '$distro' is not listed by wsl -l -v." }
        return 0
    }
    if ($items.Count -gt 0) {
        Write-BrynqLine '  This removes:'
        foreach ($i in $items) { Write-BrynqLine "    - $i" }
    }
    if ($distro -and -not $bridgeDistro) {
        Write-BrynqLine "  Distro '$distro' is not listed by wsl -l -v: Windows git's GitHub helper is not touched. Remove it yourself with: git config --global --unset-all $script:BrynqHelperKey"
    }
    elseif (-not $distro) {
        Write-BrynqLine "  No BrynQ distro is recorded (set BRYNQ_DISTRO=<name> to name it): Windows git's GitHub helper is not touched."
    }
    if ($dryRun) {
        if ($appData) { Write-BrynqLine "  Would ask before deleting $($paths.app_data) (the app's sign-ins)." }
        if ($created) { Write-BrynqLine "  Would offer to delete the distro '$created' (typed name)." }
        Write-BrynqLine 'Dry run (BRYNQ_BOOTSTRAP_DRYRUN=1): nothing was changed.'
        return 0
    }

    # Every question first: a missing test-mode answer removes nothing.
    $removeMain = $false
    if ($items.Count -gt 0) {
        $removeMain = Get-BrynqYes -Options $options -Value (Get-BrynqEnv 'BRYNQ_UNINSTALL') -Question 'Remove these?'
        if ($null -eq $removeMain) {
            Write-BrynqLine '  Set BRYNQ_UNINSTALL=yes to answer: Remove these?'
            return 20
        }
    }
    $removeAppData = $false
    if ($appData) {
        $removeAppData = Get-BrynqYes -Options $options -Value (Get-BrynqEnv 'BRYNQ_REMOVE_APP_DATA') -Question "Also delete $($paths.app_data)? It holds the app's settings and the sign-ins of its browser pane."
        if ($null -eq $removeAppData) {
            Write-BrynqLine "  Set BRYNQ_REMOVE_APP_DATA to answer (yes or no): Also delete $($paths.app_data)?"
            return 20
        }
    }
    $unregister = $false
    if ($created) {
        $typed = Get-BrynqEnv 'BRYNQ_UNREGISTER_DISTRO'
        if (-not $typed) {
            if ($options.noninteractive) {
                Write-BrynqLine "  Set BRYNQ_UNREGISTER_DISTRO to answer ('$created' or no): Delete the distro '$created' with everything in it?"
                return 20
            }
            Write-BrynqLine "  The setup created the WSL distro '$created'. Deleting it deletes everything in it (your Linux files, repos, sign-ins)."
            $typed = Read-BrynqAnswer "  Type $created to delete it, or press Enter to keep it"
        }
        $unregister = "$typed".Trim() -ceq $created
    }
    if (-not $removeMain -and -not $removeAppData -and -not $unregister) {
        Write-BrynqLine 'Nothing was removed.'
        return 0
    }

    $failed = @()
    if ($removeMain) {
        if ($bridgeDistro) {
            Write-BrynqLine "  Removing Windows git's GitHub sign-in through '$bridgeDistro'..."
            $rc = Invoke-BrynqInDistro -Distro $bridgeDistro -Command 'bd toolkit windows-bridge --remove'
            if ($rc -ne 0) {
                $failed += "Removing the GitHub sign-in bridge in '$bridgeDistro' failed (exit $rc). Remove it yourself with: git config --global --unset-all $script:BrynqHelperKey"
            }
        }
        if ($null -ne $entry) {
            Write-BrynqLine '  Removing the BrynQ Toolkit app...'
            $uninstaller = Get-BrynqAppUninstaller $entry
            $rc = Invoke-BrynqUninstaller -Path $uninstaller
            if ($rc -ne 0) {
                $failed += "The app's uninstaller failed (exit $rc, $uninstaller). Remove BrynQ Toolkit in Settings > Apps."
            }
        }
        foreach ($f in $files) { Remove-BrynqFile $f }
        Remove-BrynqDirectory $paths.dir
    }
    if ($removeAppData) { Remove-BrynqDirectory $paths.app_data }
    if ($created) {
        if ($unregister) {
            Write-BrynqLine "  Deleting the distro '$created'..."
            $r = Invoke-Native -FilePath 'wsl.exe' -ArgumentList '--unregister', $created
            if ($r.ExitCode -ne 0) { $failed += "Deleting the distro '$created' failed: $(Get-BrynqTail $r.Output). Run: wsl --unregister $created" }
        }
        else {
            Write-BrynqLine "  Kept the distro '$created'. To delete it later: wsl --unregister $created"
        }
    }
    elseif ($bridgeDistro) {
        Write-BrynqLine "  Kept the distro '$bridgeDistro' (this setup did not create it). Added there: ~/.brynq, ~/.local/bin/bd, the toolkit checkout and the Claude plugin; nothing inside it was removed."
    }
    Write-BrynqLine '  WSL and Virtual Machine Platform stay on. To turn them off (PowerShell as admin, then restart):'
    Write-BrynqLine '    dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart'
    Write-BrynqLine '    dism.exe /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart'
    foreach ($f in $failed) { Write-BrynqLine "  $f" }
    if ($failed.Count -gt 0) { return 1 }
    Write-BrynqLine 'BrynQ Toolkit is removed.'
    return 0
}

# BRYNQ_ACTION: install (the default) or uninstall. Returns the exit code.
function Invoke-BrynqMain {
    [OutputType([int])]
    param([switch]$Dev, [switch]$NoSdk)
    $action = "$(Get-BrynqEnv 'BRYNQ_ACTION')".Trim().ToLowerInvariant()
    if ($action -eq '' -or $action -eq 'install') { return Invoke-BrynqInstall -Dev:$Dev -NoSdk:$NoSdk }
    if ($action -eq 'uninstall') { return Invoke-BrynqUninstall }
    Write-BrynqLine "BRYNQ_ACTION '$action' is not known: use install (the default) or uninstall."
    return 2
}

# Run unless dot-sourced (the tests load the functions with `. brynq.ps1`).
# Through iex the code goes to $LASTEXITCODE: `exit` would close the window.
if ($MyInvocation.InvocationName -ne '.') {
    $global:LASTEXITCODE = Invoke-BrynqMain -Dev:$Dev -NoSdk:$NoSdk
}
