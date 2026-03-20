# playlist-to-vault

Convert a YouTube playlist into an Obsidian-ready vault — transcripts + AI-generated outlines, fully automated.

## What it does

- Resolves channel and playlist name from any playlist URL
- Downloads captions via `yt-dlp` (no GPU required)
- Falls back to Whisper transcription if captions are unavailable
- Generates structured markdown outlines via Ollama
- Saves transcripts to `Documents\YouTube Transcripts\<Channel>`
- Saves outlines to your Obsidian Series Vault
- Skips already-processed videos unless `-Force` is passed

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | ✅ | Caption/audio download |
| [Ollama](https://ollama.com) | Optional | AI outline generation |
| [Whisper / faster-whisper](https://github.com/SYSTRAN/faster-whisper) | Optional | Transcription fallback |
| Firefox (or other browser) | Optional | Cookie auth for age-restricted/private videos |

## Setup

### 1. Configure paths

**Option A — Environment variables (recommended):**

```powershell
$env:PLAYLIST_VAULT_YT2TXT   = "C:\path\to\helpers\yt2txt.ps1"
$env:PLAYLIST_VAULT_WHISPER  = "C:\path\to\Whisper"
$env:PLAYLIST_VAULT_AUDIO    = "C:\path\to\YouTube"
$env:PLAYLIST_VAULT_OBSIDIAN = "C:\path\to\Obsidian\Series Vault"
```

**Option B — Local config file (gitignored):**

```powershell
Copy-Item config.local.ps1.example config.local.ps1
# Edit config.local.ps1 with your paths
```

### 2. Run

```powershell
# Basic usage (prompts for URL)
.\playlist-to-vault.ps1

# Pass URL directly
.\playlist-to-vault.ps1 -Playlist "https://www.youtube.com/playlist?list=PLxxxxxx"

# Process oldest-first, limit to 10 videos
.\playlist-to-vault.ps1 -Playlist PLxxxxxx -Oldest -Limit 10

# Force re-process everything
.\playlist-to-vault.ps1 -Playlist PLxxxxxx -Force

# Skip outline generation
.\playlist-to-vault.ps1 -Playlist PLxxxxxx -NoOutline

# Use Chrome cookies instead of Firefox
.\playlist-to-vault.ps1 -Playlist PLxxxxxx -CookieBrowser chrome
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Playlist` | *(prompted)* | Playlist URL or ID |
| `-Model` | `gemma3:12b` | Ollama model for outlines |
| `-Limit` | `0` (all) | Max videos to process |
| `-Oldest` | off | Process oldest-first |
| `-Force` | off | Re-process existing files |
| `-NoOutline` | off | Skip outline generation |
| `-UseWhisper` | off | Skip captions, go straight to Whisper |
| `-NoWhisperFallback` | off | Disable Whisper fallback |
| `-CookieBrowser` | `firefox` | Browser for cookie auth |
| `-DryRun` | off | *(reserved)* |

## Output structure

```
Documents\
└── YouTube Transcripts\
    └── <Channel>\
        └── <Video Title> [<VideoId>].txt

Obsidian\Series Vault\
└── <Channel>\
    └── <Playlist>\
        └── <Video Title> [<VideoId>].md
```
