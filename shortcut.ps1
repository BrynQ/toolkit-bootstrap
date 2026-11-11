# BrynQ Toolkit - shortcut.ps1 is retired.
#
# It made the "BrynQ Agents" desktop shortcut and a keep-alive in the Startup
# folder. The BrynQ Toolkit app replaces both: one command installs it (and
# removes the old shortcut and keep-alive after asking). Published to the
# public toolkit-bootstrap repo at merge, so the old one-liner prints the new
# one instead of making the old files again. Changes nothing; ASCII and
# Windows PowerShell 5.1 (run through irm | iex: no `exit`).

Write-Host 'shortcut.ps1 is retired: the BrynQ Toolkit app replaces the BrynQ Agents shortcut.'
Write-Host 'Install it (and remove the old shortcut and keep-alive) with, in a normal PowerShell:'
Write-Host ''
Write-Host '    irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/brynq.ps1 | iex'
Write-Host ''
