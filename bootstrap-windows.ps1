# BrynQ Toolkit - bootstrap-windows.ps1 is retired.
#
# It turned on WSL and installed Ubuntu in an elevated PowerShell, then left
# the rest (restart, Linux user, bootstrap.sh) to you. brynq.ps1 replaces it:
# one command in a normal PowerShell does all of that, resumes by itself after
# the restart, and installs and opens the BrynQ Toolkit app. Published to the
# public toolkit-bootstrap repo at merge (bootstrap/PUBLISH.md), so the old
# one-liner prints the new one. Changes nothing; ASCII and Windows PowerShell
# 5.1 (run through irm | iex: no `exit`).

Write-Host 'bootstrap-windows.ps1 is retired: one command now installs WSL, the toolkit and the BrynQ Toolkit app.'
Write-Host 'Run it in a normal PowerShell (not as administrator; it asks for admin rights once if WSL is missing):'
Write-Host ''
Write-Host '    irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/brynq.ps1 | iex'
Write-Host ''
