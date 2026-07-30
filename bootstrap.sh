#!/usr/bin/env bash
# BrynQ AI Toolkit — one-line remote bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash
#
# Fetches the toolkit and launches the setup wizard, in one command:
#   1. install git + gh (one sudo prompt), sign in to GitHub if needed
#   2. clone the private toolkit (reusing an existing clone if you have one)
#   3. install the remaining system prerequisites (sudo cached — no 2nd prompt)
#   4. run the toolkit's own bootstrap → opens the wizard at http://127.0.0.1:8421
#
# Contains no secrets. The private clone is gated by your GitHub login.
#
# CANONICAL SOURCE for BrynQ/toolkit-bootstrap/bootstrap.sh — the file the curl
# one-liner above actually fetches. Publish any edit to both, byte for byte.
set -euo pipefail

say() { echo "  $*"; }

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

# ── 1. git + gh (enough to authenticate + clone) ────────────────────────────
# The installed version, not apt's exit code, is the success condition. Ubuntu
# ships gh in `universe` frozen at 2.46.0, so `apt-get install gh` *succeeds*
# and leaves behind a build that aborts on `gh issue view --comments`,
# `gh issue edit` and `gh pr view/edit` — it asks GraphQL for the sunset
# Projects-classic field and treats the error as fatal. `apt upgrade` never
# repairs it either, because universe offers no newer candidate; only GitHub's
# official repo carries a current build.
if ! command -v git >/dev/null 2>&1 || ! gh_version_ok; then
    if command -v apt-get >/dev/null 2>&1; then
        say "Installing git + gh (sudo password once)…"
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
    elif command -v brew >/dev/null 2>&1; then
        brew install git gh
    else
        echo "ERROR: need apt-get or brew to install git + gh." >&2; exit 1
    fi
    gh_version_ok || say "! gh is still below ${GH_MIN_STR} — \`gh issue view --comments\` and \`gh pr edit\` will fail. Run \`bd toolkit doctor\` after setup."
fi

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
if ! gh auth status >/dev/null 2>&1; then
    say "Signing in to GitHub (SSH)…"
    gh auth login -h github.com -p ssh -s project,read:org,user:email -w < /dev/tty
fi

# ── 3. Resolve the data-analytics base + clone/reuse the toolkit ────────────
BASE="${BRYNQ_DATA_ANALYTICS_BASE_PATH:-${DATA_ANALYTICS_BASE_PATH:-}}"
if [ -z "${BASE}" ]; then
    BASE="$(python3 -c 'import json,os;p=os.path.expanduser("~/.brynq/orchestrator_config.json");d=json.load(open(p)) if os.path.exists(p) else {};print((d.get("repo_to_dir") or {}).get("default") or "")' 2>/dev/null || true)"
fi
BASE="${BASE:-$HOME/data_analytics}"
BASE="${BASE/#\~/$HOME}"
DIR="${BASE}/brynq-ai-toolkit"

if [ -d "${DIR}/.git" ]; then
    say "Updating existing clone at ${DIR}…"
    git -C "${DIR}" pull --ff-only || true
else
    say "Cloning the toolkit into ${DIR}…"
    mkdir -p "${BASE}"
    gh repo clone BrynQ/brynq-ai-toolkit "${DIR}"
fi

# ── 4. System prerequisites (sudo cached from step 1) + launch the wizard ───
if [ -f "${DIR}/install_prereqs.sh" ]; then
    bash "${DIR}/install_prereqs.sh" || say "Some prerequisites failed — the wizard will flag them."
fi
exec bash "${DIR}/bootstrap.sh"
