<#
.SYNOPSIS
    playlist-to-vault.ps1 - Convert a YouTube playlist into an Obsidian-ready vault

.DESCRIPTION
    - Prompts for a YouTube playlist URL or playlist ID
    - Resolves channel + playlist name automatically
    - Downloads captions (preferred, no GPU)
    - Falls back to Whisper only if needed
    - Saves transcripts locally (Documents\YouTube Transcripts\<Channel>)
    - Saves outlines to Obsidian Series Vault
    - Skips existing files unless -Force

.REQUIRES
    yt-dlp, Firefox cookies, Ollama (optional), Whisper (optional)

.SETUP
    Configure via environment variables (recommended) or edit the CONFIG section.
    See README.md for full setup instructions.
#>

[CmdletBinding()]
param(
    [string]$Playlist,
    [string]$Model = "gemma3:12b",
    [int]$Limit = 0,
    [switch]$Oldest,
    [switch]$Force,
    [switch]$NoOutline,
    [switch]$UseWhisper,
    [switch]$NoWhisperFallback,
    [switch]$DryRun,
    [ValidateSet('firefox', 'chrome', 'edge', 'safari')]
    [string]$CookieBrowser = 'firefox'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
# Set environment variables to avoid editing this file:
#   PLAYLIST_VAULT_YT2TXT   - Path to yt2txt.ps1 helper script
#   PLAYLIST_VAULT_WHISPER  - Directory for Whisper output
#   PLAYLIST_VAULT_AUDIO    - Directory for temporary audio downloads
#   PLAYLIST_VAULT_OBSIDIAN - Root of your Obsidian Series Vault
#
# Or create a gitignored config.local.ps1 next to this script with overrides.

$localConfig = Join-Path $PSScriptRoot "config.local.ps1"
if (Test-Path $localConfig) {
    Write-Verbose "Loading local config: $localConfig"
    . $localConfig
}

$Yt2TxtScript = $env:PLAYLIST_VAULT_YT2TXT    ?? (Join-Path $PSScriptRoot "helpers\yt2txt.ps1")
$WhisperDir   = $env:PLAYLIST_VAULT_WHISPER   ?? (Join-Path $PSScriptRoot "data\whisper")
$AudioDir     = $env:PLAYLIST_VAULT_AUDIO     ?? (Join-Path $PSScriptRoot "data\audio")
$ObsidianRoot = $env:PLAYLIST_VAULT_OBSIDIAN  ?? ""

if (-not $ObsidianRoot) {
    $ObsidianRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Obsidian\Series Vault"
    Write-Warning "PLAYLIST_VAULT_OBSIDIAN not set. Using default: $ObsidianRoot"
}

# ─────────────────────────────────────────
# INPUT
# ─────────────────────────────────────────

if (-not $Playlist) {
    $Playlist = Read-Host "Enter YouTube playlist URL or playlist ID"
}

if ($Playlist -match 'list=([A-Za-z0-9_-]+)') {
    $PlaylistId = $Matches[1]
}
elseif ($Playlist -match '^PL[A-Za-z0-9_-]{16,}$') {
    $PlaylistId = $Playlist
}
else {
    Write-Error "Invalid playlist input"
    exit 1
}

$PlaylistUrl = "https://www.youtube.com/playlist?list=$PlaylistId"

# ─────────────────────────────────────────
# RESOLVE CHANNEL + PLAYLIST
# ─────────────────────────────────────────

Write-Host "Resolving metadata..." -ForegroundColor Cyan

$json = & yt-dlp `
    --cookies-from-browser $CookieBrowser `
    --flat-playlist -J `
    --no-warnings `
    $PlaylistUrl 2>$null | ConvertFrom-Json

if (-not $json) { throw "Failed to load playlist" }

$channelName   = ($json.uploader -replace '[<>:"/\\|?*]', '').Trim()
$playlistTitle = ($json.title    -replace '[<>:"/\\|?*]', '').Trim()

$TranscriptRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "YouTube Transcripts"
$TranscriptsDir = Join-Path $TranscriptRoot $channelName
$OutlinesDir    = Join-Path $ObsidianRoot "$channelName\$playlistTitle"
$TempDir        = Join-Path $env:TEMP "playlist2vault_$PlaylistId"

Write-Host "Channel:     $channelName"   -ForegroundColor Cyan
Write-Host "Playlist:    $playlistTitle" -ForegroundColor Cyan
Write-Host "Transcripts: $TranscriptsDir" -ForegroundColor DarkGray
Write-Host "Outlines:    $OutlinesDir"   -ForegroundColor DarkGray

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────

@($TranscriptsDir, $OutlinesDir, $TempDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ─────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────

function Sanitize {
    param([string]$t)
    $t -replace '[<>:"/\\|?*]', '' -replace '\s+', ' ' | ForEach-Object { $_.Trim() }
}

function Convert-VttToTxt {
    param(
        [string]$VttPath,
        [string]$TxtPath
    )

    $lines = Get-Content -LiteralPath $VttPath -Encoding UTF8

    $content = @()

    foreach ($l in $lines) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        if ($l -match '^WEBVTT') { continue }
        if ($l -match '^Kind:') { continue }
        if ($l -match '^Language:') { continue }
        if ($l -match '^NOTE') { continue }
        if ($l -match '^\d{2}:\d{2}:\d{2}\.\d{3}\s*-->') { continue }

        if ($l -match '<\d{2}:\d{2}:\d{2}\.\d{3}>') {
            $clean = ($l -replace '<[^>]+>', '').Trim()
            if ($clean) {
                $clean = $clean -replace '^\s*>>\s*', ''
                $content += $clean
            }
        }
    }

    $text = ($content -join ' ') -replace '\s{2,}', ' '
    $text = $text.Trim()

    $sentences = [regex]::Split($text, '(?<=[.!?])\s+(?=[A-Z])')

    $paras = @()
    $buf   = @()

    foreach ($s in $sentences) {
        $buf += $s
        if ($buf.Count -ge 5) {
            $paras += ($buf -join ' ').Trim()
            $buf = @()
        }
    }

    if ($buf.Count -gt 0) {
        $paras += ($buf -join ' ').Trim()
    }

    ($paras -join "`n`n") | Out-File -LiteralPath $TxtPath -Encoding utf8 -NoNewline
}

function Get-Captions {
    param(
        [string]$Id,
        [string]$OutPath
    )

    Remove-Item "$TempDir\$Id*" -Force -ErrorAction SilentlyContinue

    # ── PASS 1: cookies + web client (primary)
    & yt-dlp `
        --cookies-from-browser $CookieBrowser `
        --write-auto-sub `
        --sub-lang en `
        --sub-format vtt `
        --skip-download `
        --no-warnings `
        --ignore-no-formats-error `
        -o "$TempDir\$Id" `
        "https://www.youtube.com/watch?v=$Id" 2>$null

    $vtt = Get-ChildItem -LiteralPath $TempDir -Filter "$Id*.vtt" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    # ── PASS 2: android client (fallback, no cookies)
    if (-not $vtt) {
        & yt-dlp `
            --write-auto-sub `
            --sub-lang en `
            --sub-format vtt `
            --skip-download `
            --no-warnings `
            --ignore-no-formats-error `
            --extractor-args "youtube:player_client=android" `
            -o "$TempDir\$Id" `
            "https://www.youtube.com/watch?v=$Id" 2>$null

        $vtt = Get-ChildItem -LiteralPath $TempDir -Filter "$Id*.vtt" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    if (-not $vtt) { return $false }

    Convert-VttToTxt -VttPath $vtt.FullName -TxtPath $OutPath
    Remove-Item -LiteralPath $vtt.FullName -Force -ErrorAction SilentlyContinue

    return $true
}

function Get-Whisper {
    param(
        [string]$Id,
        [string]$OutPath
    )

    if (-not (Test-Path -LiteralPath $Yt2TxtScript)) {
        Write-Host "    -> Whisper script not found at: $Yt2TxtScript" -ForegroundColor Yellow
        return $false
    }

    Write-Host "    -> Running Whisper..." -ForegroundColor Yellow

    try {
        & $Yt2TxtScript `
            -Url "https://www.youtube.com/watch?v=$Id" `
            -DownloadDir $AudioDir `
            -WhisperDir $WhisperDir `
            -Engine faster `
            -Preset max `
            -Model medium.en

        Start-Sleep 2

        $txt = Get-ChildItem -LiteralPath $WhisperDir -Filter "*$Id*.txt" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($txt) {
            Copy-Item -LiteralPath $txt.FullName -Destination $OutPath -Force

            Get-ChildItem -LiteralPath $AudioDir -Filter "*$Id*" -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '\.(mp3|webm|m4a|opus|wav)$' } |
                Remove-Item -Force -ErrorAction SilentlyContinue

            return $true
        }
    }
    catch {
        Write-Host "    -> Whisper failed: $_" -ForegroundColor Red
    }

    return $false
}

$OutlinePrompt = @"
Summarize this transcript into a structured markdown outline.

Include:
- TL;DR
- Key sections
- Important arguments
- Notable quotes

Be concise and structured.
"@

function Get-Outline {
    param(
        [string]$TranscriptPath,
        [string]$OutPath,
        [string]$Title,
        [string]$Id
    )

    if ($NoOutline) { return $false }

    if (-not (Test-Path -LiteralPath $TranscriptPath)) { return $false }

    $text = Get-Content -LiteralPath $TranscriptPath -Raw
    if (-not $text.Trim()) { return $false }

    $prompt = "$OutlinePrompt`n`nVIDEO TITLE: $Title`nVIDEO ID: $Id`n`nTRANSCRIPT:`n$text"

    try {
        $body = @{
            model  = $Model
            prompt = $prompt
            stream = $false
        } | ConvertTo-Json -Depth 5

        $resp = Invoke-RestMethod `
            -Uri "http://127.0.0.1:11434/api/generate" `
            -Method POST `
            -Body $body `
            -ContentType "application/json"

        if ($resp.response) {
            $resp.response | Out-File -LiteralPath $OutPath -Encoding utf8
            return $true
        }
    }
    catch {
        Write-Host "    -> Ollama failed: $_" -ForegroundColor Yellow
    }

    return $false
}

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────

$videos = $json.entries | ForEach-Object {
    [PSCustomObject]@{
        Id    = $_.id
        Title = $_.title
    }
}

if ($Oldest)    { [array]::Reverse($videos) }
if ($Limit -gt 0) { $videos = $videos | Select-Object -First $Limit }

$processed = 0

foreach ($v in $videos) {

    Write-Host "`n$($v.Title)" -ForegroundColor Yellow

    $safe = Sanitize $v.Title
    $txt  = Join-Path $TranscriptsDir "$safe [$($v.Id)].txt"
    $md   = Join-Path $OutlinesDir    "$safe [$($v.Id)].md"

    if (-not $Force -and (Test-Path -LiteralPath $txt) -and (Test-Path -LiteralPath $md)) {
        Write-Host "  -> Skipping (exists)" -ForegroundColor DarkGray
        continue
    }

    # ── TRANSCRIPT ─────────────────────────

    if (-not (Test-Path -LiteralPath $txt) -or $Force) {

        $ok = $false

        if (-not $UseWhisper) {
            Write-Host "  -> Captions..." -ForegroundColor Cyan
            $ok = Get-Captions $v.Id $txt

            if (-not $ok) {
                Start-Sleep 1
                $ok = Get-Captions $v.Id $txt
            }
        }

        if (-not $ok -and -not $NoWhisperFallback) {
            Write-Host "  -> Whisper fallback..." -ForegroundColor Yellow
            $ok = Get-Whisper $v.Id $txt
        }

        if (-not $ok) {
            Write-Host "  -> Failed" -ForegroundColor Red
            continue
        }

        Write-Host "  -> Transcript saved" -ForegroundColor Green
    }
    else {
        Write-Host "  -> Using existing transcript" -ForegroundColor DarkGray
    }

    # ── OUTLINE ────────────────────────────

    if (-not (Test-Path -LiteralPath $md) -or $Force) {

        if (Test-Path -LiteralPath $txt) {
            Write-Host "  -> Outline..." -ForegroundColor Cyan

            if (Get-Outline $txt $md $v.Title $v.Id) {
                Write-Host "  -> Outline saved" -ForegroundColor Green
            }
            else {
                Write-Host "  -> Outline skipped/failed" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host "  -> Using existing outline" -ForegroundColor DarkGray
    }

    $processed++
}

Write-Host "`nDone. Processed: $processed" -ForegroundColor Cyan
