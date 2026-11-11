#!/usr/bin/env bash
# BrynQ Toolkit — one-command install for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/brynq.sh | bash
#   curl -fsSL …/brynq.sh | bash -s -- [--dev] [--no-sdk]
#
# Installs what is missing and opens the BrynQ Toolkit app; afterwards you only
# click its icon. Safe to re-run: on a ready Mac it changes nothing and opens the
# app.
#   1. Xcode Command Line Tools (git, python3)
#   2. Homebrew (asks first; needs an admin account) — tmux and the other
#      prerequisites come from it
#   3. the toolkit: bootstrap.sh --no-wizard (git + gh, GitHub sign-in, Claude
#      Code CLI, SDK feed sign-in, setup.sh in published mode)
#   4. the BrynQ Toolkit app into /Applications (bd toolkit desktop install)
#   5. open it (bd toolkit desktop open)
#
# --dev        You develop the toolkit itself (skills and bd from the checkout).
# --no-sdk     Skip the SDK feed sign-in ("I'm a PM"); the app offers it later.
# --uninstall  Remove the app (asks first), then ask before deleting ~/.brynq
#              (settings, credentials, logs). Same as BRYNQ_ACTION=uninstall.
#              bd, the toolkit checkout, the Claude plugin and Homebrew stay.
#              Test-mode answers: BRYNQ_UNINSTALL=yes|no,
#              BRYNQ_REMOVE_BRYNQ_HOME=yes|no.
#
# Test mode (environment): BRYNQ_BOOTSTRAP_NONINTERACTIVE=1 never asks (a
# question without an answer exits 20 naming the variable that answers it, e.g.
# BRYNQ_INSTALL_HOMEBREW=1); BRYNQ_BOOTSTRAP_BASE_URL is where bootstrap.sh is
# fetched from (file://… works); BRYNQ_TOOLKIT_REPO_URL is passed on.
#
# Exit codes: 0 done (uninstall: also declined), 1 uninstall could not remove
# something, 2 bad flags / not macOS, 13 Homebrew needs an admin
# account (or was declined), 14 Xcode Command Line Tools missing, 20 a question
# needs an answer (or the GitHub sign-in needs a terminal: the toolkit's Claude
# plugin comes from a private GitHub repository), 40 the toolkit setup failed,
# 50 app install failed, 51 app did not open, 52 /Applications not writable.
# Log: ~/.brynq/logs/brynq-<time>.log (bootstrap.sh writes into the same file).
set -Eeuo pipefail

APPS_DIR="/Applications"
BREW_CANDIDATES="/opt/homebrew/bin/brew /usr/local/bin/brew"
BASE_URL="${BRYNQ_BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main}"
APP_BUNDLE="BrynQ Toolkit.app"
CLT_WAIT_ROUNDS=180   # x 10 s = 30 min for the Command Line Tools installer

say() { echo "  $*"; [ -z "${LOG:-}" ] || echo "  $*" >>"${LOG}"; }

DEV=0
NO_SDK=0
ACTION="${BRYNQ_ACTION:-install}"
parse_flags() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --dev) DEV=1 ;;
            --no-sdk) NO_SDK=1 ;;
            --uninstall) ACTION=uninstall ;;
            -h|--help) sed -n '2,37p' "${BASH_SOURCE[0]:-/dev/null}" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "Unknown argument: ${arg} (try --help)" >&2; exit 2 ;;
        esac
    done
    case "${ACTION}" in
        install) ;;
        uninstall)
            if [ "${DEV}" -eq 1 ] || [ "${NO_SDK}" -eq 1 ]; then
                echo "--uninstall takes no other flag" >&2
                exit 2
            fi ;;
        *) echo "BRYNQ_ACTION '${ACTION}' is not known: use install (the default) or uninstall." >&2; exit 2 ;;
    esac
}

NONINTERACTIVE=0
[ "${BRYNQ_BOOTSTRAP_NONINTERACTIVE:-}" = "1" ] && NONINTERACTIVE=1

can_ask() {
    [ "${NONINTERACTIVE}" -eq 0 ] && { : </dev/tty; } 2>/dev/null
}

ANSWER=""
ask() {
    ANSWER=""
    read -r -p "    $1 " ANSWER </dev/tty || ANSWER=""
}

LOG=""
STEP=0
TOTAL=5
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

on_err() {
    local rc=$?
    [ "${BASH_SUBSHELL}" -eq 0 ] || exit "${rc}"
    trap - ERR
    fail 40 "Step ${STEP}/${TOTAL} (${STEP_NAME}) failed: ${STEP_HINT}"
}
trap on_err ERR

# ── 1. Xcode Command Line Tools ─────────────────────────────────────────────
# /usr/bin/git is a shim that opens an install dialog when the tools are
# missing, so `command -v git` proves nothing: `xcode-select -p` does.
ensure_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        say "Xcode Command Line Tools already installed."
        return 0
    fi
    xcode-select --install >/dev/null 2>&1 || true
    say "A macOS window asks to install the Command Line Tools: click Install. This waits until it is done."
    local i=0
    while [ "${i}" -lt "${CLT_WAIT_ROUNDS}" ]; do
        sleep 10
        if xcode-select -p >/dev/null 2>&1; then
            say "Xcode Command Line Tools installed."
            return 0
        fi
        i=$((i + 1))
    done
    fail 14 "The Xcode Command Line Tools are not installed yet — finish xcode-select --install, then run this again."
}

# ── 2. Homebrew ─────────────────────────────────────────────────────────────
find_brew() {
    local b
    command -v brew >/dev/null 2>&1 && return 0
    for b in ${BREW_CANDIDATES}; do
        if [ -x "${b}" ]; then
            eval "$("${b}" shellenv)"
            return 0
        fi
    done
    return 1
}

ensure_brew() {
    if find_brew; then
        say "Homebrew already installed."
        return 0
    fi
    local groups
    groups=" $(id -Gn) "
    if [[ "${groups}" != *" admin "* ]]; then
        fail 13 "Homebrew needs an admin account. Ask IT to install Homebrew (https://brew.sh), then run this again."
    fi
    if [ "${BRYNQ_INSTALL_HOMEBREW:-}" != "1" ]; then
        can_ask || fail 20 "Set BRYNQ_INSTALL_HOMEBREW=1 to answer: Install Homebrew?"
        ask "Homebrew is needed (tmux and the other tools come from it). Install it now? It asks for your password. [Y/n]"
        case "${ANSWER}" in
            [nN]|[nN][oO]) fail 13 "Homebrew is needed. Install it from https://brew.sh (or ask IT), then run this again." ;;
        esac
    fi
    say "Installing Homebrew…"
    local installer rc=0
    installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || fail 13 "Could not download the Homebrew installer — check your internet connection, then run this again."
    if [ "${NONINTERACTIVE}" -eq 1 ]; then
        NONINTERACTIVE=1 /bin/bash -c "${installer}" </dev/null || rc=$?
    else
        /bin/bash -c "${installer}" </dev/tty || rc=$?
    fi
    [ "${rc}" -eq 0 ] || fail 13 "The Homebrew installer failed (exit ${rc}) — install it from https://brew.sh, then run this again."
    find_brew || fail 13 "Homebrew installed but brew is not found — open a new terminal and run this again."
}

# ── uninstall ───────────────────────────────────────────────────────────────
# Nothing is removed without a yes: y/yes typed at the terminal (Enter keeps),
# or in test mode the answer variable (a missing one: exit 20 before anything
# is removed). No log file: ~/.brynq may be the thing that goes.

# yes_answer VAR QUESTION: returns 0 on yes, 1 on no.
yes_answer() {
    local var="$1" question="$2" value
    value="$(printf '%s' "${!var:-}" | tr '[:upper:]' '[:lower:]')"
    case "${value}" in
        yes) return 0 ;;
        no) return 1 ;;
    esac
    if ! can_ask; then
        echo "✗ Set ${var}=yes or no to answer: ${question}" >&2
        exit 20
    fi
    ask "${question} [y/N]"
    case "${ANSWER}" in
        [yY]|[yY][eE][sS]|[jJ]|[jJ][aA]) return 0 ;;
    esac
    return 1
}

uninstall() {
    local b apps="" brynq_home="${HOME}/.brynq" remove_apps=0 remove_home=0 failed=0
    for b in "${APPS_DIR}/${APP_BUNDLE}" "${HOME}/Applications/${APP_BUNDLE}"; do
        [ ! -d "${b}" ] || apps="${apps}${b}"$'\n'
    done
    echo "Uninstall BrynQ Toolkit (macOS)."
    if [ -z "${apps}" ] && [ ! -d "${brynq_home}" ]; then
        echo "  Nothing of BrynQ Toolkit was found."
        return 0
    fi
    # Every question first.
    if [ -n "${apps}" ]; then
        printf '  The app: %s' "${apps}" | tr '\n' ' '
        echo
        if yes_answer BRYNQ_UNINSTALL "Remove the BrynQ Toolkit app (quit it first)?"; then remove_apps=1; fi
    fi
    if [ -d "${brynq_home}" ]; then
        if yes_answer BRYNQ_REMOVE_BRYNQ_HOME "Also delete ${brynq_home}? It holds your BrynQ settings and credentials, the toolkit release clone and the logs."; then
            remove_home=1
        fi
    fi
    if [ "${remove_apps}" -eq 0 ] && [ "${remove_home}" -eq 0 ]; then
        echo "Nothing was removed."
        return 0
    fi
    if [ "${remove_apps}" -eq 1 ]; then
        while IFS= read -r b; do
            [ -n "${b}" ] || continue
            if rm -rf "${b}"; then
                say "Removed ${b}"
            else
                echo "✗ Could not remove ${b} — drag it to the Bin (it may need an admin password)." >&2
                failed=1
            fi
        done <<<"${apps}"
    fi
    if [ "${remove_home}" -eq 1 ]; then
        if rm -rf "${brynq_home}"; then
            say "Removed ${brynq_home}"
        else
            echo "✗ Could not remove ${brynq_home} completely." >&2
            failed=1
        fi
    fi
    say "Kept: bd (~/.local/bin/bd), the toolkit checkout, the Claude plugin (BrynQ manages it) and Homebrew with its tools."
    [ "${failed}" -eq 0 ] || return 1
    echo "BrynQ Toolkit is removed."
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    parse_flags "$@"
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "brynq.sh is for macOS. Linux / WSL: curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash -s -- --no-wizard" >&2
        exit 2
    fi
    if [ "${ACTION}" = uninstall ]; then
        trap - ERR
        local rc=0
        uninstall || rc=$?
        exit "${rc}"
    fi
    LOG="${BRYNQ_BOOTSTRAP_LOG:-${HOME}/.brynq/logs/brynq-$(date +%Y%m%d-%H%M%S).log}"
    mkdir -p "$(dirname "${LOG}")"
    touch "${LOG}"
    export BRYNQ_BOOTSTRAP_LOG="${LOG}"

    # The app goes to /Applications (an existing copy in ~/Applications is
    # updated there). Checked first, so nothing is installed for an app that
    # can't land; never a silent ~/Applications fallback.
    if [ ! -d "${HOME}/Applications/${APP_BUNDLE}" ] && [ ! -w "${APPS_DIR}" ]; then
        fail 52 "Your account cannot write ${APPS_DIR}; use an admin account, or move an existing ${APP_BUNDLE} to ~/Applications and run this again."
    fi

    step "Xcode Command Line Tools" "run xcode-select --install, then run this again."
    ensure_clt

    step "Homebrew" "install Homebrew from https://brew.sh, then run this again."
    ensure_brew

    step "Installing the toolkit" "fix the step bootstrap.sh named above, then run this again."
    local script="${HOME}/.brynq/bootstrap/bootstrap.sh" rc=0
    mkdir -p "$(dirname "${script}")"
    curl -fsSL "${BASE_URL}/bootstrap.sh" -o "${script}" \
        || fail 40 "Could not download ${BASE_URL}/bootstrap.sh — check your internet connection, then run this again."
    local args=(--no-wizard)
    [ "${DEV}" -eq 0 ] || args+=(--dev)
    [ "${NO_SDK}" -eq 0 ] || args+=(--no-sdk)
    bash "${script}" "${args[@]}" </dev/null || rc=$?
    case "${rc}" in
        0) ;;
        20) exit 20 ;;
        *) fail 40 "The toolkit setup failed (bootstrap.sh exit ${rc}) — fix the step it named above, then run this again." ;;
    esac
    export PATH="${HOME}/.local/bin:${PATH}"
    command -v bd >/dev/null 2>&1 || fail 40 "bd is not in ~/.local/bin after the toolkit setup — run bash ${script} --no-wizard and read its summary."

    step "Installing the BrynQ app" "see bd toolkit desktop status."
    if ! bd toolkit desktop install 2>&1 | tee -a "${LOG}"; then
        bd toolkit desktop status 2>&1 | tee -a "${LOG}" >&2 || true
        fail 50 "The BrynQ app did not install (status above) — run bd toolkit desktop install again."
    fi

    step "Opening the BrynQ app" "run bd toolkit desktop open."
    if ! bd toolkit desktop open 2>&1 | tee -a "${LOG}"; then
        fail 51 "The BrynQ app did not open — run bd toolkit desktop open (bd toolkit desktop status shows the install)."
    fi

    echo "BrynQ Toolkit is open. From now on use the BrynQ Toolkit icon."
    echo "BrynQ Toolkit is open." >>"${LOG}"
}

main "$@"
