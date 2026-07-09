<#
    BrynQ AI Toolkit - Windows prerequisite bootstrap.

    Run this ONCE in an *elevated* PowerShell (Run as administrator) on a fresh
    Windows machine that doesn't have WSL yet. It:
      1. enables the "Windows Subsystem for Linux" Windows feature,
      2. enables "VirtualMachinePlatform" (required for WSL 2),
      3. installs WSL + the Ubuntu distro.

    One-liner (elevated PowerShell):
        irm https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap-windows.ps1 | iex

    After it finishes: REBOOT, launch "Ubuntu" from the Start menu, create your
    Linux username/password at the first-run prompt, then run the toolkit
    bootstrap inside that Ubuntu shell:

        curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash

    Contains no secrets; access to the private toolkit is gated by your GitHub login.
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "  -> $msg" -ForegroundColor Cyan }

# Must be elevated: dism feature-enable needs administrator rights.
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run in an ELEVATED PowerShell (Run as administrator)."
    exit 1
}

Write-Host "BrynQ AI Toolkit - Windows bootstrap" -ForegroundColor Green

# 1. Windows Subsystem for Linux feature (no restart yet; we batch the reboot).
Write-Step "Enabling Microsoft-Windows-Subsystem-Linux ..."
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart

# 2. Virtual Machine Platform - required for WSL 2.
Write-Step "Enabling VirtualMachinePlatform (WSL 2 requirement) ..."
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# 3. Install WSL + the chosen distro. On modern Windows `wsl --install` also sets
#    WSL 2 as the default and downloads the kernel; on older builds the dism
#    features above are what make it work after a reboot.
Write-Step "Installing WSL + $Distro ..."
wsl.exe --install -d $Distro

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. REBOOT Windows." -ForegroundColor Yellow
Write-Host "  2. Launch '$Distro' from the Start menu and create your Linux user." -ForegroundColor Yellow
Write-Host "  3. In the Ubuntu shell, run the toolkit bootstrap:" -ForegroundColor Yellow
Write-Host "       curl -fsSL https://raw.githubusercontent.com/BrynQ/toolkit-bootstrap/main/bootstrap.sh | bash" -ForegroundColor Yellow
