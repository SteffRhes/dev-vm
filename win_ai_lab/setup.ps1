#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # much faster downloads in 5.1

# GitHub requires TLS 1.2; 5.1 on older .NET may not enable it by default
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}


# download

$url      = 'https://github.com/nix-community/NixOS-WSL/releases/download/2605.7.2/nixos.wsl'
$dir      = Join-Path ([System.IO.Path]::GetTempPath()) 'nixos-wsl'
$file     = Join-Path $dir (Split-Path $url -Leaf)
$partFile = "$file.part"

if (Test-Path -LiteralPath $file -PathType Leaf) {
    Write-Host "Already present: $file"
}
else {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host "Downloading $url ..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $partFile -UseBasicParsing
        Move-Item -LiteralPath $partFile -Destination $file -Force
    }
    catch {
        Remove-Item -LiteralPath $partFile -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "Saved to $file"
}


# install wsl instance

$distroName = 'aivm'
$distroDir  = Join-Path $env:LOCALAPPDATA "wsl\$distroName"

# Remove the existing instance, if there is one
$lxss   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$exists = Get-ChildItem -Path $lxss -ErrorAction SilentlyContinue |
          Where-Object { (Get-ItemProperty -Path $_.PSPath).DistributionName -eq $distroName }

if ($exists) {
    Write-Host "Removing existing WSL distribution '$distroName' ..."
    wsl.exe --unregister $distroName
    if ($LASTEXITCODE -ne 0) { throw "wsl --unregister failed (exit code $LASTEXITCODE)" }
}

# Remove leftovers, e.g. a disk image from an aborted earlier run
if (Test-Path -LiteralPath $distroDir) {
    Remove-Item -LiteralPath $distroDir -Recurse -Force
}
New-Item -ItemType Directory -Path $distroDir -Force | Out-Null

Write-Host "Installing '$distroName' from $file ..."
wsl.exe --install --from-file $file --name $distroName --location $distroDir --no-launch
if ($LASTEXITCODE -ne 0) { throw "wsl --install failed (exit code $LASTEXITCODE)" }
Write-Host "Done. Start it with: wsl -d $distroName"


# set up nixos

# Source folder: .\nix next to the script, so it works from any current directory
$srcDir = Join-Path $PSScriptRoot 'nix'
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    throw "Source folder not found: $srcDir"
}

# Copy the folder contents (including dotfiles) into /etc/nixos, overwriting existing files
Write-Host "Copying $srcDir to /etc/nixos/ in '$distroName' ..."
wsl.exe -d $distroName -u root --cd $srcDir -- cp -r ./. /etc/nixos/
if ($LASTEXITCODE -ne 0) { throw "Copy failed (exit code $LASTEXITCODE)" }

# Windows folder shared read/write with the user "agent" (mounted at /mnt/aivm).
# windows-isolation.nix reads its Windows path from /etc/nixos/aivm-path.
$aivmDir = Join-Path $env:USERPROFILE 'aivm'
New-Item -ItemType Directory -Path $aivmDir -Force | Out-Null
Write-Host "Writing /etc/nixos/aivm-path ($aivmDir) ..."
$OutputEncoding = New-Object System.Text.UTF8Encoding $false   # no BOM, keeps non-ASCII names
$aivmDir | wsl.exe -d $distroName -u root -- tee /etc/nixos/aivm-path | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Writing aivm-path failed (exit code $LASTEXITCODE)" }

# Build the new configuration and make it the boot default
Write-Host "Running nixos-rebuild boot ..."
wsl.exe -d $distroName -u root -- nixos-rebuild boot
if ($LASTEXITCODE -ne 0) { throw "nixos-rebuild failed (exit code $LASTEXITCODE)" }

# 'boot' only takes effect at the next start, so stop the instance now
wsl.exe --terminate $distroName

