# Sets up the NixOS-WSL AI-lab VM on a Windows host with an NVIDIA GPU.
#
# Run from PowerShell (as Administrator, first time) on the Windows host:
#   .\setup-vm.ps1
#
# Prerequisite: WSL >= 2.4.4 (`wsl --version`), for `wsl --install --from-file`.
# If WSL itself isn't installed yet: wsl --install --no-distribution
#
# What it does:
#   1. Downloads the latest NixOS-WSL release.
#   2. Unregisters any existing distro of the same name (throwaway: always a clean install).
#   3. Installs the fresh image, boots it once.
#   4. Copies .\nix\* into the VM at /etc/nixos.
#   5. Adds the nixos-unstable channel (needed for opencode.nix) and runs nixos-rebuild boot,
#      with the CUDA cache passed on the command line (not yet trusted by the base config).
#   6. Activates the new generation (root, no sudo; switches the default user to "agent").
#
# After this, use:
#   wsl -d NixOS-AI-Lab              # user "agent", no root rights
#   wsl -d NixOS-AI-Lab -u root      # root, for admin work / nixos-rebuild
# Restart with `wsl --shutdown`, not `wsl -t`, see windows-isolation.nix.

$ErrorActionPreference = "Stop"

$DistroName = "NixOS-AI-Lab"
$InstallDir = Join-Path $env:LOCALAPPDATA $DistroName
$NixDir = Join-Path $PSScriptRoot "nix"
$Repo = "nix-community/NixOS-WSL"

Write-Host "Fetching latest NixOS-WSL release info..."
$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
$image = $release.assets | Where-Object { $_.name -eq "nixos.wsl" }
$checksum = $release.assets | Where-Object { $_.name -eq "nixos.wsl.sha256" }
if (-not $image -or -not $checksum) {
    throw "Could not find nixos.wsl / nixos.wsl.sha256 in release $($release.tag_name)"
}

$wslFile = Join-Path $env:TEMP "nixos-$($release.tag_name).wsl"
$checksumFile = "$wslFile.sha256"
Write-Host "Downloading $($release.tag_name) -> $wslFile"
Invoke-WebRequest -Uri $image.browser_download_url -OutFile $wslFile -UseBasicParsing
Invoke-WebRequest -Uri $checksum.browser_download_url -OutFile $checksumFile -UseBasicParsing
$expectedHash = (Get-Content $checksumFile -Raw).Split()[0]
$actualHash = (Get-FileHash -Path $wslFile -Algorithm SHA256).Hash
if ($actualHash.ToLower() -ne $expectedHash.ToLower()) {
    throw "Checksum mismatch for $wslFile`nexpected: $expectedHash`nactual:   $actualHash"
}

$existing = wsl --list --quiet 2>$null
if ($existing -contains $DistroName) {
    Write-Host "Unregistering existing $DistroName"
    wsl --unregister $DistroName
}

Write-Host "Installing $DistroName into $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
# --import (not --install --from-file): the latter auto-launches an interactive
# first-run shell after installing, which a non-interactive script can't use.
wsl --import $DistroName $InstallDir $wslFile --version 2
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

Write-Host "Booting $DistroName for the first time"
wsl -d $DistroName -- true
if ($LASTEXITCODE -ne 0) { throw "first boot of $DistroName failed" }

# Copy as root, from the already-mounted Windows drive (/mnt/c/...): /etc/nixos
# is root-owned, and the Windows-side \\wsl.localhost\... share is only reachable
# as the unprivileged default user, so Copy-Item there would fail with "access denied".
Write-Host "Copying nix config into /etc/nixos"
$wslNixDir = (wsl -d $DistroName -- wslpath -a "$NixDir").Trim()
wsl -d $DistroName -u root -- bash -lc "cp -f '$wslNixDir'/* /etc/nixos/"
if ($LASTEXITCODE -ne 0) { throw "copying nix config failed" }

Write-Host "Adding nixos-unstable channel and rebuilding (this takes a while on first run)"
$rebuildScript = @'
set -e
nix-channel --add https://channels.nixos.org/nixos-unstable nixos-unstable
nix-channel --update
nixos-rebuild boot \
  --option extra-substituters https://cache.nixos-cuda.org \
  --option extra-trusted-public-keys cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=
'@
wsl -d $DistroName -u root -- bash -lc $rebuildScript
if ($LASTEXITCODE -ne 0) { throw "nixos-rebuild failed" }

Write-Host "Activating new generation"
wsl --shutdown
wsl -d $DistroName -u root -- exit
wsl --shutdown

Write-Host "Done. 'wsl -d $DistroName' -> user agent, 'wsl -d $DistroName -u root' -> root."
