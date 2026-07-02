# BrynQ AI Toolkit — bootstrap

One command to install the [BrynQ AI Toolkit](https://github.com/BrynQ/brynq-ai-toolkit)
(private) and open its setup wizard. Run it in a WSL / Linux / macOS shell:

```bash
curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash
```

It installs `git` + `gh` (one sudo prompt), signs you into GitHub, clones the
toolkit (reusing an existing clone under your data-analytics path), installs the
remaining prerequisites, and launches the setup wizard at
`http://127.0.0.1:8421`, which walks you through the rest.

Fresh Windows first needs WSL: run `wsl --install` in an admin PowerShell, reboot,
create your Ubuntu user, then run the command above in the Ubuntu shell.

This script contains no secrets; access to the private toolkit is gated by your
GitHub login. It's the published copy of `bootstrap-remote.sh` in the toolkit repo.
