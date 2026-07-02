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
set -euo pipefail

say() { echo "  $*"; }

# ── 1. git + gh (enough to authenticate + clone) ────────────────────────────
if ! command -v git >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        say "Installing git + gh (sudo password once)…"
        sudo apt-get update -qq || true
        sudo apt-get install -y -qq git gh 2>/dev/null || {
            # gh may not be in the distro repo → add the official one.
            sudo mkdir -p -m 755 /etc/apt/keyrings
            wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
            sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            sudo apt-get update -qq && sudo apt-get install -y -qq git gh
        }
    elif command -v brew >/dev/null 2>&1; then
        brew install git gh
    else
        echo "ERROR: need apt-get or brew to install git + gh." >&2; exit 1
    fi
fi

# ── 2. GitHub auth (also grants the board scopes the wizard needs) ───────────
if ! gh auth status >/dev/null 2>&1; then
    say "Signing in to GitHub…"
    gh auth login -h github.com -s project,read:org -w
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
