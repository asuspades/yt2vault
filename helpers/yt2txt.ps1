<#
.SYNOPSIS
    yt2txt.ps1 - YouTube/Rumble URL → MP3 → Whisper transcription

.DESCRIPTION
    Helper script for playlist2vault.ps1.
    Downloads audio from a video URL and transcribes it using local Whisper.

    Configuration precedence:
    1. Environment variables (YTTXT_*)
    2. config.local.ps1 override ($script:ConfigOverride)
    3. Defaults: Relative to $PSScriptRoot or user folders

.REQUIRES
    yt-dlp, Node.js (for yt-dlp JS runtime), Transcribe-GPU.ps1 (or similar)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    # Paths: leave empty to use env vars / config / defaults
    [string]$DownloadDir = "",
    [string]$WhisperDir  = "",

    # Transcriber script path: leave empty to use env var / config / default
    [string]$TranscriberPath = "",

    [ValidateSet("faster","whisper")]
    [string]$Engine = "faster",
    [ValidateSet("fast","max","balanced")]
    [string]$Preset = "max",
    [string]$Model = "medium.en",

    [switch]$NoResample16k,
    [switch]$NoVAD,
    [switch]$WordTimestamps,

    # Runtime config
    [ValidateSet('firefox','chrome','edge','safari','brave')]
    [string]$CookieBrowser = 'firefox',
    [string]$NodeRuntime = "node"  # Use "node" if in PATH, or full path like "node:C:\Program Files\nodejs\node.exe"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

# ─────────────────────────────────────────
# LOAD OPTIONAL LOCAL CONFIG (gitignored)
# ─────────────────────────────────────────
$localConfig = Join-Path $PSScriptRoot "config.local.ps1"
if (Test-Path $localConfig) {
    Write-Verbose "Loading local config: $localConfig"
    . $localConfig
}

# ─────────────────────────────────────────
# RESOLVE PATHS: env vars → config override → param default → sensible fallback
# ─────────────────────────────────────────

# DownloadDir: where MP3s are saved
if (-not $DownloadDir) {
    $DownloadDir = $env:YTTXT_DOWNLOAD_DIR ?? $script:ConfigOverride?.DownloadDir ?? ""
}
if (-not $DownloadDir) {
    # Default: sibling "data/audio" folder, or user Videos\YouTube
    $relative = Join-Path $PSScriptRoot "data\audio"
    if (Test-Path $relative) {
        $DownloadDir = $relative
    } else {
        $DownloadDir = Join-Path ([Environment]::GetFolderPath("MyVideos")) "YouTube"
        Write-Verbose "DownloadDir not set. Using default: $DownloadDir"
    }
}

# WhisperDir: where transcription outputs go
if (-not $WhisperDir) {
    $WhisperDir = $env:YTTXT_WHISPER_DIR ?? $script:ConfigOverride?.WhisperDir ?? ""
}
if (-not $WhisperDir) {
    $relative = Join-Path $PSScriptRoot "data\whisper"
    if (Test-Path $relative) {
        $WhisperDir = $relative
    } else {
        $WhisperDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Whisper"
        Write-Verbose "WhisperDir not set. Using default: $WhisperDir"
    }
}

# TranscriberPath: path to Transcribe-GPU.ps1 or equivalent
if (-not $TranscriberPath) {
    $TranscriberPath = $env:YTTXT_TRANSCRIBER ?? $script:ConfigOverride?.TranscriberPath ?? ""
}
if (-not $TranscriberPath) {
    # Default: look in common relative locations
    $candidates = @(
        (Join-Path $PSScriptRoot "Transcribe-GPU.ps1"),
        (Join-Path $PSScriptRoot "helpers\Transcribe-GPU.ps1"),
        (Join-Path $PSScriptRoot "..\scripts\Transcribe-GPU.ps1")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $TranscriberPath = $c
            break
        }
    }
    if (-not $TranscriberPath) {
        Write-Warning "TranscriberPath not set and not found in defaults. Set YTTXT_TRANSCRIBER env var or use -TranscriberPath."
    }
}

# Validate critical paths
if (-not (Test-Path $DownloadDir)) {
    try { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }
    catch { Write-Error "Cannot create DownloadDir: $DownloadDir"; exit 1 }
}
if (-not (Test-Path $WhisperDir)) {
    try { New-Item -ItemType Directory -Path $WhisperDir -Force | Out-Null }
    catch { Write-Error "Cannot create WhisperDir: $WhisperDir"; exit 1 }
}
if ($TranscriberPath -and -not (Test-Path $TranscriberPath)) {
    Write-Warning "Transcriber script not found: $TranscriberPath"
}

# ─────────────────────────────────────────
# INPUT VALIDATION
# ─────────────────────────────────────────

if ($Url -notmatch '^https?://') {
    Write-Host "Invalid input. Provide a full http(s) URL." -ForegroundColor Red
    exit 1
}

# Optional: host-based DownloadDir override (configurable via env)
try {
    $u = [uri]$Url
    $hostOverride = $null
    if ($u.Host -like "*rumble.com") {
        $hostOverride = $env:YTTXT_RUMBLE_DIR ?? $script:ConfigOverride?.RumbleDir ?? ""
        if (-not $hostOverride) {
            $hostOverride = Join-Path ([Environment]::GetFolderPath("MyVideos")) "Rumble"
        }
        Write-Verbose "Rumble detected. Using DownloadDir: $hostOverride"
        $DownloadDir = $hostOverride
        if (-not (Test-Path $DownloadDir)) {
            New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
        }
    }
} catch {
    Write-Verbose "Host detection skipped: $_"
}

# ─────────────────────────────────────────
# DOWNLOAD AUDIO
# ─────────────────────────────────────────

Write-Host "[*] Downloading audio..." -ForegroundColor Cyan

$ytDlpArgs = @(
    '--js-runtimes', $NodeRuntime,
    '--cookies-from-browser', $CookieBrowser,
    '-P', $DownloadDir,
    '-o', "%(title)s [%(id)s].%(ext)s",
    '-f', "ba[acodec^=mp3]/ba/b",
    '-x', '--audio-format', 'mp3',
    '--no-warnings',
    $Url
)

& yt-dlp @ytDlpArgs

$LatestMp3 = Get-ChildItem -Path $DownloadDir -Filter *.mp3 -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1

if (-not $LatestMp3) {
    Write-Host "No MP3 found after download. Check yt-dlp output above." -ForegroundColor Red
    exit 1
}

Write-Verbose "Downloaded: $($LatestMp3.FullName)"

# ─────────────────────────────────────────
# TRANSCRIBE
# ─────────────────────────────────────────

if (-not $TranscriberPath) {
    Write-Host "[!] TranscriberPath not configured. Skipping transcription." -ForegroundColor Yellow
    Write-Host "[i] Audio saved: $($LatestMp3.FullName)" -ForegroundColor Cyan
    exit 0
}

Write-Host "[*] Transcribing (engine=$Engine, preset=$Preset, model=$Model)..." -ForegroundColor Cyan

# Use hashtable splatting for proper parameter binding
$transcribeParams = @{
    InputPath = $LatestMp3.FullName
    Model     = $Model
    Engine    = $Engine
    Preset    = $Preset
    OutputDir = $WhisperDir
}

# Add switch parameters if set
if ($NoResample16k)   { $transcribeParams['NoResample16k']  = $true }
if ($NoVAD)           { $transcribeParams['NoVAD']          = $true }
if ($WordTimestamps)  { $transcribeParams['WordTimestamps'] = $true }

& $TranscriberPath @transcribeParams

# ─────────────────────────────────────────
# OUTPUT REPORT
# ─────────────────────────────────────────

$txtPath = Join-Path $WhisperDir ([IO.Path]::GetFileNameWithoutExtension($LatestMp3.Name) + ".txt")
if (Test-Path $txtPath) {
    Write-Host "[OK] Transcript: $txtPath" -ForegroundColor Green
} else {
    # Try to find any .txt output with matching ID
    $id = [IO.Path]::GetFileNameWithoutExtension($LatestMp3.Name)
    $found = Get-ChildItem $WhisperDir -Filter "*$id*.txt" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        Write-Host "[OK] Transcript: $($found.FullName)" -ForegroundColor Green
    } else {
        Write-Host "[i] Finished. Check outputs in $WhisperDir." -ForegroundColor Yellow
    }
}
