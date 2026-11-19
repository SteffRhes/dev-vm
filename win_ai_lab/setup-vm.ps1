#Requires -Version 5.1

<#
.SYNOPSIS
    Installs NixOS-WSL as the "AI lab" VM and applies the NixOS configuration from .\nix.

.DESCRIPTION
    What it does, in order:

      1. checks WSL on the host
      2. resolves a NixOS-WSL release and downloads its image (cached, sha256-verified)
      3. registers the distro with `wsl --import`
      4. sets up the nix channels: nixos, nixos-wsl (pinned to the installed release)
         and nixos-unstable (needed by nix/opencode.nix)
      5. copies *.nix from .\nix into /etc/nixos as root (each file verified by sha256)
      6. runs `nixos-rebuild boot` with the CUDA binary cache, then the
         shutdown / activate / shutdown dance that makes the new default user
         "agent" effective (see nix/users.nix and nix/configuration.nix)

    Everything inside the VM runs via `wsl -u root`, which keeps working after
    nix/users.nix has removed sudo. Config files are piped in as base64 over stdin,
    so the copy does not depend on Windows interop or on the drive mounts, both of
    which nix/windows-isolation.nix locks down.

    Re-runs: use -UpdateOnly to push changed config files into the existing distro and
    rebuild, or -Force to throw the distro away and install from scratch.

.PARAMETER Distro
    Name the distro is registered under in WSL. Default: NixOS-AI-Lab.

.PARAMETER Release
    NixOS-WSL release tag, e.g. 2605.7.2, or "latest" (default).

.PARAMETER NixDir
    Directory with the *.nix files to copy to /etc/nixos. Default: .\nix next to this script.

.PARAMETER InstallDir
    Where WSL puts the disk image. Default: %LOCALAPPDATA%\WSL\<Distro>.

.PARAMETER DownloadDir
    Cache directory for downloaded images. Default: %LOCALAPPDATA%\NixOS-WSL.

.PARAMETER ImageFile
    Use this local .wsl image instead of downloading one. The release is then unknown,
    so the nixos-wsl channel keeps the image's default (the release branch, not a tag).

.PARAMETER RebuildMode
    boot, switch or none. Default: boot for a fresh install, switch with -UpdateOnly.
    A fresh install needs "boot": the default user changes and sudo disappears, so the
    new generation must be activated by a restart rather than in the running system.

.PARAMETER UpdateOnly
    Skip download and import; only copy the config files into an existing distro and rebuild.

.PARAMETER Force
    Delete an existing distro of the same name (destroys its disk image) and install fresh.

.PARAMETER UpdateChannels
    Run `nix-channel --update` even when no channel had to be added (-UpdateOnly runs).

.PARAMETER DisableGuiApplications
    Set [wsl2] guiApplications=false in %USERPROFILE%\.wslconfig. Recommended by
    nix/windows-isolation.nix: it turns off WSLg (no clipboard/GUI access, ~1 GB VRAM back).
    Affects all distros on this machine, so it is opt-in.

.PARAMETER NonInteractive
    Never prompt. Combined with -Force this deletes the existing distro without asking.

.PARAMETER SkipHashCheck
    Do not verify the sha256 of the downloaded image.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-vm.ps1

.EXAMPLE
    # reinstall from scratch, pinned release, WSLg off
    .\setup-vm.ps1 -Release 2605.7.2 -Force -DisableGuiApplications

.EXAMPLE
    # config changed: copy it in and rebuild the running VM
    .\setup-vm.ps1 -UpdateOnly -RebuildMode switch
#>

[CmdletBinding()]
param(
    [string] $Distro = 'NixOS-AI-Lab',
    [string] $Release = 'latest',
    [string] $NixDir,
    [string] $InstallDir,
    [string] $DownloadDir,
    [string] $ImageFile,
    [ValidateSet('boot', 'switch', 'none')]
    [string] $RebuildMode = 'boot',
    [switch] $UpdateOnly,
    [switch] $Force,
    [switch] $UpdateChannels,
    [switch] $DisableGuiApplications,
    [switch] $NonInteractive,
    [switch] $SkipHashCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is slow with the progress bar

$script:LastExit = 0
$script:OldConsoleEncoding = [Console]::OutputEncoding
$script:OldOutputEncoding = $OutputEncoding

$env:WSL_UTF8 = '1'                        # wsl.exe prints UTF-8 instead of UTF-16
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = New-Object Text.ASCIIEncoding   # stdin to wsl.exe is base64, ASCII only

# -- constants -------------------------------------------------------------------------------
$RepoUrl = 'https://github.com/nix-community/NixOS-WSL'
$RepoApi = 'https://api.github.com/repos/nix-community/NixOS-WSL'

# CUDA packages are not on cache.nixos.org. The first build runs before nix/gpu-llama.nix
# is active, so the cache has to be passed on the command line; keep in sync with that file.
$CudaCache = 'https://cache.nixos-cuda.org'
$CudaKey = 'cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M='

$UnstableChannel = 'https://channels.nixos.org/nixos-unstable'
$GitHubHeaders = @{ 'User-Agent' = 'nixos-wsl-setup'; 'Accept' = 'application/vnd.github+json' }

# -- output ----------------------------------------------------------------------------------
function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string] $Message) Write-Host "    $Message" }
function Write-Note { param([string] $Message) Write-Host "    warning: $Message" -ForegroundColor Yellow }
function Stop-Setup { param([string] $Message) throw $Message }

function Confirm-Action {
    param([string] $Message)
    if ($NonInteractive) { return $true }
    $answer = Read-Host "$Message [y/N]"
    return ($answer -match '^(y|yes)$')
}

# -- wsl -------------------------------------------------------------------------------------
function Invoke-Wsl {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $Capture,
        [switch] $AllowFailure
    )
    Write-Verbose "wsl.exe $($Arguments -join ' ')"
    $output = $null
    if ($Capture) {
        $output = (& wsl.exe @Arguments 2>&1 | Out-String)
    }
    else {
        & wsl.exe @Arguments
    }
    $script:LastExit = $LASTEXITCODE
    if ($script:LastExit -ne 0 -and -not $AllowFailure) {
        if ($Capture) { Write-Host $output }
        Stop-Setup "wsl.exe $($Arguments -join ' ') failed with exit code $script:LastExit"
    }
    if ($Capture) { return [string] $output }   # never $null, callers .Trim() it
}

# Run a command in the VM as root, through a login shell (PATH, NIX_PATH, ...).
function Invoke-Root {
    param(
        [Parameter(Mandatory)] [string] $Command,
        [switch] $Capture,
        [switch] $AllowFailure
    )
    Invoke-Wsl -Arguments @('-d', $Distro, '-u', 'root', '--', 'bash', '-lc', $Command) `
        -Capture:$Capture -AllowFailure:$AllowFailure
}

# Write a local file into the VM as root, byte for byte, and verify it.
# base64 over stdin instead of a file copy: works regardless of interop and drive mounts.
function Copy-ToDistro {
    param(
        [Parameter(Mandatory)] [string] $LocalPath,
        [Parameter(Mandatory)] [string] $RemotePath
    )
    $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalPath))
    # tr removes the newline the pipe appends; base64 -d would reject a \r
    $base64 | & wsl.exe -d $Distro -u root -- bash -lc "umask 022; tr -d '\r\n' | base64 -d > '$RemotePath'"
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "writing $RemotePath in $Distro failed with exit code $LASTEXITCODE"
    }

    $expected = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLower()
    $actual = ((Invoke-Root "sha256sum '$RemotePath'" -Capture).Trim() -split '\s+')[0].ToLower()
    if ($actual -ne $expected) {
        Stop-Setup "$RemotePath differs from $LocalPath (sha256 $actual, expected $expected)"
    }
}

# -- release / download ------------------------------------------------------------------------
# The Location header: HttpResponseHeaders in PowerShell 7, WebHeaderCollection in 5.1.
function Get-RedirectLocation {
    param($Response)
    if (-not $Response) { return $null }
    $headers = $Response.Headers
    if (-not $headers) { return $null }
    if ($headers.PSObject.Properties['Location'] -and $headers.Location) {
        return [string] @($headers.Location)[0]
    }
    try {
        $value = $headers['Location']
        if ($value) { return [string] @($value)[0] }
    }
    catch { }
    return $null
}

function Resolve-ReleaseTag {
    param([string] $Requested)
    if ($Requested -and $Requested -ne 'latest') { return $Requested }

    try {
        return (Invoke-RestMethod -Uri "$RepoApi/releases/latest" -Headers $GitHubHeaders -UseBasicParsing).tag_name
    }
    catch {
        Write-Note "GitHub API not usable ($($_.Exception.Message)), trying the release redirect"
    }

    $location = $null
    try {
        # -MaximumRedirection 0: the 302 of /releases/latest points at /releases/tag/<tag>
        $location = Get-RedirectLocation (Invoke-WebRequest -Uri "$RepoUrl/releases/latest" -MaximumRedirection 0 -UseBasicParsing)
    }
    catch {
        if ($_.Exception.PSObject.Properties['Response']) {
            $location = Get-RedirectLocation $_.Exception.Response
        }
    }
    if ($location -and $location -match '/tag/([^/]+)/?$') { return $Matches[1] }

    Stop-Setup "could not determine the latest NixOS-WSL release; pass -Release <tag>, e.g. -Release 2605.7.2"
}

function Get-RemoteFile {
    param([string] $Uri, [string] $OutFile)

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --location --fail --retry 3 --continue-at - --output $OutFile $Uri
        if ($LASTEXITCODE -ne 0) {
            # a broken partial file makes resuming fail; start over once
            Write-Note "resumed download failed (exit $LASTEXITCODE), downloading from scratch"
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            & $curl.Source --location --fail --retry 3 --output $OutFile $Uri
            if ($LASTEXITCODE -ne 0) { Stop-Setup "downloading $Uri failed with exit code $LASTEXITCODE" }
        }
    }
    else {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    }
}

function Get-ReleaseImage {
    param([string] $Tag, [string] $Directory)

    $asset = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'nixos.aarch64.wsl' } else { 'nixos.wsl' }
    $url = "$RepoUrl/releases/download/$Tag/$asset"
    $target = Join-Path $Directory "$Tag-$asset"

    $expected = $null
    if (-not $SkipHashCheck) {
        try {
            # the asset is served as application/octet-stream, so .Content is a byte array
            $sha = (Invoke-WebRequest -Uri "$url.sha256" -UseBasicParsing).Content
            if ($sha -is [byte[]]) { $sha = [Text.Encoding]::ASCII.GetString($sha) }
            if ([string] $sha -match '([0-9a-fA-F]{64})') { $expected = $Matches[1].ToLower() }
            else { Write-Note "could not read a sha256 from $asset.sha256; the image will not be verified" }
        }
        catch {
            Write-Note "could not fetch $asset.sha256 ($($_.Exception.Message)); the image will not be verified"
        }
    }

    if (Test-Path -LiteralPath $target) {
        if (-not $expected) {
            Write-Info "using cached image $target (not verified)"
            return $target
        }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
        if ($actual -eq $expected) {
            Write-Info "using cached image $target (sha256 ok)"
            return $target
        }
        Write-Note 'cached image has a different sha256, downloading again'
        Remove-Item -LiteralPath $target -Force
    }

    Write-Info "downloading $url"
    $partial = "$target.part"
    Get-RemoteFile -Uri $url -OutFile $partial

    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            Stop-Setup "sha256 mismatch for $asset (got $actual, expected $expected)"
        }
        Write-Info 'sha256 ok'
    }
    Move-Item -LiteralPath $partial -Destination $target -Force
    return $target
}

# -- .wslconfig ----------------------------------------------------------------------------------
function Get-WslConfigPath { return (Join-Path $env:USERPROFILE '.wslconfig') }

function Test-GuiApplicationsDisabled {
    $path = Get-WslConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $inWsl2 = $false
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $inWsl2 = ($Matches[1] -eq 'wsl2'); continue }
        if ($inWsl2 -and $line -match '^\s*guiApplications\s*=\s*(\S+)') { return ($Matches[1] -match '^(false|0)$') }
    }
    return $false
}

function Disable-GuiApplications {
    $path = Get-WslConfigPath
    if (Test-GuiApplicationsDisabled) {
        Write-Info "$path already has guiApplications=false"
        return
    }

    $lines = @()
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination "$path.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $lines = @(Get-Content -LiteralPath $path)
    }

    $sectionAt = -1
    $keyAt = -1
    $inWsl2 = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
            $inWsl2 = ($Matches[1] -eq 'wsl2')
            if ($inWsl2) { $sectionAt = $i }
            continue
        }
        if ($inWsl2 -and $lines[$i] -match '^\s*guiApplications\s*=') { $keyAt = $i; break }
    }

    if ($keyAt -ge 0) {
        $lines[$keyAt] = 'guiApplications=false'
    }
    elseif ($sectionAt -ge 0) {
        $head = if ($sectionAt -eq 0) { @($lines[0]) } else { $lines[0..$sectionAt] }
        $tail = if ($sectionAt -eq $lines.Count - 1) { @() } else { $lines[($sectionAt + 1)..($lines.Count - 1)] }
        $lines = @($head) + @('guiApplications=false') + @($tail)
    }
    else {
        $lines = @($lines) + @('[wsl2]', 'guiApplications=false')
    }

    [IO.File]::WriteAllLines($path, [string[]] $lines, (New-Object Text.UTF8Encoding $false))
    Write-Info "set guiApplications=false in $path (takes effect after wsl --shutdown)"
}

# ==================================================================================================
# main
# ==================================================================================================
try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    # a config change on a running VM does not need the restart dance
    if ($UpdateOnly -and -not $PSBoundParameters.ContainsKey('RebuildMode')) { $RebuildMode = 'switch' }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    if (-not $NixDir) { $NixDir = Join-Path $scriptDir 'nix' }
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA "WSL\$Distro" }
    if (-not $DownloadDir) { $DownloadDir = Join-Path $env:LOCALAPPDATA 'NixOS-WSL' }

    # -- 1. host checks ----------------------------------------------------------------------
    Write-Step 'checking the host'
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Stop-Setup 'wsl.exe not found. Install WSL first: `wsl --install --no-distribution`, then reboot.'
    }
    $wslVersion = (Invoke-Wsl -Arguments @('--version') -Capture -AllowFailure)
    if ($script:LastExit -eq 0) {
        $firstLine = @($wslVersion -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($firstLine) { Write-Info $firstLine[0].Trim() }
    }
    else {
        Write-Note 'old "inbox" WSL (no --version); NixOS-WSL support is best effort there'
    }

    if (-not (Test-Path -LiteralPath $NixDir)) { Stop-Setup "config directory not found: $NixDir" }
    $nixFiles = @(Get-ChildItem -LiteralPath $NixDir -File -Filter '*.nix' | Sort-Object Name)
    if (-not $nixFiles) { Stop-Setup "no *.nix files in $NixDir" }
    if (-not ($nixFiles.Name -contains 'configuration.nix')) {
        Stop-Setup "$NixDir has no configuration.nix"
    }
    # file names end up inside a shell command below
    $odd = @($nixFiles | Where-Object { $_.Name -notmatch '^[A-Za-z0-9._-]+$' })
    if ($odd) { Stop-Setup "rename these, the names are not safe to pass to a shell: $($odd.Name -join ', ')" }
    Write-Info "config: $NixDir ($($nixFiles.Count) files)"

    if ($RebuildMode -eq 'switch' -and -not $UpdateOnly) {
        Write-Note 'a fresh install should use -RebuildMode boot: the default user changes and sudo disappears, which a running system cannot switch to (see nix/users.nix)'
    }

    # keep the hardcoded CUDA key honest
    $gpuNix = Join-Path $NixDir 'gpu-llama.nix'
    if ((Test-Path -LiteralPath $gpuNix) -and
        ((Get-Content -LiteralPath $gpuNix -Raw) -notmatch [regex]::Escape($CudaKey))) {
        Write-Note "the CUDA cache key in this script does not appear in gpu-llama.nix; check both"
    }

    $existing = @()
    $list = Invoke-Wsl -Arguments @('--list', '--quiet') -Capture -AllowFailure
    if ($script:LastExit -eq 0) {
        # the NUL filter is for old "inbox" WSL, which ignores WSL_UTF8 and prints UTF-16
        $existing = @($list -split '\r?\n' | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    }
    $distroExists = $existing -contains $Distro

    # -- 2. install the distro ------------------------------------------------------------------
    $tag = $null
    if ($UpdateOnly) {
        if (-not $distroExists) { Stop-Setup "-UpdateOnly: distro '$Distro' is not registered" }
        Write-Info "updating the existing distro '$Distro'"
    }
    else {
        if ($distroExists) {
            if (-not $Force) {
                Stop-Setup "distro '$Distro' already exists. Use -UpdateOnly to only apply the config, -Force to delete and reinstall, or -Distro <name> for a second VM."
            }
            Write-Step "deleting the existing distro '$Distro'"
            Write-Note "this destroys its disk image and everything in it, including /home/agent"
            if (-not (Confirm-Action "unregister '$Distro' now?")) { Stop-Setup 'aborted' }
            Invoke-Wsl -Arguments @('--terminate', $Distro) -AllowFailure
            Invoke-Wsl -Arguments @('--unregister', $Distro)
            $distroExists = $false
        }

        if ($ImageFile) {
            if (-not (Test-Path -LiteralPath $ImageFile)) { Stop-Setup "image not found: $ImageFile" }
            $image = (Resolve-Path -LiteralPath $ImageFile).Path
            Write-Step "using the local image $image"
        }
        else {
            Write-Step 'resolving the NixOS-WSL release'
            $tag = Resolve-ReleaseTag -Requested $Release
            Write-Info "release $tag"
            if (-not (Test-Path -LiteralPath $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir | Out-Null }
            $image = Get-ReleaseImage -Tag $tag -Directory $DownloadDir
        }

        Write-Step "importing '$Distro' into $InstallDir"
        if (Test-Path -LiteralPath $InstallDir) {
            $leftovers = @(Get-ChildItem -LiteralPath $InstallDir -Force)
            if ($leftovers) {
                if (-not $Force) { Stop-Setup "$InstallDir is not empty; use -Force or pass -InstallDir <dir>" }
                Write-Note "$InstallDir still contains $($leftovers.Count) file(s) from an earlier install"
                if (-not (Confirm-Action "delete the leftover files in ${InstallDir}?")) { Stop-Setup 'aborted' }
                $leftovers | Remove-Item -Recurse -Force
                Write-Info 'leftovers deleted'
            }
        }
        else {
            New-Item -ItemType Directory -Path $InstallDir | Out-Null
        }

        try {
            $drive = New-Object IO.DriveInfo ((Split-Path -Qualifier $InstallDir) + '\')
            $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
            Write-Info "$freeGb GB free on $($drive.Name)"
            if ($freeGb -lt 25) {
                Write-Note 'less than 25 GB free; the image, the CUDA llama.cpp closure and the model will not fit'
            }
        }
        catch { Write-Verbose "no free space info for $InstallDir" }

        Write-Info 'unpacking the image, this takes a few minutes'
        Invoke-Wsl -Arguments @('--import', $Distro, $InstallDir, $image, '--version', '2')
    }

    # -- 3. channels ----------------------------------------------------------------------------
    Write-Step 'setting up the nix channels'
    $channels = Invoke-Root 'nix-channel --list' -Capture -AllowFailure
    $channelsChanged = $false

    if ($channels -notmatch '(?m)^nixos\s') {
        $nixosVersion = (Invoke-Root 'nixos-version' -Capture).Trim()
        if ($nixosVersion -notmatch '^(\d+\.\d+)') { Stop-Setup "cannot read the NixOS release from '$nixosVersion'" }
        $nixosChannel = "https://channels.nixos.org/nixos-$($Matches[1])"
        Write-Info "adding nixos -> $nixosChannel"
        Invoke-Root "nix-channel --add $nixosChannel nixos"
        $channelsChanged = $true
    }

    if ($tag) {
        # The image points nixos-wsl at the release *branch*; pin it to the installed release
        # so a later `nix-channel --update` cannot change the WSL modules under us.
        # Back to the moving branch:
        #   nix-channel --add $RepoUrl/archive/refs/heads/release-<ver>.tar.gz nixos-wsl
        Write-Info "pinning nixos-wsl to $tag"
        Invoke-Root "nix-channel --add $RepoUrl/archive/refs/tags/$tag.tar.gz nixos-wsl"
        $channelsChanged = $true
    }

    if ($channels -notmatch '(?m)^nixos-unstable\s') {
        Write-Info "adding nixos-unstable -> $UnstableChannel (nix/opencode.nix)"
        Invoke-Root "nix-channel --add $UnstableChannel nixos-unstable"
        $channelsChanged = $true
    }

    if ($channelsChanged -or $UpdateChannels) {
        Write-Info 'nix-channel --update'
        Invoke-Root 'nix-channel --update'
    }
    else {
        Write-Info 'channels unchanged (pass -UpdateChannels to refresh them)'
    }

    # -- 4. config files --------------------------------------------------------------------------
    Write-Step "copying the config to ${Distro}:/etc/nixos"

    $imageConfig = Invoke-Root 'cat /etc/nixos/configuration.nix' -Capture -AllowFailure
    $imageState = if ($imageConfig -match 'system\.stateVersion\s*=\s*"([^"]+)"') { $Matches[1] } else { $null }
    $localConfig = Get-Content -LiteralPath (Join-Path $NixDir 'configuration.nix') -Raw
    $localState = if ($localConfig -match 'system\.stateVersion\s*=\s*"([^"]+)"') { $Matches[1] } else { $null }
    if ($imageState -and $localState -and $imageState -ne $localState) {
        Write-Note "stateVersion: the image has $imageState, $NixDir\configuration.nix has $localState"
        Write-Note 'keep the value the fresh install had unless you know what you are changing'
    }

    Invoke-Root 'install -d -m 0755 /etc/nixos'
    foreach ($file in $nixFiles) {
        Write-Info $file.Name
        Copy-ToDistro -LocalPath $file.FullName -RemotePath "/etc/nixos/$($file.Name)"
    }

    $remoteFiles = @((Invoke-Root 'cd /etc/nixos && ls -1 *.nix' -Capture -AllowFailure) -split '\r?\n' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $stale = @($remoteFiles | Where-Object { $nixFiles.Name -notcontains $_ })
    if ($stale) {
        Write-Note "/etc/nixos also contains, left over from an earlier run: $($stale -join ', ')"
        Write-Note "they are inert unless configuration.nix imports them; delete with: wsl -d $Distro -u root -- rm /etc/nixos/<file>"
    }

    # -- 5. rebuild ---------------------------------------------------------------------------------
    if ($RebuildMode -eq 'none') {
        Write-Step 'skipping nixos-rebuild (-RebuildMode none)'
    }
    else {
        Write-Step "nixos-rebuild $RebuildMode"
        if (-not $UpdateOnly) {
            Write-Info 'first build: expect a large download (CUDA llama.cpp, opencode) and some patience'
        }
        $options = "--option extra-substituters '$CudaCache' --option extra-trusted-public-keys '$CudaKey'"
        Invoke-Root "nixos-rebuild $RebuildMode $options"

        if ($RebuildMode -eq 'boot') {
            # The new generation is only activated at the next start, and the default user from
            # the new /etc/wsl.conf only on the start after that. `wsl -t` is not enough here:
            # it can leave stale cgroups behind and break the systemd user session.
            Write-Step 'activating the new generation'
            Write-Info 'wsl --shutdown stops all WSL distros on this machine'
            Invoke-Wsl -Arguments @('--shutdown')
            Invoke-Root 'true' | Out-Null
            Invoke-Wsl -Arguments @('--shutdown')
        }
    }

    # -- 6. .wslconfig -------------------------------------------------------------------------------
    if ($DisableGuiApplications) {
        Write-Step 'disabling WSLg'
        Disable-GuiApplications
    }
    elseif (-not (Test-GuiApplicationsDisabled)) {
        Write-Note "WSLg is still enabled. nix/windows-isolation.nix recommends [wsl2] guiApplications=false in $(Get-WslConfigPath); re-run with -DisableGuiApplications to set it."
    }

    # -- 7. result -------------------------------------------------------------------------------------
    Write-Step 'result'
    $version = (Invoke-Root 'nixos-version; nixos-wsl-version' -Capture -AllowFailure).Trim()
    foreach ($line in ($version -split '\r?\n' | Where-Object { $_.Trim() })) { Write-Info $line.Trim() }

    $defaultUser = (Invoke-Wsl -Arguments @('-d', $Distro, '--', 'bash', '-lc', 'id -un') -Capture -AllowFailure).Trim()
    Write-Info "default user: $defaultUser"
    if ($RebuildMode -eq 'boot' -and $defaultUser -ne 'agent') {
        Write-Note "expected 'agent' (nix/users.nix); if this is still 'nixos', run: wsl --shutdown"
    }

    $gpu = (Invoke-Root 'nvidia-smi --query-gpu=name,driver_version --format=csv,noheader' -Capture -AllowFailure).Trim()
    if ($script:LastExit -eq 0 -and $gpu) { Write-Info "gpu: $gpu" }
    else { Write-Note 'nvidia-smi found no GPU; check the NVIDIA driver on the Windows side' }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host "  shell as agent : wsl -d $Distro"
    Write-Host "  shell as root  : wsl -d $Distro -u root"
    Write-Host "  apply config   : .\setup-vm.ps1 -Distro $Distro -UpdateOnly"
    Write-Host "  throw away     : wsl --unregister $Distro"
    Write-Host ''
    Write-Host '  Next: put the GGUF model where nix/gpu-llama.nix expects it (~/models/... as agent),'
    Write-Host "        then run 'oc' in the VM to start llama-server and opencode."
}
catch {
    Write-Host ''
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
    exit 1
}
finally {
    [Console]::OutputEncoding = $script:OldConsoleEncoding
    $OutputEncoding = $script:OldOutputEncoding
}
