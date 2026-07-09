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

## Fresh Windows machine

Windows first needs WSL. In an **elevated** PowerShell (Run as administrator):

```powershell
irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap-windows.ps1 | iex
```

That enables the WSL + VirtualMachinePlatform Windows features and installs
Ubuntu. **Reboot**, launch **Ubuntu**, create your Linux user, then run the
`curl … | bash` command above in the Ubuntu shell.

(Equivalently, by hand: `dism.exe /online /enable-feature
/featurename:Microsoft-Windows-Subsystem-Linux /all /norestart`, the same for
`VirtualMachinePlatform`, then `wsl --install -d Ubuntu`.)

These scripts contain no secrets; access to the private toolkit is gated by your
GitHub login. `bootstrap.sh` is the published copy of `bootstrap-remote.sh` in
the toolkit repo; `bootstrap-windows.ps1` is the Windows-side prerequisite.
