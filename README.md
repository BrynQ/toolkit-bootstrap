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

## Desktop shortcut (Windows, optional)

Once the toolkit is installed, this puts a **BrynQ Agents** shortcut on your
desktop. In a **normal** PowerShell — no administrator rights needed:

```powershell
irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/shortcut.ps1 | iex
```

Clicking it starts the dashboard inside a tmux session named `agents` and
attaches to it. Closing the window leaves the dashboard running; clicking again
re-attaches to the same session rather than starting a second one. Detach without
stopping it with `Ctrl-b` then `d`.

It also installs a **WSL keep-alive anchor** at logon (a hidden `.vbs` in your
Startup folder). This is not optional dressing — WSL terminates a distro when its
last session closes, which takes the tmux *server* down with it, so without the
anchor closing the window kills the dashboard and every agent session. Note that
the `.wslconfig` idle-timeout settings most write-ups recommend do **not** fix
this: they govern the VM, not the distro instance
([microsoft/WSL#9245](https://github.com/microsoft/WSL/discussions/9245)).
Deleting the `.vbs` disables the anchor.

Equivalent to typing `agents` in a WSL shell (the function `setup.sh` installs
in your `~/.bashrc`) — the shortcut just saves opening a terminal first. Safe to
re-run; it overwrites the same shortcut.

These scripts contain no secrets; access to the private toolkit is gated by your
GitHub login. `bootstrap.sh` is the published copy of `bootstrap-remote.sh` in
the toolkit repo; `bootstrap-windows.ps1` is the Windows-side prerequisite;
`shortcut.ps1` is authoritative here (it has no toolkit-internal dependencies).
