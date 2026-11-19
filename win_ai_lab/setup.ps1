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

# Windows editors may save the files with CRLF line endings. Inside '' strings the
# CR ends up in generated shell scripts (e.g. "fi\r"), which then fail to build.
# --exec runs the command without a shell (so the arguments arrive unchanged) and
# without NixOS' PATH, hence the absolute paths.
$sw = '/run/current-system/sw/bin'
wsl.exe -d $distroName -u root --exec "$sw/find" /etc/nixos -name '*.nix' -exec "$sw/sed" -i 's/\r$//' '{}' '+'
if ($LASTEXITCODE -ne 0) { throw "Converting line endings failed (exit code $LASTEXITCODE)" }

# Windows folder shared read/write with the user "agent" (mounted at /mnt/aivm).
# windows-isolation.nix reads its Windows path from /etc/nixos/aivm-path.
$aivmDir = Join-Path $env:USERPROFILE 'aivm'
New-Item -ItemType Directory -Path $aivmDir -Force | Out-Null
Write-Host "Writing /etc/nixos/aivm-path ($aivmDir) ..."
$OutputEncoding = New-Object System.Text.UTF8Encoding $false   # no BOM, keeps non-ASCII names
$aivmDir | wsl.exe -d $distroName -u root -- tee /etc/nixos/aivm-path | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Writing aivm-path failed (exit code $LASTEXITCODE)" }

# Build the new configuration and make it the boot default.
# The CUDA cache is passed on the command line: the nix.settings in gpu-llama.nix
# only take effect after this build. Without it, llama.cpp (CUDA) is compiled locally.
Write-Host "Running nixos-rebuild boot ..."
wsl.exe -d $distroName -u root -- nixos-rebuild boot `
    --option extra-substituters https://cache.nixos-cuda.org `
    --option extra-trusted-public-keys 'cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M='
if ($LASTEXITCODE -ne 0) { throw "nixos-rebuild failed (exit code $LASTEXITCODE)" }

# Two restarts are needed. WSL reads /etc/wsl.conf (default user, automount root
# /win, interop) when the instance starts, before NixOS activates. On the first
# start the new generation activates and writes the new wsl.conf, but this start
# still ran with the old one (drives under /mnt/c, ...). Only the second start
# runs fully with the new config. Use --shutdown, not --terminate (see
# configuration.nix); it stops all running WSL distros.
Write-Host "Activating the new configuration (restart 1/2) ..."
wsl.exe --shutdown
wsl.exe -d $distroName -u root -- true
if ($LASTEXITCODE -ne 0) { throw "First start failed (exit code $LASTEXITCODE)" }

Write-Host "Restarting with the new wsl.conf (restart 2/2) ..."
wsl.exe --shutdown
Write-Host "Done. Start it with: wsl -d $distroName"

