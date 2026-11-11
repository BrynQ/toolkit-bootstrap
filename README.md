# BrynQ AI Toolkit — bootstrap

One command installs the [BrynQ AI Toolkit](https://github.com/BrynQ/brynq-ai-toolkit)
(private) and the BrynQ Toolkit desktop app; afterwards you only click its
icon. Safe to re-run: it installs or repairs only what is missing. A
**Developer** signs in to the SDK feed during the install, a **PM** skips it.

## Windows

In a **normal** PowerShell (not as administrator):

```powershell
irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/brynq.ps1 | iex
```

PM: run `$env:BRYNQ_NO_SDK = '1'` first, in the same window.

The toolkit runs in WSL only. The command turns WSL on if needed (one admin
prompt, one restart that resumes by itself), installs the toolkit in one named
distro, sets the GitHub bridge and the logon keep-alive, and installs the app.
It also offers to remove the old **BrynQ Agents** shortcut and
`BrynQ WSL keep-alive.vbs` from earlier installs. Check it in a WSL terminal:
`bd toolkit doctor`.

## macOS

```bash
curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/brynq.sh | bash
```

PM: `… | bash -s -- --no-sdk`. Check it in a new terminal: `bd toolkit doctor`.

## Linux / an existing WSL distro

```bash
curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash
```

## Retired commands

`shortcut.ps1` and `bootstrap-windows.ps1` now only print the `brynq.ps1`
command above; the desktop app replaces the shortcut and its keep-alive.

These scripts contain no secrets; access to the private toolkit is gated by
your GitHub login. Every file here is a published copy from the toolkit repo
(see `bootstrap/PUBLISH.md` there); don't edit them here.
