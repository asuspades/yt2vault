<#
.SYNOPSIS
    playlist2vault.ps1 - Playlist OR Channel → transcripts + outlines

.DESCRIPTION
    - Accepts:
        • Playlist URL / ID
        • Channel /streams, /videos, or /shorts URL
    - Downloads captions (preferred, no GPU)
    - Falls back to Whisper only if needed
    - Filenames: {position} {title} [{id}]  (position = oldest-first index)
    - Sets filesystem timestamps from YouTube upload date
    - Skip logic matches by video ID — survives renames
    - Saves transcripts locally
    - Saves outlines to Obsidian Channel Vault
    - Skips existing files unless -Force
    - Normalize mode: rename + restamp existing files only; never regenerates content

.REQUIRES
    yt-dlp, browser cookies, Node.js, Ollama (optional), Whisper (optional)

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
    [switch]$Normalize,   # Rename + restamp existing files only; never regenerates content

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
elseif ($Source -match 'youtube\.com/@[^/]+/(streams|videos|shorts)') {
    $isChannel = $true
}
else {
    Write-Error "Input must be a playlist URL/ID or a channel /streams, /videos, or /shorts URL"
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
        if ($Source -match '@([^/]+)') { $channelName = $Matches[1] }
        else                           { $channelName = "UnknownChannel" }
    }

    $collection = if ($Source -match '/streams') { "Livestream" } `
                  elseif ($Source -match '/shorts') { "Shorts" } `
                  else { "Videos" }
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

# Strip leading "Channel Name - " or "Channel Name: " prefix from title
function Strip-ChannelPrefix {
    param([string]$title, [string]$channel)
    $escaped = [regex]::Escape($channel)
    $title -replace "^$escaped\s*[-:]\s*", ''
}

# Zero-padded position string based on total count
function Format-Position {
    param([int]$pos, [int]$total)
    $width = $total.ToString().Length
    $pos.ToString().PadLeft($width, '0')
}

function Convert-VttToTxt {
    param($VttPath, $TxtPath)

    $lines = Get-Content $VttPath
    $buf   = [System.Collections.Generic.List[string]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($l in $lines) {
        if ($l -match '^\s*$') { continue }
        if ($l -match '^\d{2}:\d{2}:\d{2}\.\d{3} -->') { continue }
        if ($l -match '^WEBVTT') { continue }
        if ($l -match '^Kind:') { continue }
        if ($l -match '^Language:') { continue }

        $clean = ($l -replace '<[^>]+>', '').Trim()
        if ($clean -and $seen.Add($clean)) {
            $buf.Add($clean)
        }
    }

    ($buf -join ' ') -replace '\s{2,}', ' ' | Out-File -LiteralPath $TxtPath -Encoding utf8
}

# Fetch upload timestamp from YouTube for a given video ID
function Get-UploadDate {
    param([string]$id)

    $ts = & yt-dlp `
        --cookies-from-browser $CookieBrowser `
        --js-runtimes $NodeExe `
        --no-warnings `
        --print "%(timestamp)s" `
        "https://www.youtube.com/watch?v=$id" 2>$null

    if ($ts -and ($ts.Trim() -match '^\d+$')) {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts.Trim()).LocalDateTime
    }
    return $null
}

# Apply creation + write timestamps to a file
function Set-FileDate {
    param([string]$path, [datetime]$dt)
    try {
        [IO.File]::SetCreationTime($path, $dt)
        [IO.File]::SetLastWriteTime($path, $dt)
    } catch {}
}

# Find existing file in a directory matching *[id].ext regardless of prefix/title.
# Uses regex with [regex]::Escape() to safely handle IDs containing special chars like '-'.
# Optional $preferStem: if provided, prefers exact target filename first.
function Find-ByVideoId {
    param(
        [string]$dir,
        [string]$id,
        [string]$ext,
        [string]$preferStem = ""
    )
    
    # Regex-escape ID to prevent misinterpretation of special chars
    $escapedId = [regex]::Escape($id)
    
    # Match files containing [id] anywhere in name (flexible for legacy files)
    $pattern = "\[$escapedId\]"
    $matches = @(Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern })

    if ($matches.Count -eq 0) { return $null }

    # Prefer exact target name if provided and present
    if ($preferStem) {
        $exact = $matches | Where-Object { $_.BaseName -eq $preferStem }
        if ($exact) { return $exact | Select-Object -First 1 }
    }

    # If duplicates exist, prefer the one that already has a numeric prefix (^\d+\s)
    $numbered = $matches | Where-Object { $_.Name -match '^\d+\s' }
    if ($numbered) { return $numbered | Select-Object -First 1 }

    return $matches | Select-Object -First 1
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
        '--sleep-requests',       '1',
        '-o',                     "$TempDir\$id",
        "https://www.youtube.com/watch?v=$id"
    )

    # PASS 1 — default client
    & yt-dlp @commonArgs 2>&1 | Out-Null
    $vtt = Get-ChildItem $TempDir -Filter "$id*.vtt" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

    # PASS 2 — android + safari fallback
    if (-not $vtt) {
        & yt-dlp @commonArgs '--extractor-args' 'youtube:player_client=android,web_safari' 2>&1 | Out-Null

        $vtt = Get-ChildItem $TempDir -Filter "$id*.vtt" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1
    }

    if (-not $vtt) {
        return $false
    }

    Convert-VttToTxt $vtt.FullName $out
    Remove-Item $vtt.FullName -Force -ErrorAction SilentlyContinue

    return (Test-Path -LiteralPath $out)
}

function Get-Whisper {
    param($id, $out)

    if (-not (Test-Path $Yt2TxtScript)) { return $false }

    # Track files BEFORE execution for reliable fallback detection
    $before = @(Get-ChildItem $WhisperDir -Filter "*.txt" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName)

    & $Yt2TxtScript -Url "https://www.youtube.com/watch?v=$id" `
        -DownloadDir $AudioDir `
        -WhisperDir  $WhisperDir

    Start-Sleep 3

    # Try strict ID match first
    $escapedId = [regex]::Escape($id)
    $txt = Get-ChildItem $WhisperDir -Filter "*$escapedId*.txt" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    # Fallback: newest file created during run (handles non-ID-named outputs)
    if (-not $txt) {
        $after = Get-ChildItem $WhisperDir -Filter "*.txt" -ErrorAction SilentlyContinue
        $txt = $after |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if ($txt -and (Test-Path $txt.FullName)) {
        Copy-Item $txt.FullName $out -Force
        return $true
    }

    Write-Host "  -> Whisper failed to produce usable output" -ForegroundColor DarkGray
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

    function EscapeJson([string]$s) {
        $s.Replace('\',  '\\').
           Replace('"',  '\"').
           Replace("`n", '\n').
           Replace("`r", '\r').
           Replace("`t", '\t')
    }

    $sysPrompt = EscapeJson $userMsg
    $asstPrime = EscapeJson "# Content Brief:"
    $modelEsc  = EscapeJson $Model

    $bodyJson  = '{"model":"' + $modelEsc + '","stream":false,"options":{"num_ctx":131072},"messages":[{"role":"user","content":"' + $sysPrompt + '"},{"role":"assistant","content":"' + $asstPrime + '"}]}'
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
# yt-dlp returns newest-first; assign positions oldest-first (1 = oldest)
# ─────────────────────────────────────────

$allEntries = @($json.entries | ForEach-Object {
    [PSCustomObject]@{ Id = $_.id; Title = $_.title }
})

$total = $allEntries.Count

# Reverse to get oldest-first, assign 1-based positions
$withPos = for ($i = 0; $i -lt $total; $i++) {
    [PSCustomObject]@{
        Id       = $allEntries[$total - 1 - $i].Id
        Title    = $allEntries[$total - 1 - $i].Title
        Position = $i + 1
    }
}

# Default processing order: newest first (reverse of withPos)
$videos = $withPos[$($total - 1)..0]

if ($Oldest) { $videos = $withPos }
if ($Limit -gt 0) { $videos = $videos | Select-Object -First $Limit }

Write-Host "Videos found: $total" -ForegroundColor Cyan

# ─────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────

$processed = 0
$renamed   = 0
$restamped = 0

foreach ($v in $videos) {

    Write-Host "`n$($v.Title)" -ForegroundColor Yellow

    $pos      = Format-Position $v.Position $total
    $stripped = Strip-ChannelPrefix (Sanitize $v.Title) $channelName
    $safe     = Sanitize $stripped
    $stem     = "$pos $safe [$($v.Id)]"

    $txt = Join-Path $TranscriptsDir "$stem.txt"
    $md  = Join-Path $OutlinesDir    "$stem.md"

    # ID-based lookup — prefer file already matching target stem
    $existingTxt = Find-ByVideoId $TranscriptsDir $v.Id ".txt" $stem
    $existingMd  = Find-ByVideoId $OutlinesDir    $v.Id ".md"  $stem

    # ── RENAME NORMALIZATION ──
    $didRename = $false

    if ($existingTxt -and $existingTxt.FullName -ne $txt) {
        if (-not $DryRun) {
            Rename-Item -LiteralPath $existingTxt.FullName -NewName "$stem.txt" -ErrorAction SilentlyContinue
            $existingTxt = Get-Item -LiteralPath $txt -ErrorAction SilentlyContinue
            # Remove stale duplicates with same ID left over from pre-numbering runs
            $escapedId = [regex]::Escape($v.Id)
            Get-ChildItem -LiteralPath $TranscriptsDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "\[$escapedId\]\.txt$" -and $_.FullName -ne $txt } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "  -> Renamed transcript" -ForegroundColor DarkGray
        $didRename = $true; $renamed++
    }

    if ($existingMd -and $existingMd.FullName -ne $md) {
        if (-not $DryRun) {
            Rename-Item -LiteralPath $existingMd.FullName -NewName "$stem.md" -ErrorAction SilentlyContinue
            $existingMd = Get-Item -LiteralPath $md -ErrorAction SilentlyContinue
            # Remove stale duplicates with same ID left over from pre-numbering runs
            $escapedId = [regex]::Escape($v.Id)
            Get-ChildItem -LiteralPath $OutlinesDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "\[$escapedId\]\.md$" -and $_.FullName -ne $md } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "  -> Renamed outline" -ForegroundColor DarkGray
        $didRename = $true
    }

    # ── NORMALIZE MODE ──
    if ($Normalize) {
        if (-not ($existingTxt -or $existingMd)) {
            Write-Host "  -> Not found locally, skipping" -ForegroundColor DarkGray
            continue
        }

        if ($DryRun) {
            Write-Host "  -> DryRun: would restamp $stem" -ForegroundColor DarkGray
            continue
        }

        $uploadDt = Get-UploadDate $v.Id

        if ($uploadDt) {
            $txtPath = if ($existingTxt -and (Test-Path -LiteralPath $txt)) { $txt }
                       elseif ($existingTxt) { $existingTxt.FullName } else { $null }

            $mdPath  = if ($existingMd -and (Test-Path -LiteralPath $md)) { $md }
                       elseif ($existingMd) { $existingMd.FullName } else { $null }

            $stamped = $false

            if ($txtPath) {
                $cur = [IO.File]::GetLastWriteTime($txtPath)
                if ([math]::Abs(($cur - $uploadDt).TotalSeconds) -gt 60) {
                    Set-FileDate $txtPath $uploadDt
                    $stamped = $true
                    $restamped++
                }
            }

            if ($mdPath) {
                $cur = [IO.File]::GetLastWriteTime($mdPath)
                if ([math]::Abs(($cur - $uploadDt).TotalSeconds) -gt 60) {
                    Set-FileDate $mdPath $uploadDt
                    $stamped = $true
                }
            }

            $label = if ($stamped) { "Restamped" } else { "Date OK" }
            Write-Host "  -> $label $($uploadDt.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
        }

        continue
    }

    # ── NORMAL MODE ──

    if ($DryRun) {
        Write-Host "  -> DryRun: $stem" -ForegroundColor DarkGray
        continue
    }

    if (-not $Force -and $existingTxt -and $existingMd) {
        if (-not $didRename) {
            Write-Host "  -> Skipping (exists)" -ForegroundColor DarkGray
        }
        $processed++
        continue
    }

    $uploadDt = $null

    # ── TRANSCRIPT ──
    if (-not $existingTxt -or $Force) {

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

        # 🔴 HARD VALIDATION: Ensure file actually exists after generation
        if (-not (Test-Path -LiteralPath $txt)) {
            Write-Host "  -> ERROR: transcript not found after generation" -ForegroundColor Red
            continue
        }

        $existingTxt = Get-Item -LiteralPath $txt -ErrorAction SilentlyContinue
        Write-Host "  -> Transcript saved" -ForegroundColor Green

        $uploadDt = Get-UploadDate $v.Id
        if ($uploadDt) {
            Set-FileDate $txt $uploadDt
            Write-Host "  -> Dated: $($uploadDt.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
        }
    }

    # 🔴 SECOND HARD GATE: Prevent crash if transcript is missing before outline
    if (-not (Test-Path -LiteralPath $txt)) {
        Write-Host "  -> ERROR: transcript missing, skipping outline" -ForegroundColor Red
        continue
    }

    # ── OUTLINE ──
    if (-not $existingMd -or $Force) {

        Write-Host "  -> Outline..." -ForegroundColor Cyan

        if (Get-Outline $txt $md) {
            Write-Host "  -> Saved" -ForegroundColor Green

            $existingMd = Get-Item -LiteralPath $md -ErrorAction SilentlyContinue

            if (-not $uploadDt) {
                $uploadDt = Get-UploadDate $v.Id
            }

            if ($uploadDt) {
                Set-FileDate $md $uploadDt
            }
        }
        else {
            Write-Host "  -> Outline skipped/failed" -ForegroundColor DarkGray
        }
    }

    $processed++
}

# Cleanup temp
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

if ($Normalize) {
    Write-Host "`nNormalize: $renamed renamed, $restamped restamped / $total videos" -ForegroundColor Cyan
} else {
    Write-Host "`nDone: $processed / $total" -ForegroundColor Cyan
}
