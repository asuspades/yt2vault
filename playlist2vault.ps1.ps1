<#
.SYNOPSIS
    playlist2vault.ps1 - Playlist OR Channel Streams → transcripts + outlines

.DESCRIPTION
    - Accepts:
        • Playlist URL / ID
        • Channel /streams URL
    - Downloads captions (preferred, no GPU)
    - Falls back to Whisper only if needed
    - Saves transcripts locally
    - Saves outlines to Obsidian Channel Vault
    - Skips existing files unless -Force

.REQUIRES
    yt-dlp, Firefox cookies, Node.js, Ollama (optional), Whisper (optional)

.CONFIGURATION
    Set paths via ONE of these methods (in order of precedence):
    1. Environment variables: PV_YT2TXT, PV_WHISPER_DIR, PV_AUDIO_DIR,
       PV_NODE_EXE, PV_TRANSCRIPTS, PV_OBSIDIAN
    2. Local config file: config.local.ps1 (gitignored)
    3. Defaults: Relative to $PSScriptRoot or user Documents folder
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Source,

    [string]$Model = "gemma3:27b",
    [int]$Limit = 0,
    [switch]$Oldest,
    [switch]$Force,
    [switch]$NoOutline,
    [switch]$UseWhisper,
    [switch]$NoWhisperFallback,
    [switch]$DryRun,

    [ValidateSet('firefox','chrome','edge','safari','brave')]
    [string]$CookieBrowser = 'firefox'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────
# LOAD OPTIONAL LOCAL CONFIG (gitignored)
# ─────────────────────────────────────────
$localConfig = Join-Path $PSScriptRoot "config.local.ps1"
if (Test-Path $localConfig) {
    Write-Verbose "Loading local config: $localConfig"
    . $localConfig
}

# ─────────────────────────────────────────
# CONFIG - Resolved from env vars → local override → defaults
# ─────────────────────────────────────────

$Yt2TxtScript = $env:PV_YT2TXT ?? $script:ConfigOverride?.Yt2TxtScript ?? ""
$WhisperDir   = $env:PV_WHISPER_DIR ?? $script:ConfigOverride?.WhisperDir ?? ""
$AudioDir     = $env:PV_AUDIO_DIR ?? $script:ConfigOverride?.AudioDir ?? ""
$NodeExe      = $env:PV_NODE_EXE ?? $script:ConfigOverride?.NodeExe ?? "node"
$TranscriptRoot = $env:PV_TRANSCRIPTS ?? $script:ConfigOverride?.TranscriptRoot ?? ""
$ObsidianRoot   = $env:PV_OBSIDIAN ?? $script:ConfigOverride?.ObsidianRoot ?? ""

# Fallback defaults (safe for Git, relative to script or user folders)
if (-not $Yt2TxtScript) { $Yt2TxtScript = Join-Path $PSScriptRoot "helpers\yt2txt.ps1" }
if (-not $WhisperDir)   { $WhisperDir   = Join-Path $PSScriptRoot "data\whisper" }
if (-not $AudioDir)     { $AudioDir     = Join-Path $PSScriptRoot "data\audio" }
if (-not $TranscriptRoot) {
    $TranscriptRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "YouTube Transcripts"
    Write-Verbose "TranscriptRoot not set. Using default: $TranscriptRoot"
}
if (-not $ObsidianRoot) {
    $ObsidianRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Obsidian\Youtube Channel Vault"
    Write-Warning "ObsidianRoot not set. Using default: $ObsidianRoot"
}

# Validate critical optional dependency
if ($Yt2TxtScript -and -not (Test-Path $Yt2TxtScript)) {
    Write-Warning "Yt2TxtScript not found: $Yt2TxtScript (Whisper fallback will be disabled)"
}

# ─────────────────────────────────────────
# DETECT INPUT TYPE
# ─────────────────────────────────────────

$isPlaylist = $false
$isChannel  = $false

if ($Source -match 'list=([A-Za-z0-9_-]+)' -or $Source -match '^PL[A-Za-z0-9_-]{16,}$') {
    $isPlaylist = $true
}
elseif ($Source -match 'youtube\.com/@[^/]+/streams') {
    $isChannel = $true
}
else {
    Write-Error "Input must be playlist URL/ID OR channel /streams URL"
    exit 1
}

# ─────────────────────────────────────────
# LOAD METADATA
# ─────────────────────────────────────────

Write-Host "Resolving metadata..." -ForegroundColor Cyan

if ($isPlaylist) {

    if ($Source -match 'list=([A-Za-z0-9_-]+)') {
        $PlaylistId = $Matches[1]
    } else {
        $PlaylistId = $Source
    }

    $SourceUrl = "https://www.youtube.com/playlist?list=$PlaylistId"

    $json = & yt-dlp `
        --cookies-from-browser $CookieBrowser `
        --js-runtimes $NodeExe `
        --flat-playlist -J `
        --no-warnings `
        $SourceUrl 2>$null | ConvertFrom-Json

    $channelName = ($json.uploader -replace '[<>:"/\\|?*]', '').Trim()
    $collection  = ($json.title    -replace '[<>:"/\\|?*]', '').Trim()
}

if ($isChannel) {

    $SourceUrl = $Source

    $json = & yt-dlp `
        --cookies-from-browser $CookieBrowser `
        --js-runtimes $NodeExe `
        --flat-playlist -J `
        --no-warnings `
        $SourceUrl 2>$null | ConvertFrom-Json

    # Try multiple fields in order of reliability
    $channelName = $null
    foreach ($field in @($json.channel, $json.uploader, $json.entries[0].channel, $json.entries[0].uploader)) {
        if ($field -and $field.Trim()) {
            $channelName = ($field -replace '[<>:"/\\|?*]', '').Trim()
            break
        }
    }

    if (-not $channelName) {
        # Last resort: extract from URL (@handle)
        if ($Source -match '@([^/]+)') {
            $channelName = $Matches[1]
        } else {
            $channelName = "UnknownChannel"
        }
    }

    $collection = "Livestream"
}

$TranscriptsDir = Join-Path $TranscriptRoot $channelName
$OutlinesDir    = Join-Path $ObsidianRoot "$channelName\$collection"
$TempDir        = Join-Path $env:TEMP ("vault_" + ([guid]::NewGuid().ToString().Substring(0,8)))

Write-Host "Channel:     $channelName" -ForegroundColor Cyan
Write-Host "Collection:  $collection"  -ForegroundColor Cyan
Write-Host "Transcripts: $TranscriptsDir" -ForegroundColor DarkGray
Write-Host "Outlines:    $OutlinesDir"    -ForegroundColor DarkGray

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
    param($VttPath, $TxtPath)

    $lines = Get-Content $VttPath
    $buf   = [System.Collections.Generic.List[string]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($l in $lines) {
        # Skip header, blank, timestamp-only lines
        if ($l -match '^\s*$') { continue }
        if ($l -match '^\d{2}:\d{2}:\d{2}\.\d{3} -->') { continue }
        if ($l -match '^WEBVTT') { continue }
        if ($l -match '^Kind:') { continue }
        if ($l -match '^Language:') { continue }

        # Strip inline timing tags  <00:00:00.000>
        $clean = ($l -replace '<[^>]+>', '').Trim()
        if ($clean -and $seen.Add($clean)) {
            $buf.Add($clean)
        }
    }

    ($buf -join ' ') -replace '\s{2,}', ' ' | Out-File -LiteralPath $TxtPath -Encoding utf8
}

function Get-Captions {
    param($id, $out)

    Remove-Item "$TempDir\$id*" -Force -ErrorAction SilentlyContinue

    $commonArgs = @(
        '--cookies-from-browser', $CookieBrowser,
        '--js-runtimes',          $NodeExe,
        '--write-auto-sub',
        '--sub-lang',             'en',
        '--sub-format',           'vtt',
        '--skip-download',
        '--ignore-no-formats-error',
        '--no-warnings',
        '--socket-timeout',       '30',
        '-o',                     "$TempDir\$id",
        "https://www.youtube.com/watch?v=$id"
    )

    # PASS 1 — default client
    & yt-dlp @commonArgs 2>&1 | Out-Null

    $vtt = Get-ChildItem $TempDir -Filter "$id*.vtt" -ErrorAction SilentlyContinue | Select-Object -First 1

    # PASS 2 — android client fallback
    if (-not $vtt) {
        & yt-dlp @commonArgs '--extractor-args' 'youtube:player_client=android' 2>&1 | Out-Null
        $vtt = Get-ChildItem $TempDir -Filter "$id*.vtt" -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $vtt) { return $false }

    Convert-VttToTxt $vtt.FullName $out
    Remove-Item $vtt.FullName -Force -ErrorAction SilentlyContinue
    return $true
}

function Get-Whisper {
    param($id, $out)

    if (-not (Test-Path $Yt2TxtScript)) { return $false }

    & $Yt2TxtScript -Url "https://www.youtube.com/watch?v=$id" `
        -DownloadDir $AudioDir `
        -WhisperDir  $WhisperDir

    Start-Sleep 2

    $txt = Get-ChildItem $WhisperDir -Filter "*$id*.txt" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($txt) {
        Copy-Item $txt.FullName $out -Force
        return $true
    }

    return $false
}

$OutlinePrompt = @'
You are a transcript analyst. Your ONLY job is to output a Content Brief in the EXACT format shown below. Do NOT write prose analysis. Do NOT write essays. Do NOT add commentary. Do NOT deviate from the template. Begin your response with the # Content Brief heading and nothing else.

REQUIRED OUTPUT FORMAT — FOLLOW EXACTLY:

# Content Brief: [Speaker Name/Content Title]

**TL;DR:** [2-3 sentence summary of key takeaways]

## Main Discussion Points

- **[Primary Topic/Theme]**

  - Key insight or development
  - Supporting detail with context
  - Relevant statistics or examples
  - "[Powerful direct quote from the transcript]"
  - Additional supporting information

- **[Secondary Topic/Theme]**

  - Key insight or development
  - Background context and implications
  - "[Another direct quote from the transcript]"
  - Related details and consequences

## Resources Discussed

- [ ] **Resource Title** by Author/Organization (Year if mentioned) - One sentence on relevance
- [ ] **Another Resource Title** by Author/Organization (Year if mentioned) - One sentence on relevance

---

INSTRUCTIONS:

1. TL;DR: 2-3 sentences capturing the main takeaways.

2. Main Discussion Points: Comprehensive hierarchical breakdown. Cover ALL major topics. Each topic gets multiple sub-bullets with depth, context, and at least one direct quote from the transcript. Include 5-8 total quotes across all sections. Quotes must be actual words spoken in the transcript, not paraphrases.

3. Resources Discussed: List every named work that was meaningfully discussed, recommended, or used as evidence—books, films, TV shows, albums, documentaries, websites, YouTube channels, podcasts, academic papers. Each entry should be something a reader would actually want to seek out based on the conversation. Exclude passing name-drops with no context. Use - [ ] checkbox format so the reader can track what they have viewed or acquired.

Begin your response now with # Content Brief:
'@

function Get-Outline {
    param($txt, $md)

    if ($NoOutline) { return $false }

    $raw = Get-Content -LiteralPath $txt -Raw
    if (-not $raw) { return $false }

    $userMsg = $OutlinePrompt + "`n`n--- TRANSCRIPT START ---`n$raw`n--- TRANSCRIPT END ---"

    # Serialize via .NET JsonSerializer to handle em-dashes, smart quotes,
    # and other non-ASCII cleanly across all PowerShell versions.
    $bodyObj = [ordered]@{
        model    = $Model
        stream   = $false
        options  = [ordered]@{ num_ctx = 131072 }
        messages = @(
            [ordered]@{ role = "user";      content = $userMsg }
            [ordered]@{ role = "assistant"; content = "# Content Brief:" }
        )
    }

    # PS 5.1 ConvertTo-Json has a known bug with long strings containing
    # certain unicode chars. Use .NET's JavaScriptSerializer instead.
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = [int]::MaxValue

    $bodyJson  = $jss.Serialize($bodyObj)
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    try {
        $r = Invoke-RestMethod `
            -Uri         "http://127.0.0.1:11434/api/chat" `
            -Method      POST `
            -Body        $bodyBytes `
            -ContentType "application/json; charset=utf-8" `
            -TimeoutSec  1200

        $text = $r.message.content
        if ($text) {
            ("# Content Brief:" + $text) | Out-File -LiteralPath $md -Encoding utf8
            return $true
        }
    } catch {
        Write-Host "  -> Ollama error: $_" -ForegroundColor Red
    }

    return $false
}

# ─────────────────────────────────────────
# BUILD VIDEO LIST
# ─────────────────────────────────────────

$videos = $json.entries | ForEach-Object {
    [PSCustomObject]@{
        Id    = $_.id
        Title = $_.title
    }
}

if ($Oldest) { [array]::Reverse($videos) }
if ($Limit -gt 0) { $videos = $videos | Select-Object -First $Limit }

Write-Host "Videos found: $($videos.Count)" -ForegroundColor Cyan

# ─────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────

$processed = 0

foreach ($v in $videos) {

    Write-Host "`n$($v.Title)" -ForegroundColor Yellow

    $safe = Sanitize $v.Title

    $txt = Join-Path $TranscriptsDir "$safe [$($v.Id)].txt"
    $md  = Join-Path $OutlinesDir    "$safe [$($v.Id)].md"

    if (-not $Force -and (Test-Path -LiteralPath $txt) -and (Test-Path -LiteralPath $md)) {
        Write-Host "  -> Skipping (exists)" -ForegroundColor DarkGray
        continue
    }

    if ($DryRun) {
        Write-Host "  -> DryRun" -ForegroundColor DarkGray
        continue
    }

    if (-not (Test-Path -LiteralPath $txt)) {

        $ok = $false

        Write-Host "  -> Captions..." -ForegroundColor Cyan
        $ok = Get-Captions $v.Id $txt

        if (-not $ok) {
            Start-Sleep 2
            Write-Host "  -> Captions retry..." -ForegroundColor Cyan
            $ok = Get-Captions $v.Id $txt
        }

        if (-not $ok -and -not $NoWhisperFallback) {
            Write-Host "  -> Whisper fallback..." -ForegroundColor Yellow
            $ok = Get-Whisper $v.Id $txt
        }

        if (-not $ok) {
            Write-Host "  -> Failed (no transcript)" -ForegroundColor Red
            continue
        }
    }

    if (-not (Test-Path -LiteralPath $md)) {
        Write-Host "  -> Outline..." -ForegroundColor Cyan

        if (Get-Outline $txt $md) {
            Write-Host "  -> Saved" -ForegroundColor Green
        } else {
            Write-Host "  -> Outline skipped/failed" -ForegroundColor DarkGray
        }
    }

    $processed++
}

# Cleanup temp
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nDone: $processed / $($videos.Count)" -ForegroundColor Cyan
