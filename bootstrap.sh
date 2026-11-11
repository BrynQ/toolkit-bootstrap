#!/usr/bin/env bash
# BrynQ AI Toolkit — one-line remote bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash
#   curl -fsSL …/bootstrap.sh | bash -s -- --no-wizard [--dev] [--no-sdk]
#   curl -fsSL …/bootstrap.sh | bash -s -- --sign-in
#
# Without flags (as before): install the system packages (git, gh and the
# toolkit's prerequisites), sign in to GitHub, clone or reuse the private
# toolkit, then open the setup wizard at http://127.0.0.1:8421.
#
# --no-wizard   Headless install instead of the wizard (the one-command installs
#               use it: bootstrap/brynq.sh, brynq.ps1 inside WSL). Also installs
#               uv and the Claude Code CLI, offers the SDK feed sign-in, and runs
#               setup.sh in published mode (no mode question).
# --dev         With --no-wizard: toolkit developer (setup.sh --developer: skills
#               and bd from the checkout). The checkout is never pulled.
# --no-sdk      With --no-wizard: skip the SDK feed and azure-cli ("I'm a PM";
#               setup.sh --no-azure). BRYNQ_NO_SDK=1 does the same. The app's first-run
#               checklist offers the sign-in later. Without --dev, on a fresh
#               install, the dashboard opens in the PM view (ui_profile "pm").
# --min-bd=X.Y.Z  With --no-wizard: the oldest toolkit this install accepts
#               (brynq.ps1 passes the bd its own steps need). A local-mode
#               checkout older than that is updated (see below) or the run stops.
# --sign-in     Only install the system packages and sign in to GitHub, then
#               stop (brynq.ps1 runs it before the install). Takes no other flag
#               than --no-sdk (no azure-cli).
#
# GitHub sign-in: always needed, also with BRYNQ_TOOLKIT_REPO_URL, because the
# toolkit's Claude plugin comes from a private GitHub repository. Without a
# login and without a terminal for `gh auth login`, the script stops with exit
# 20 before it installs anything.
#
# Test mode (environment): BRYNQ_BOOTSTRAP_NONINTERACTIVE=1 never asks; a
# question without an answer exits 20 naming the variable that answers it.
# BRYNQ_TOOLKIT_REPO_URL clones from that URL (a git bundle) instead of GitHub.
#
# A local-mode checkout (~/.brynq/toolkit_mode.json) is used as it is, unless
# it is older than --min-bd or than its source (its upstream branch; the
# source's HEAD when detached or with BRYNQ_TOOLKIT_REPO_URL). Then a clean one
# (no uncommitted changes, no untracked files, no unpushed commits) is
# fast-forwarded (or checked out at the source's HEAD) before setup.sh runs; one
# with local work stops with exit 20 and nothing changed. Exit codes: 0 done, 2 bad flags, 20 a question needs an answer (or
# the GitHub sign-in needs a terminal), 40 a step failed (the step, a
# one-sentence hint and the log path are printed).
# Log: ~/.brynq/logs/bootstrap-<time>.log (BRYNQ_BOOTSTRAP_LOG names another).
#
# Contains no secrets and handles none. The private clone and the Claude
# plugin are gated by your GitHub login.
#
# CANONICAL SOURCE for BrynQ/toolkit-bootstrap/bootstrap.sh — the file the curl
# one-liner above actually fetches. Publish any edit to both, byte for byte.
set -Eeuo pipefail

say() { echo "  $*"; [ -n "${IN_LOG_PIPE:-}" ] || [ -z "${LOG:-}" ] || echo "  $*" >>"${LOG}"; }

# gh floor — keep in sync with GH_MIN_VERSION in brynq_devtools/kits/ai_toolkit.py.
GH_MIN=(2 73 0)
GH_MIN_STR="${GH_MIN[0]}.${GH_MIN[1]}.${GH_MIN[2]}"

# `gh --version` prints e.g. `gh version 2.46.0 (2025-12-13 Ubuntu 2.46.0-4)`.
# Only the first number is the upstream version — the trailing one is the distro
# packaging revision and the date is the *packaging* date, so neither says how
# old the build is. False only when gh is absent or provably below the floor: an
# unparseable version is deliberately not held against it, so a future format
# change cannot make every run reinstall gh from the official repo.
gh_version_ok() {
    local out
    command -v gh >/dev/null 2>&1 || return 1
    out="$(gh --version 2>/dev/null)" || return 0
    [[ "${out}" =~ gh\ version\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 0
    (( BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3] \
       >= GH_MIN[0] * 1000000 + GH_MIN[1] * 1000 + GH_MIN[2] ))
}

# ── Flags, questions, progress, log ─────────────────────────────────────────
WIZARD=1
DEV=0
NO_SDK=0
SIGN_IN_ONLY=0
MIN_BD=""
parse_flags() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --sign-in) SIGN_IN_ONLY=1 ;;
            --no-wizard) WIZARD=0 ;;
            --dev) DEV=1 ;;
            --no-sdk) NO_SDK=1 ;;
            --min-bd=*)
                MIN_BD="${arg#--min-bd=}"
                [[ "${MIN_BD}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "--min-bd takes a version like 2.1.25, not '${MIN_BD}'." >&2; exit 2; }
                ;;
            -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]:-/dev/null}" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "Unknown argument: ${arg} (try --help)" >&2; exit 2 ;;
        esac
    done
    if [ "${SIGN_IN_ONLY}" -eq 1 ] && { [ "${WIZARD}" -eq 0 ] || [ "${DEV}" -eq 1 ]; }; then
        echo "--sign-in takes no other flag than --no-sdk." >&2
        exit 2
    fi
    if [ "${SIGN_IN_ONLY}" -eq 0 ] && [ "${WIZARD}" -eq 1 ] && { [ "${DEV}" -eq 1 ] || [ "${NO_SDK}" -eq 1 ]; }; then
        echo "--dev and --no-sdk go with --no-wizard (the setup wizard asks these itself)." >&2
        exit 2
    fi
    if [ "${WIZARD}" -eq 0 ] && [ "${BRYNQ_NO_SDK:-}" = "1" ]; then
        NO_SDK=1
    fi
}

NONINTERACTIVE=0
[ "${BRYNQ_BOOTSTRAP_NONINTERACTIVE:-}" = "1" ] && NONINTERACTIVE=1

# True when a question can be asked: not in test mode and a terminal is there
# (`curl … | bash` has the script on stdin, so answers come from /dev/tty).
can_ask() {
    [ "${NONINTERACTIVE}" -eq 0 ] && { : </dev/tty; } 2>/dev/null
}

ANSWER=""
ask() {
    ANSWER=""
    read -r -p "    $1 " ANSWER </dev/tty || ANSWER=""
}

LOG=""
setup_log() {
    LOG="${BRYNQ_BOOTSTRAP_LOG:-${HOME}/.brynq/logs/bootstrap-$(date +%Y%m%d-%H%M%S).log}"
    mkdir -p "$(dirname "${LOG}")"
    touch "${LOG}"
}

STEP=0
TOTAL=0
STEP_NAME=""
STEP_HINT=""
step() {
    STEP=$((STEP + 1))
    STEP_NAME="$1"
    STEP_HINT="$2"
    echo "[${STEP}/${TOTAL}] ${STEP_NAME}…"
    echo "[${STEP}/${TOTAL}] ${STEP_NAME}…" >>"${LOG}"
}

fail() {
    local code="$1"
    shift
    echo "✗ $*" >&2
    echo "✗ $*" >>"${LOG}"
    echo "  Log: ${LOG}" >&2
    exit "${code}"
}

# Any unexpected failure: name the step, its hint and the log; exit 40. A failure
# inside a subshell (run_logged) only passes its status up, so this prints once.
on_err() {
    local rc=$?
    [ "${BASH_SUBSHELL}" -eq 0 ] || exit "${rc}"
    trap - ERR
    fail 40 "Step ${STEP}/${TOTAL} (${STEP_NAME}) failed: ${STEP_HINT}"
}
trap on_err ERR

# Runs a non-interactive command with its output on screen and in the log.
# Interactive ones (gh auth login, the feed sign-in) run outside it: a pipe on
# stdout stops their prompts.
run_logged() {
    ( IN_LOG_PIPE=1; "$@" ) 2>&1 | tee -a "${LOG}"
    return "${PIPESTATUS[0]}"
}

# ── 1. System packages: git + gh, and the rest in the same sudo session ─────
# Every apt package the toolkit needs is installed here, before the GitHub
# sign-in: `gh auth login` can wait longer than sudo's 15-minute cache (K3f:
# ~16 min), and on Windows the install after `--sign-in` is another WSL
# session that does not share it. install_prereqs.sh then finds nothing
# missing and never asks for sudo. "package command" pairs, the same set as
# install_prereqs.sh's want_apt lines (tests/test_bootstrap_flags.py checks it).
APT_PACKAGES=("git git" "tmux tmux" "xterm xterm" "ffmpeg ffmpeg" "curl curl" "nodejs node" "npm npm" "bubblewrap bwrap")

missing_apt_packages() {
    local spec
    for spec in "${APT_PACKAGES[@]}"; do
        command -v "${spec#* }" >/dev/null 2>&1 || echo "${spec% *}"
    done
}

# azure-cli only for the SDK feed sign-in (setup_uv.py); --no-sdk leaves it out.
want_az() {
    [ "${NO_SDK}" -eq 0 ] && ! command -v az >/dev/null 2>&1
}

system_packages_missing() {
    command -v git >/dev/null 2>&1 && gh_version_ok || return 0
    command -v apt-get >/dev/null 2>&1 || return 1
    [ -n "$(missing_apt_packages)" ] || want_az
}

# The installed version, not apt's exit code, is the success condition. Ubuntu
# ships gh in `universe` frozen at 2.46.0, so `apt-get install gh` *succeeds*
# and leaves behind a build that aborts on `gh issue view --comments`,
# `gh issue edit` and `gh pr view/edit` — it asks GraphQL for the sunset
# Projects-classic field and treats the error as fatal. `apt upgrade` never
# repairs it either, because universe offers no newer candidate; only GitHub's
# official repo carries a current build.
install_system_packages() {
    local missing=() pkg
    if command -v apt-get >/dev/null 2>&1; then
        say "Installing the system packages (sudo password once)…"
        sudo apt-get update -qq || true
        sudo apt-get install -y -qq git gh 2>/dev/null || true
        if ! gh_version_ok; then
            say "Distro gh is absent or older than ${GH_MIN_STR} — installing from GitHub's official repo…"
            type -p wget >/dev/null || sudo apt-get install -y -qq wget
            sudo mkdir -p -m 755 /etc/apt/keyrings
            wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
            sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            sudo apt-get update -qq && sudo apt-get install -y -qq git gh
        fi
        while read -r pkg; do [ -z "${pkg}" ] || missing+=("${pkg}"); done < <(missing_apt_packages)
        if [ "${#missing[@]}" -gt 0 ]; then
            sudo apt-get install -y -qq "${missing[@]}" \
                || say "! Installing ${missing[*]} failed — the install step tries again."
        fi
        if want_az; then
            say "Installing azure-cli (Microsoft repo)…"
            curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash >/dev/null 2>&1 \
                || say "! azure-cli install failed — the SDK feed sign-in installs it."
        fi
    elif command -v brew >/dev/null 2>&1; then
        brew install git gh
    else
        echo "ERROR: need apt-get or brew to install git + gh." >&2; exit 1
    fi
    gh_version_ok || say "! gh is still below ${GH_MIN_STR} — \`gh issue view --comments\` and \`gh pr edit\` will fail. Run \`bd toolkit doctor\` after setup."
}

# ── 2. GitHub auth (SSH git protocol + the scopes the wizard needs) ──────────
# `-p ssh` makes git operations use SSH: gh walks the user through generating
# and uploading an SSH key (interactive) and sets git_protocol=ssh, so every
# later `gh repo clone <slug>` comes down as an SSH remote. `-w` keeps the token
# step browser-based, as before. Scopes: project + read:org for the board,
# user:email so the wizard can pre-fill the verified email for the git-identity
# step.
#
# `< /dev/tty` is essential: this script is run via `curl … | bash`, so stdin is
# the pipe carrying the script, not the keyboard. Without a TTY, gh can't show
# its interactive "Generate a new SSH key?" prompt, so it silently SKIPS key
# generation/upload (and never requests the admin:public_key scope) while still
# setting git_protocol=ssh — leaving every clone to fail with
# "Permission denied (publickey)". Redirecting stdin from the controlling
# terminal lets gh's SSH flow run exactly as it does when typed by hand.
#
# `gh auth setup-git` afterwards: Claude Code's marketplace clone of the private
# repo (and the plugin's background updates) need git credentials that never
# prompt.
#
# The sign-in is never skipped, not even for a BRYNQ_TOOLKIT_REPO_URL clone:
# setup.sh adds the Claude plugin's marketplace, a private GitHub repo.
GITHUB_REASON="Signing in to GitHub: the toolkit's Claude plugin comes from a private GitHub repository"

gh_signed_in() {
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

need_github_terminal() {
    can_ask || fail 20 "${GITHUB_REASON}. There is no terminal for gh auth login: run gh auth login yourself, then run this again."
}

github_sign_in() {
    if gh_signed_in; then
        say "Already signed in to GitHub."
    else
        need_github_terminal
        say "${GITHUB_REASON}."
        gh auth login -h github.com -p ssh -s project,read:org,user:email -w </dev/tty
    fi
    run_logged gh auth setup-git \
        || say "! gh auth setup-git failed — run it yourself, or the Claude plugin can't fetch the private repo."
}

# ── 3. Resolve the data-analytics base + clone/reuse the toolkit ────────────
# "major minor patch" of a version (a VERSION=… line or a bare 2.1.25+dev), else empty.
version_key() {
    printf '%s\n' "${1#VERSION=}" | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' | head -n 1
}

# True when $1 is older than $2. An unknown $2 is never newer; an unknown $1 is older than a known $2.
version_lt() {
    local x y
    x="$(version_key "$1")"
    y="$(version_key "$2")"
    [ -n "${y}" ] || return 1
    [ -n "${x}" ] || return 0
    # shellcheck disable=SC2086  # word-split into the six numbers on purpose
    set -- ${x} ${y}
    [ "$1" -lt "$4" ] && return 0
    [ "$1" -gt "$4" ] && return 1
    [ "$2" -lt "$5" ] && return 0
    [ "$2" -gt "$5" ] && return 1
    [ "$3" -lt "$6" ]
}

# A path under $HOME as ~/…, for messages.
home_path() {
    case "$1" in
        "${HOME}"/*) printf '~%s' "${1#"${HOME}"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The version in a checkout's VERSION file (2.1.13), or a ref's with $2, else empty.
checkout_version() {
    local line
    if [ -n "${2:-}" ]; then
        line="$(git -C "$1" show "$2:VERSION" 2>/dev/null | head -n 1 || true)"
    else
        line="$(head -n 1 "$1/VERSION" 2>/dev/null || true)"
    fi
    line="${line#VERSION=}"
    printf '%s' "${line%%[[:space:]]*}"
}

# Local mode (K3f rerun R2): the recorded checkout is the developer's, so it is
# never changed while it holds their work. It is updated only when it is older
# than --min-bd or than its source, and only when clean: no uncommitted changes,
# no untracked files (ignored ones are fine), no commits its source lacks. On a
# branch with an upstream: `git fetch` + `git merge --ff-only`; detached, or with
# BRYNQ_TOOLKIT_REPO_URL (a bundle, the E2E): the source's HEAD is checked out.
# Anything else stops with exit 20 before setup, with nothing changed (a fetch
# only moves remote-tracking refs).
update_local_checkout() {
    local have branch="" upstream="" target="" want="" shown reasons=()
    have="$(checkout_version "${DIR}")"
    shown="$(home_path "${DIR}")"
    branch="$(git -C "${DIR}" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [ -n "${BRYNQ_TOOLKIT_REPO_URL:-}" ]; then
        run_logged git -C "${DIR}" fetch --quiet "${BRYNQ_TOOLKIT_REPO_URL}" HEAD && target="FETCH_HEAD"
    elif [ -n "${branch}" ]; then
        upstream="$(git -C "${DIR}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
        if [ -n "${upstream}" ]; then
            run_logged git -C "${DIR}" fetch --quiet && target="${upstream}"
        fi
    else
        run_logged git -C "${DIR}" fetch --quiet origin HEAD && target="FETCH_HEAD"
    fi
    [ -z "${target}" ] || want="$(checkout_version "${DIR}" "${target}")"

    local too_old=0 behind=0
    if [ -n "${MIN_BD}" ] && version_lt "${have}" "${MIN_BD}"; then too_old=1; fi
    if [ -n "${want}" ] && version_lt "${have}" "${want}"; then behind=1; fi
    if [ "${too_old}" -eq 0 ] && [ "${behind}" -eq 0 ]; then
        if [ -z "${target}" ]; then
            say "Local mode: using your checkout ${DIR} as it is (could not check it against its source)."
        else
            say "Local mode: using your checkout ${DIR} as it is (${have:-unknown version}, current)."
        fi
        return 0
    fi

    local need="${MIN_BD}"
    [ -z "${want}" ] || ! version_lt "${need}" "${want}" || need="${want}"
    if [ -z "${target}" ]; then
        if [ -n "${branch}" ] && [ -z "${upstream}" ] && [ -z "${BRYNQ_TOOLKIT_REPO_URL:-}" ]; then
            fail 20 "Your toolkit checkout at ${shown} is at ${have:-an unknown version} (this install needs ${need} or newer) and its branch ${branch} has no upstream: update it yourself, then run this again."
        fi
        fail 40 "Your toolkit checkout at ${shown} is at ${have:-an unknown version} (this install needs ${need} or newer) and could not be fetched from its source: check your connection and GitHub sign-in, then run this again."
    fi
    if [ "${too_old}" -eq 1 ] && version_lt "${want}" "${MIN_BD}"; then
        fail 40 "Your toolkit checkout at ${shown} is at ${have:-an unknown version} and its source (${target}) only has ${want:-an unknown version}; this install needs ${MIN_BD} or newer: check out a newer toolkit yourself, then run this again."
    fi

    [ -z "$(git -C "${DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ] || reasons+=("uncommitted changes")
    [ -z "$(git -C "${DIR}" ls-files --others --exclude-standard 2>/dev/null)" ] || reasons+=("untracked files")
    if [ "$(git -C "${DIR}" rev-list --count HEAD --not "${target}" --remotes 2>/dev/null || echo 1)" != "0" ]; then
        reasons+=("unpushed commits")
    fi
    if [ "${#reasons[@]}" -gt 0 ]; then
        local list="${reasons[0]}" i
        for ((i = 1; i < ${#reasons[@]}; i++)); do
            if [ "${i}" -eq $((${#reasons[@]} - 1)) ]; then list+=" and ${reasons[i]}"; else list+=", ${reasons[i]}"; fi
        done
        fail 20 "Your toolkit checkout at ${shown} is at ${have:-an unknown version} (this install needs ${need} or newer) and has ${list}: commit or stash them (or update it yourself), then run this again."
    fi

    if [ -n "${upstream}" ] && [ -z "${BRYNQ_TOOLKIT_REPO_URL:-}" ]; then
        say "Local mode: updating your checkout ${DIR} from ${have:-an unknown version} to ${want} (fast-forward ${branch} to ${upstream})."
        run_logged git -C "${DIR}" merge --ff-only --quiet "${upstream}"
    else
        say "Local mode: updating your checkout ${DIR} from ${have:-an unknown version} to ${want} (checking out the source's HEAD)."
        run_logged git -C "${DIR}" checkout --quiet --detach "${target}"
    fi
}

# Flags of ours that `script` (setup.sh, install_prereqs.sh) does not know: a
# checkout older than the flag would stop at it ("Unknown argument").
unknown_flags() {
    local script="$1" flag
    shift
    for flag in "$@"; do
        grep -q -- "^[[:space:]]*${flag})" "${script}" 2>/dev/null || printf ' %s' "${flag}"
    done
}

# Sets DIR and LOCAL_CHECKOUT (the recorded local-mode checkout, else empty).
DIR=""
LOCAL_CHECKOUT=""
get_toolkit() {
    local base="${BRYNQ_DATA_ANALYTICS_BASE_PATH:-${DATA_ANALYTICS_BASE_PATH:-}}" found=""
    if [ -f "${HOME}/.brynq/orchestrator_config.json" ] || [ -f "${HOME}/.brynq/toolkit_mode.json" ]; then
        found="$(python3 - <<'PY' 2>/dev/null || true
import json, os
def load(name):
    p = os.path.expanduser("~/.brynq/" + name)
    try:
        return json.load(open(p)) if os.path.exists(p) else {}
    except ValueError:
        return {}
print((load("orchestrator_config.json").get("repo_to_dir") or {}).get("default") or "")
mode = load("toolkit_mode.json")
checkout = mode.get("checkout") or ""
print(checkout if mode.get("mode") == "local" and os.path.isdir(checkout) else "")
PY
)"
    fi
    [ -n "${base}" ] || base="$(printf '%s\n' "${found}" | sed -n 1p)"
    LOCAL_CHECKOUT="$(printf '%s\n' "${found}" | sed -n 2p)"
    base="${base:-$HOME/data_analytics}"
    base="${base/#\~/$HOME}"
    DIR="${base}/brynq-ai-toolkit"

    if [ -n "${LOCAL_CHECKOUT}" ]; then
        DIR="${LOCAL_CHECKOUT}"
        update_local_checkout
    elif [ -d "${DIR}/.git" ] && [ "${DEV}" -eq 1 ]; then
        say "--dev: using ${DIR} as it is (never pulled)."
    elif [ -d "${DIR}/.git" ]; then
        say "Updating existing clone at ${DIR}…"
        run_logged git -C "${DIR}" pull --ff-only || say "Could not fast-forward ${DIR}; continuing with it as it is."
    else
        say "Cloning the toolkit into ${DIR}…"
        mkdir -p "${base}"
        if [ -n "${BRYNQ_TOOLKIT_REPO_URL:-}" ]; then
            run_logged git clone "${BRYNQ_TOOLKIT_REPO_URL}" "${DIR}"
        else
            run_logged gh repo clone BrynQ/brynq-ai-toolkit "${DIR}"
        fi
    fi
}

# ── 4. uv + the Claude Code CLI (headless install only) ─────────────────────
install_uv_and_claude() {
    if command -v uv >/dev/null 2>&1; then
        say "uv already installed."
    else
        say "Installing uv…"
        run_logged bash -o pipefail -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
        command -v uv >/dev/null 2>&1 || fail 40 "uv installed but not found on PATH — open a new terminal and run this again."
    fi
    # Claude Code's own installer (native build, updates itself), never npm. A
    # Codex-only machine keeps its Codex-only setup (setup.sh's Codex branch).
    if command -v claude >/dev/null 2>&1; then
        say "Claude Code CLI already installed."
    elif command -v codex >/dev/null 2>&1; then
        say "codex found — Claude Code not installed (Codex-only setup). Add it later: curl -fsSL https://claude.ai/install.sh | bash"
    else
        say "Installing the Claude Code CLI…"
        run_logged bash -o pipefail -c 'curl -fsSL https://claude.ai/install.sh | bash'
        command -v claude >/dev/null 2>&1 || fail 40 "Claude Code installed but not found in ~/.local/bin — run this again."
    fi
}

# ── 6. SDK feed (headless install only) ─────────────────────────────────────
# Developers sign in to the Azure feed here (setup_uv.py: the feed is proven
# before uv.toml is written); a PM skips it. A skip is recorded in
# ~/.brynq/bootstrap-state.json so a re-run doesn't ask again and the app's
# first-run checklist offers the sign-in. Adds --no-azure to SETUP_ARGS when the
# feed won't be there.
STATE_FILE="${HOME}/.brynq/bootstrap-state.json"
SETUP_ARGS=()
FEED_QUESTION="Sign in to the SDK feed now (developers)? [Y/s=skip, I'm a PM]"

record_feed() {  # record_feed skipped | (no argument: clear the skip)
    python3 - "${STATE_FILE}" "${1:-}" <<'PY'
import json, os, sys, time
path, value = sys.argv[1], sys.argv[2]
try:
    state = json.load(open(path)) if os.path.exists(path) else {}
except ValueError:
    state = {}
if value:
    state["sdk_feed"] = {"state": value, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
else:
    state.pop("sdk_feed", None)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY
}

# U10: a PM install opens the dashboard in the PM view. "I'm a PM" is this
# run's feed skip (--no-sdk / BRYNQ_NO_SDK=1, or "s" at the question) without
# --dev. Only on a fresh install (no orchestrator_config.json when this run
# started) and only when ui_profile is unset, so an upgrade or a user's own
# choice is never touched. Developers leave it unset (= Dev).
PM_INSTALL=0
CONFIG_FILE="${HOME}/.brynq/orchestrator_config.json"
CONFIG_EXISTED=0

set_pm_profile() {
    [ "${PM_INSTALL}" -eq 1 ] && [ "${DEV}" -eq 0 ] && [ "${CONFIG_EXISTED}" -eq 0 ] || return 0
    python3 - "${CONFIG_FILE}" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    config = json.load(open(path)) if os.path.exists(path) else {}
except ValueError:
    sys.exit(0)  # not ours to repair; the app reports a broken config itself
if config.get("ui_profile"):
    sys.exit(0)
config["ui_profile"] = "pm"
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(config, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
    say "PM install: the dashboard opens in the PM view (Settings › General › Dashboard view to change)."
}

sdk_feed() {
    local setup_uv="${DIR}/agents/orchestrator/scripts/setup_uv.py"
    local uv_toml="${HOME}/.config/uv/uv.toml" configured=0
    grep -q "pkgs.dev.azure.com/brynq" "${uv_toml}" 2>/dev/null && configured=1
    if [ "${NO_SDK}" -eq 1 ]; then
        say "--no-sdk: skipping the SDK feed (the app's first-run checklist offers it later)."
        record_feed skipped
        PM_INSTALL=1
        SETUP_ARGS+=(--no-azure)
        return 0
    fi
    if [ "${configured}" -eq 1 ] && python3 "${setup_uv}" --check >/dev/null 2>&1; then
        say "SDK feed already signed in."
        [ ! -f "${STATE_FILE}" ] || record_feed
        return 0
    fi
    if grep -q '"state": "skipped"' "${STATE_FILE}" 2>/dev/null; then
        say "SDK feed skipped earlier — sign in from the app's first-run checklist, or: python3 ${setup_uv} --login"
        SETUP_ARGS+=(--no-azure)
        return 0
    fi
    can_ask || fail 20 "Set BRYNQ_NO_SDK=1 to answer: ${FEED_QUESTION}"
    ask "${FEED_QUESTION}"
    case "${ANSWER}" in
        [sS]|[sS][kK][iI][pP])
            say "Skipped — the app's first-run checklist offers the SDK feed later."
            record_feed skipped
            PM_INSTALL=1
            SETUP_ARGS+=(--no-azure)
            return 0
            ;;
    esac
    local rc=0
    if [ "${configured}" -eq 1 ]; then
        python3 "${setup_uv}" --login </dev/tty || rc=$?
    else
        python3 "${setup_uv}" </dev/tty || rc=$?
    fi
    if [ "${rc}" -eq 0 ]; then
        say "SDK feed signed in."
        [ ! -f "${STATE_FILE}" ] || record_feed
    else
        say "! The SDK feed sign-in did not finish — the toolkit installs without it; sign in later from the app or: python3 ${setup_uv} --login"
        SETUP_ARGS+=(--no-azure)
    fi
}

# ── main ────────────────────────────────────────────────────────────────────
# Everything runs from here, so a download cut off half-way runs nothing.
main() {
    parse_flags "$@"
    [ ! -f "${CONFIG_FILE}" ] || CONFIG_EXISTED=1
    setup_log
    export PATH="${HOME}/.local/bin:${PATH}"
    gh_signed_in || need_github_terminal
    if [ "${SIGN_IN_ONLY}" -eq 1 ]; then TOTAL=2; elif [ "${WIZARD}" -eq 1 ]; then TOTAL=5; else TOTAL=7; fi

    step "Installing the system packages" "install git and gh yourself (apt-get or brew), then run this again."
    if system_packages_missing; then
        run_logged install_system_packages
    else
        say "git, gh ${GH_MIN_STR}+ and the system packages already installed."
    fi

    step "Signing in to GitHub" "run gh auth login yourself, then run this again."
    github_sign_in
    if [ "${SIGN_IN_ONLY}" -eq 1 ]; then
        say "Signed in to GitHub. Log: ${LOG}"
        return 0
    fi

    step "Getting the toolkit" "check that GitHub is reachable and you have access to BrynQ/brynq-ai-toolkit, then run this again."
    get_toolkit

    if [ "${WIZARD}" -eq 1 ]; then
        step "Installing the system prerequisites" "run sudo bash ${DIR}/install_prereqs.sh and read its error."
        run_logged bash "${DIR}/install_prereqs.sh" || say "Some prerequisites failed — the wizard will flag them."
        step "Opening the setup wizard" "run bash ${DIR}/bootstrap.sh yourself."
        exec bash "${DIR}/bootstrap.sh"
    fi

    step "Installing uv and the Claude Code CLI" "check your internet connection, then run this again."
    install_uv_and_claude

    step "Installing the system prerequisites" "run sudo bash ${DIR}/install_prereqs.sh and read its error."
    local prereq_args=() unknown
    [ "${NO_SDK}" -eq 0 ] || prereq_args+=(--no-azure)  # az is only for the SDK feed
    unknown="$(unknown_flags "${DIR}/install_prereqs.sh" "${prereq_args[@]+"${prereq_args[@]}"}")"
    if [ -n "${unknown}" ]; then
        say "This checkout's install_prereqs.sh is older than${unknown}: running it without (it installs what it always did)."
        prereq_args=()
    fi
    run_logged bash "${DIR}/install_prereqs.sh" "${prereq_args[@]+"${prereq_args[@]}"}" </dev/null \
        || say "Some prerequisites failed — setup lists what is missing."

    step "SDK feed" "run python3 ${DIR}/agents/orchestrator/scripts/setup_uv.py --login, or run this again with --no-sdk."
    if [ "${DEV}" -eq 1 ]; then
        SETUP_ARGS+=(--developer)
    elif [ -n "${LOCAL_CHECKOUT}" ]; then
        say "Keeping local mode (setup.sh applies the recorded mode)."
    else
        SETUP_ARGS+=(--published)
    fi
    sdk_feed

    step "Setting up the toolkit" "fix what setup.sh printed above, then run this again."
    unknown="$(unknown_flags "${DIR}/setup.sh" "${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"}")"
    [ -z "${unknown}" ] || fail 20 "Your toolkit checkout at $(home_path "${DIR}") is at $(checkout_version "${DIR}"), whose setup.sh does not know${unknown}: update it (git pull, or check out a newer release), then run this again."
    run_logged bash "${DIR}/setup.sh" "${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"}" </dev/null
    set_pm_profile

    say "Toolkit installed. Log: ${LOG}"
}

main "$@"
