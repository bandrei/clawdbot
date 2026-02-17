# PowerShell script for setting up OpenClaw (Windows version of docker-setup.sh)
$ErrorActionPreference = "Stop"

$RootDir = $PSScriptRoot
$ComposeFile = Join-Path $RootDir "docker-compose.yml"
$ExtraComposeFile = Join-Path $RootDir "docker-compose.extra.yml"
$EnvFile = Join-Path $RootDir ".env"

# --- Default Configuration ---
$ImageName = if ($env:OPENCLAW_IMAGE) { $env:OPENCLAW_IMAGE } else { "openclaw:local" }
$ExtraMounts = if ($env:OPENCLAW_EXTRA_MOUNTS) { $env:OPENCLAW_EXTRA_MOUNTS } else { "" }
$HomeVolumeName = if ($env:OPENCLAW_HOME_VOLUME) { $env:OPENCLAW_HOME_VOLUME } else { "" }

# --- Helper Functions ---
function Require-Cmd {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "Missing dependency: $Name"
        exit 1
    }
}

Require-Cmd "docker"
try {
    docker compose version > $null 2>&1
}
catch {
    Write-Error "Docker Compose not available (try: docker compose version)"
    exit 1
}

# --- Directories ---
$OpenClawConfigDir = if ($env:OPENCLAW_CONFIG_DIR) { $env:OPENCLAW_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".openclaw" }
$OpenClawWorkspaceDir = if ($env:OPENCLAW_WORKSPACE_DIR) { $env:OPENCLAW_WORKSPACE_DIR } else { Join-Path $env:USERPROFILE ".openclaw\workspace" }

if (-not (Test-Path $OpenClawConfigDir)) { New-Item -ItemType Directory -Path $OpenClawConfigDir -Force | Out-Null }
if (-not (Test-Path $OpenClawWorkspaceDir)) { New-Item -ItemType Directory -Path $OpenClawWorkspaceDir -Force | Out-Null }

# Export variables for the session
$env:OPENCLAW_CONFIG_DIR = $OpenClawConfigDir
$env:OPENCLAW_WORKSPACE_DIR = $OpenClawWorkspaceDir
$env:OPENCLAW_GATEWAY_PORT = if ($env:OPENCLAW_GATEWAY_PORT) { $env:OPENCLAW_GATEWAY_PORT } else { "18789" }
$env:OPENCLAW_BRIDGE_PORT = if ($env:OPENCLAW_BRIDGE_PORT) { $env:OPENCLAW_BRIDGE_PORT } else { "18790" }
$env:OPENCLAW_GATEWAY_BIND = if ($env:OPENCLAW_GATEWAY_BIND) { $env:OPENCLAW_GATEWAY_BIND } else { "lan" }
$env:OPENCLAW_IMAGE = $ImageName
$env:OPENCLAW_DOCKER_APT_PACKAGES = if ($env:OPENCLAW_DOCKER_APT_PACKAGES) { $env:OPENCLAW_DOCKER_APT_PACKAGES } else { "" }
$env:OPENCLAW_EXTRA_MOUNTS = $ExtraMounts
$env:OPENCLAW_HOME_VOLUME = $HomeVolumeName

# --- Token Generation ---
if (-not $env:OPENCLAW_GATEWAY_TOKEN) {
    if (Get-Command "openssl" -ErrorAction SilentlyContinue) {
        $env:OPENCLAW_GATEWAY_TOKEN = (openssl rand -hex 32).Trim()
    }
    else {
        # Fallback to .NET RNG
        $bytes = New-Object Byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $env:OPENCLAW_GATEWAY_TOKEN = [BitConverter]::ToString($bytes).Replace("-", "").ToLower()
    }
}

# --- Handle Docker Compose Files ---
$ComposeFiles = @($ComposeFile)

function Write-ExtraCompose {
    param(
        [string]$HomeVolume,
        [string[]]$Mounts
    )

    $content = "services:`n  openclaw-gateway:`n    volumes:`n"
    
    if (-not [string]::IsNullOrEmpty($HomeVolume)) {
        $content += "      - ${HomeVolume}:/home/node`n"
        $content += "      - ${OpenClawConfigDir}:/home/node/.openclaw`n"
        $content += "      - ${OpenClawWorkspaceDir}:/home/node/.openclaw/workspace`n"
    }
    
    foreach ($m in $Mounts) {
        if (-not [string]::IsNullOrWhiteSpace($m)) {
            $content += "      - $m`n"
        }
    }

    $content += "  openclaw-cli:`n    volumes:`n"
    if (-not [string]::IsNullOrEmpty($HomeVolume)) {
        $content += "      - ${HomeVolume}:/home/node`n"
        $content += "      - ${OpenClawConfigDir}:/home/node/.openclaw`n"
        $content += "      - ${OpenClawWorkspaceDir}:/home/node/.openclaw/workspace`n"
    }

    foreach ($m in $Mounts) {
        if (-not [string]::IsNullOrWhiteSpace($m)) {
            $content += "      - $m`n"
        }
    }

    # Only add named volume if HomeVolume is a string (not a path with / or \)
    if (-not [string]::IsNullOrEmpty($HomeVolume) -and $HomeVolume -notmatch "[/\\]") {
        $content += "volumes:`n  ${HomeVolume}:`n"
    }

    Set-Content -Path $ExtraComposeFile -Value $content -Encoding UTF8
}

$ValidMounts = @()
if (-not [string]::IsNullOrEmpty($ExtraMounts)) {
    $ValidMounts = $ExtraMounts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

if (-not [string]::IsNullOrEmpty($HomeVolumeName) -or $ValidMounts.Count -gt 0) {
    Write-ExtraCompose -HomeVolume $HomeVolumeName -Mounts $ValidMounts
    $ComposeFiles += $ExtraComposeFile
}

$ComposeArgs = @()
$ComposeHint = "docker compose"
foreach ($file in $ComposeFiles) {
    $ComposeArgs += "-f", $file
    $ComposeHint += " -f `"$file`""
}

# --- Upsert .env ---
function Upsert-Env {
    param(
        [string]$Path,
        [string[]]$Keys
    )
    
    $seen = @{}
    $newLines = @()
    
    if (Test-Path $Path) {
        $lines = Get-Content $Path
        foreach ($line in $lines) {
            $replaced = $false
            # Match key=value where key doesn't start with #
            if ($line -match "^([^#=]+)=(.*)$") {
                $key = $Matches[1].Trim()
                if ($Keys -contains $key) {
                    $val = (Get-Item "env:$key").Value
                    $newLines += "$key=$val"
                    $seen[$key] = $true
                    $replaced = $true
                }
            }
            if (-not $replaced) {
                $newLines += $line
            }
        }
    }

    foreach ($k in $Keys) {
        if (-not $seen.ContainsKey($k)) {
            if (Test-Path "env:$k") {
                $val = (Get-Item "env:$k").Value
                $newLines += "$k=$val"
            }
        }
    }

    Set-Content -Path $Path -Value $newLines -Encoding UTF8
}

Upsert-Env -Path $EnvFile -Keys @(
    "OPENCLAW_CONFIG_DIR",
    "OPENCLAW_WORKSPACE_DIR",
    "OPENCLAW_GATEWAY_PORT",
    "OPENCLAW_BRIDGE_PORT",
    "OPENCLAW_GATEWAY_BIND",
    "OPENCLAW_GATEWAY_TOKEN",
    "OPENCLAW_IMAGE",
    "OPENCLAW_EXTRA_MOUNTS",
    "OPENCLAW_HOME_VOLUME",
    "OPENCLAW_DOCKER_APT_PACKAGES"
)

# --- Build & Run ---
Write-Host "==> Building Docker image: $ImageName"
docker build `
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$env:OPENCLAW_DOCKER_APT_PACKAGES" `
    -t "$ImageName" `
    -f (Join-Path $RootDir "Dockerfile") `
    "$RootDir"

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "==> Onboarding (interactive)"
Write-Host "When prompted:"
Write-Host "  - Gateway bind: lan"
Write-Host "  - Gateway auth: token"
Write-Host "  - Gateway token: $env:OPENCLAW_GATEWAY_TOKEN"
Write-Host "  - Tailscale exposure: Off"
Write-Host "  - Install Gateway daemon: No"
Write-Host ""

# Construct command arguments for docker
$dockerArgs = @("compose") + $ComposeArgs + @("run", "--rm", "openclaw-cli", "onboard", "--no-install-daemon")
& docker $dockerArgs

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "==> Provider setup (optional)"
Write-Host "WhatsApp (QR):"
Write-Host "  $ComposeHint run --rm openclaw-cli channels login"
Write-Host "Telegram (bot token):"
Write-Host "  $ComposeHint run --rm openclaw-cli channels add --channel telegram --token <token>"
Write-Host "Discord (bot token):"
Write-Host "  $ComposeHint run --rm openclaw-cli channels add --channel discord --token <token>"
Write-Host "Docs: https://docs.openclaw.ai/channels"

Write-Host ""
Write-Host "==> Starting gateway"
$upArgs = @("compose") + $ComposeArgs + @("up", "-d", "openclaw-gateway")
& docker $upArgs

Write-Host ""
Write-Host "Gateway running with host port mapping."
Write-Host "Access from tailnet devices via the host's tailnet IP."
Write-Host "Config: $env:OPENCLAW_CONFIG_DIR"
Write-Host "Workspace: $env:OPENCLAW_WORKSPACE_DIR"
Write-Host "Token: $env:OPENCLAW_GATEWAY_TOKEN"
Write-Host ""
Write-Host "Commands:"
Write-Host "  $ComposeHint logs -f openclaw-gateway"
Write-Host "  $ComposeHint exec openclaw-gateway node dist/index.js health --token `"$env:OPENCLAW_GATEWAY_TOKEN`""
