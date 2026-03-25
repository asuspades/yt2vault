# 🎬 playlist2vault

> Convert YouTube **playlists** or **channel content** (`/streams`, `/videos`, `/shorts`) into structured Obsidian notes — with auto-captions, Whisper fallback, and LLM-generated outlines.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Obsidian](https://img.shields.io/badge/Obsidian-md-black?logo=obsidian)](https://obsidian.md)

---

## ✨ Features

- 🔗 **Dual Input Modes**: Accepts playlist URLs/IDs *or* `@channel/streams`, `/videos`, `/shorts` URLs
- 📥 **Auto-Metadata**: Resolves channel name, collection type, and video IDs automatically
- 🎙️ **Caption-First**: Downloads English auto-captions via `yt-dlp` (no GPU required)
- 🤖 **Whisper Fallback**: Falls back to local Whisper transcription via `helpers/yt2txt.ps1` if captions unavailable
- 🧠 **LLM Outlines**: Generates structured "Content Brief" markdown via Ollama (optional)
- 📁 **Obsidian-Ready**: Outputs clean `.md` files organized by `Channel/Collection/Video`
- 🔢 **Positional Filenames**: Files named `01 Title [ID].txt` for correct chronological sorting
- 🕐 **Timestamp Normalization**: File creation/modification dates set to YouTube upload date
- 🔁 **Rename Resilience**: Skip logic matches by video ID — survives YouTube title changes
- ⚡ **Incremental Processing**: Skips processed videos unless `-Force` is used
- 🔒 **Privacy-Aware**: All processing happens locally; no external APIs required

---

## 🔄 Workflow

```
YouTube Source (Playlist or Channel /streams, /videos, /shorts)
                     │
                     ▼
        [ yt-dlp + cookies + Node.js runtime ]
                     │
                     ▼
        Resolve metadata → Channel + Collection
                     │
                     ▼
        For each video:
        ├─► Try: Download English auto-captions (.vtt)
        │    └─► Convert VTT → clean .txt transcript
        │
        ├─► Fallback: Run helpers/yt2txt.ps1 → Whisper transcription
        │    └─► Output: .txt transcript
        │
        └─► Optional: Send transcript to Ollama → Generate "Content Brief" .md
             └─► Save to: $ObsidianRoot/Channel/Collection/Video [ID].md

        After processing:
        └─► Set file timestamps to match YouTube upload date
        └─► Rename existing files if video title changed (ID-based matching)
```

---

## 📋 Requirements

| Tool | Required | Purpose | Install |
|------|----------|---------|---------|
| **PowerShell 5.1+** | ✅ | Runtime | [Windows](https://learn.microsoft.com/powershell) / [Cross-platform](https://github.com/PowerShell/PowerShell) |
| **yt-dlp** | ✅ | Playlist/video metadata + caption download | `winget install yt-dlp` or [github.com/yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) |
| **Node.js** | ✅ | JS runtime for yt-dlp (required by some YouTube pages) | [nodejs.org](https://nodejs.org) |
| **Browser** (Firefox/Chrome/Edge) | ⚠️ | Cookie extraction for authenticated/age-restricted content | Install normally |
| **Ollama** | Optional | Local LLM for outline generation | [ollama.com](https://ollama.com) + `ollama pull gemma3:27b` |
| **Whisper** | Optional | Fallback transcription when captions unavailable | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) + `helpers/yt2txt.ps1` |

> 💡 **No GPU?** No problem. The script prefers YouTube captions first — Whisper is only used if needed.

---

## 🚀 Quick Start

### 1. Clone the Repo

```powershell
git clone https://github.com/yourname/playlist2vault.git
cd playlist2vault
```

### 2. Configure Paths (Choose One)

#### Option A: Environment Variables (Recommended)
Add to your `$PROFILE` or system environment variables:
```powershell
# Core paths
$env:PV_OBSIDIAN    = "C:\Users\You\Obsidian\Vaults\Youtube Channel Vault"
$env:PV_TRANSCRIPTS = "D:\Archives\YouTube\Transcripts"

# Helper script paths (for Whisper fallback)
$env:PV_YT2TXT      = "C:\tools\yt2txt.ps1"           # Or use relative default
$env:PV_WHISPER_DIR = "E:\AI\Whisper"
$env:PV_AUDIO_DIR   = "D:\Media\YouTube"

# Runtime config
$env:PV_NODE_EXE    = "node"  # Assumes node.exe is in $env:PATH
```

#### Option B: Local Config File (Git-Ignored)
```powershell
# Copy the example template
Copy-Item config.local.ps1.example config.local.ps1

# Edit config.local.ps1 with your paths:
$script:ConfigOverride = @{
    ObsidianRoot   = "C:\Users\You\Obsidian\Vaults\Youtube Channel Vault"
    TranscriptRoot = "D:\Archives\YouTube\Transcripts"
    Yt2TxtScript   = "C:\tools\yt2txt.ps1"
    WhisperDir     = "E:\AI\Whisper"
    AudioDir       = "D:\Media\YouTube"
    NodeExe        = "node"
}
```

> 📁 Both `playlist2vault.ps1` and `helpers/yt2txt.ps1` share the same config system.

### 3. Run the Script

```powershell
# Process a playlist (URL or raw ID)
.\playlist2vault.ps1 -Source "https://youtube.com/playlist?list=PL..."

# Process a channel's livestreams
.\playlist2vault.ps1 -Source "https://youtube.com/@channel/streams"

# Process a channel's regular videos
.\playlist2vault.ps1 -Source "https://youtube.com/@channel/videos"

# Process a channel's Shorts
.\playlist2vault.ps1 -Source "https://youtube.com/@channel/shorts"

# Limit to 10 oldest videos, skip outlines
.\playlist2vault.ps1 -Source PL... -Limit 10 -Oldest -NoOutline

# Force re-process everything, use Chrome cookies
.\playlist2vault.ps1 -Source PL... -Force -CookieBrowser chrome

# Dry run: see what would be processed without writing files
.\playlist2vault.ps1 -Source PL... -DryRun
```

---

## ⚙️ Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Source` | `string` | *(required)* | Playlist URL/ID **or** channel `/streams`, `/videos`, or `/shorts` URL |
| `-Model` | `string` | `"gemma3:27b"` | Ollama model for outline generation |
| `-Limit` | `int` | `0` (all) | Process only the first N videos |
| `-Oldest` | `switch` | `$false` | Process oldest videos first (default: newest) |
| `-Force` | `switch` | `$false` | Re-process videos even if outputs exist |
| `-NoOutline` | `switch` | `$false` | Skip LLM outline generation |
| `-UseWhisper` | `switch` | `$false` | Skip captions; use Whisper directly |
| `-NoWhisperFallback` | `switch` | `$false` | Disable Whisper fallback if captions fail |
| `-CookieBrowser` | `string` | `"firefox"` | Browser for cookie auth: `firefox`, `chrome`, `edge`, `safari`, `brave` |
| `-DryRun` | `switch` | `$false` | Show what would be processed (no writes) |

---

## 📁 Output Structure

```
📦 Your Documents/
└── 📁 YouTube Transcripts/
    └── 📁 {Channel Name}/
        └── 📄 01 Video Title [ABC123].txt   ← Full transcript (position-padded)

📦 Your Obsidian Vault/
└── 📁 Youtube Channel Vault/
    └── 📁 {Channel Name}/
        └── 📁 {Collection}/                  # Playlist name OR "Livestream"/"Videos"/"Shorts"
            └── 📄 01 Video Title [ABC123].md ← AI-generated Content Brief
```

### Filename Format
```
{zero-padded-position} {sanitized-title} [{youtube-video-id}].{ext}
```
- **Position**: Zero-padded based on total count (`01`, `02`, ... `10`) for correct lexical sorting
- **Title**: Sanitized (invalid chars removed) + channel prefix stripped
- **ID**: YouTube video ID in brackets — enables rename resilience

### Key Behaviors
> ✅ **Rename Resilience**: Files are matched by `[ID]` — if a video title changes on YouTube, existing files are auto-renamed to the new canonical name  
> ✅ **Timestamp Normalization**: File creation/modification dates are set to the video's YouTube upload date for chronological sorting  
> ✅ **Independent Outputs**: Transcripts (`.txt`) and outlines (`.md`) are saved separately — you can re-run with `-NoOutline` to regenerate only outlines  
> ✅ **Skip Logic**: Existing files are skipped unless `-Force` is passed

---

## 🧰 Helper Script: `helpers/yt2txt.ps1`

This optional helper handles Whisper transcription fallback when YouTube captions aren't available.

### When It Runs
- Automatically invoked by `playlist2vault.ps1` when caption download fails (unless `-NoWhisperFallback`)
- Can also be run standalone for one-off transcription tasks

### Standalone Usage
```powershell
# Basic transcription
.\helpers\yt2txt.ps1 -Url "https://youtube.com/watch?v=ABC123"

# Custom model + faster engine
.\helpers\yt2txt.ps1 -Url "https://youtube.com/watch?v=ABC123" `
    -Model "large-v2" -Engine "faster" -Preset "fast"

# Output to custom directories
.\helpers\yt2txt.ps1 -Url "https://youtube.com/watch?v=ABC123" `
    -DownloadDir "D:\Temp" -WhisperDir "E:\Transcripts"

# Use Chrome cookies instead of Firefox
.\helpers\yt2txt.ps1 -Url "https://youtube.com/watch?v=ABC123" -CookieBrowser chrome
```

### Parameters
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Url` | *(required)* | YouTube or Rumble video URL |
| `-DownloadDir` | `./data/audio` | Where to save downloaded MP3 |
| `-WhisperDir` | `./data/whisper` | Where to save transcription output |
| `-TranscriberPath` | auto-detect | Path to your `Transcribe-GPU.ps1` or equivalent |
| `-Engine` | `"faster"` | `"faster"` or `"whisper"` backend |
| `-Preset` | `"max"` | `"fast"`, `"balanced"`, or `"max"` quality |
| `-Model` | `"medium.en"` | Whisper model name |
| `-CookieBrowser` | `"firefox"` | Browser for cookie auth: `firefox`, `chrome`, `edge`, `safari`, `brave` |
| `-NoResample16k` | `$false` | Skip audio resampling to 16kHz |
| `-NoVAD` | `$false` | Skip voice activity detection pre-processing |
| `-WordTimestamps` | `$false` | Include word-level timestamps in output |

> 🔗 See `config.local.ps1.example` for shared configuration between both scripts.

---

## 🔐 Privacy & Security

- 🔒 **No data leaves your machine** unless you explicitly enable external APIs
- 🍪 Browser cookies are used *only* by `yt-dlp` for authentication; never stored or transmitted by this script
- 🧹 Temporary files are written to `$env:TEMP\vault_{GUID}` and cleaned up post-run
- 🤖 Ollama requests go to `http://127.0.0.1:11434` — fully local, no cloud dependency
- 🚫 **Before contributing**: Run a quick leak check:
  ```powershell
  # Scan for hardcoded personal paths
  Select-String -Path .\*.ps1 -Pattern "C:\\Users\\[^\\]+\\|OneDrive" -CaseSensitive
  ```

---

## 🛠️ Troubleshooting

| Issue | Solution |
|-------|----------|
| `Input must be a playlist URL/ID or a channel /streams, /videos, or /shorts URL` | Ensure your `-Source` matches `list=PL...`, `^PL...`, or `@handle/(streams|videos|shorts)` format |
| `Failed to load playlist` | Verify `yt-dlp` is in `$env:PATH`; try `-CookieBrowser chrome` if using Chrome; ensure Node.js is installed |
| `No captions found` | Video may lack auto-captions; ensure `-NoWhisperFallback` is *not* set and `helpers/yt2txt.ps1` is configured |
| `Yt2TxtScript not found` | Set `$env:PV_YT2TXT` or edit `config.local.ps1` to point to your `yt2txt.ps1` helper |
| `Ollama error: Connection refused` | Start Ollama first: `ollama serve`; verify model: `ollama pull gemma3:27b` |
| `Node.js runtime error` | Ensure Node is installed and accessible; set `$env:PV_NODE_EXE = "node"` or full path like `node:C:\Program Files\nodejs\node.exe` |
| Files not sorting chronologically | Ensure your file explorer/Obsidian is sorting by "Date created" or "Date modified" — the script sets these to YouTube upload date |
| Existing files not being renamed | The script matches by `[VIDEO_ID]` — if you manually renamed files, restore the `[ID]` suffix for auto-renaming to work |

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feat/whisper-turbo`
3. Test changes with `-DryRun` first
4. Run the leak checker before pushing:
   ```powershell
   Select-String -Path .\*.ps1 -Pattern "C:\\Users\\[^\\]+\\|OneDrive" -CaseSensitive
   ```
5. Submit a PR with a clear description

💡 **Ideas welcome**:
- [ ] Support for private playlists via exported cookie file (`--cookies` flag)
- [ ] Custom prompt templates for outlines (YAML/JSON config)
- [ ] Progress bar / verbose logging toggle (`-Verbose` support)
- [ ] Docker wrapper for cross-platform Whisper
- [ ] Parallel video processing with `-ThrottleLimit`
- [ ] Frontmatter injection for Obsidian (tags, aliases, upload date)
- [ ] Support for other platforms (Rumble, Twitch VODs) via yt-dlp

---

## 📄 License

MIT © 2026. Free for personal and commercial use.  
*This tool is not affiliated with YouTube, Google, Obsidian, Ollama, or Whisper.*

---

> 🎯 **Pro Tips**
>
> **Obsidian Integration**: Combine with [Obsidian's "Watch" plugin](https://github.com/obsidian-community/obsidian-community-plugins) to auto-reload new notes as they're generated.
>
> **Chronological Browsing**: Because file timestamps match YouTube upload dates, you can sort your vault folder by "Date modified" to browse videos in true chronological order — even if you processed them out of sequence.
>
> **Re-run Safely**: Thanks to ID-based matching, you can re-run the script after renaming videos on YouTube — existing transcripts/outlines will be auto-renamed to match, no duplicates created.

```markdown
<!-- Add this badge to your Obsidian notes -->
[![Source](https://img.shields.io/badge/Source-playlist2vault-blue?logo=github)](https://github.com/yourname/playlist2vault)
```

---

<details>
<summary>📋 MIT License Template (click to expand)</summary>

```text
MIT License

Copyright (c) 2026 Asuspades

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
</details>
