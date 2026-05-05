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
- 🔁 **Rename-Resilient Matching**: Video ID-based lookup with **regex-safe escaping** — survives YouTube title changes and handles IDs with special characters (`-`, `_`, etc.)
- 🧹 **Auto-Duplicate Cleanup**: Removes stale unnumbered files from pre-numbering runs during rename normalization
- ⚡ **Incremental Processing**: Skips processed videos unless `-Force` is used
- 🔄 **Normalize Mode**: `-Normalize` renames + restamps existing files only — never regenerates content (safe for bulk maintenance)
- 🔒 **Privacy-Aware**: All processing happens locally; no external APIs required; **zero hardcoded paths**
- 🛡️ **Hard Validation Gates**: Prevents false success messages and crashes when files fail to generate
- 🪄 **One-Click Setup**: Fresh Windows install? Run `helpers/setup.ps1` to auto-install dependencies

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
        │
        ├─► [Normalize Mode?] ──► Rename files to canonical format
        │                        │
        │                        ├─► Remove duplicate files with same [ID]
        │                        │
        │                        └─► Restamp timestamps to YouTube upload date
        │                        └─► Skip content generation entirely
        │
        └─► [Normal Mode]
             │
             ├─► Try: Download English auto-captions (.vtt)
             │    └─► Convert VTT → clean .txt transcript
             │    └─► 🔴 Hard validation: confirm file exists
             │
             ├─► Fallback: Run helpers/yt2txt.ps1 → Whisper transcription
             │    └─► Track files before/after for reliable detection
             │    └─► Output: .txt transcript
             │
             ├─► 🔴 Pre-outline gate: skip if transcript missing
             │
             └─► Optional: Send transcript to Ollama → Generate "Content Brief" .md
                  └─► Save to: $ObsidianRoot/Channel/Collection/Video [ID].md

        Post-processing:
        ├─► Set file timestamps to match YouTube upload date
        ├─► Rename existing files if video title changed (regex-safe ID matching)
        └─► Clean up duplicate files with same ID from legacy runs
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

### 🪄 Option A: One-Click Setup (Windows, Fresh Install)

```powershell
# Run PowerShell as Administrator, then:
iwr https://raw.githubusercontent.com/asuspades/playlist2vault/main/helpers/setup.ps1 -OutFile setup.ps1
.\setup.ps1
```

This script will:
- ✅ Check/update PowerShell execution policy
- ✅ Install `yt-dlp`, `Node.js`, and `Git` via Winget (with manual fallbacks)
- ✅ Clone the repo to `~\playlist2vault`
- ✅ Scaffold `config.local.ps1` with sensible defaults
- ✅ Verify all tools are working post-install

> ⚠️ **Note**: Some installs may require you to **reopen PowerShell** for PATH changes to take effect.

---

### 🛠️ Option B: Manual Setup (All Platforms)

#### 1. Clone the Repo

```powershell
git clone https://github.com/asuspades/playlist2vault.git
cd playlist2vault
```

#### 2. Configure Paths (Choose One)

##### Option A: Environment Variables (Recommended for CI/automation)
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

##### Option B: Local Config File (Git-Ignored — Recommended for personal use)
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

> 📁 Both `playlist2vault.ps1` and `helpers/yt2txt.ps1` share the same config system via `config.local.ps1` (automatically gitignored).

#### 3. Run the Script

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

# 🔄 Normalize mode: rename + restamp existing files only (no regeneration)
.\playlist2vault.ps1 -Source PL... -Normalize

# Normalize with dry-run to preview changes
.\playlist2vault.ps1 -Source PL... -Normalize -DryRun
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
| `-UseWhisper` | `switch` | `$false` | Skip captions; use Whisper directly *(deprecated: captions always tried first)* |
| `-NoWhisperFallback` | `switch` | `$false` | Disable Whisper fallback if captions fail |
| `-CookieBrowser` | `string` | `"firefox"` | Browser for cookie auth: `firefox`, `chrome`, `edge`, `safari`, `brave` |
| `-DryRun` | `switch` | `$false` | Show what would be processed (no writes) |
| `-Normalize` | `switch` | `$false` | **Maintenance mode**: rename files to canonical format + restamp timestamps; never regenerates transcripts or outlines |

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
- **ID**: YouTube video ID in brackets — enables rename resilience and regex-safe matching

### Key Behaviors
> ✅ **Regex-Safe ID Matching**: Video IDs are escaped with `[regex]::Escape()` before file lookup — prevents mis-matching IDs containing special characters like `-` (e.g., `1ywSf4Gt-kY` → `1ywSf4Gt\-kY`)  
> ✅ **Prefer-Exact-Stem Lookup**: When multiple files share the same `[ID]`, the script prioritizes the file matching the exact target filename, then numbered files, then first-found  
> ✅ **Auto-Duplicate Cleanup**: After renaming a file to the canonical `position title [ID].ext` format, any remaining stale files with the same ID are automatically removed  
> ✅ **Timestamp Normalization**: File creation/modification dates are set to the video's YouTube upload date for chronological sorting  
> ✅ **Independent Outputs**: Transcripts (`.txt`) and outlines (`.md`) are saved separately — you can re-run with `-NoOutline` to regenerate only outlines  
> ✅ **Skip Logic**: Existing files are skipped unless `-Force` is passed  
> ✅ **Hard Validation Gates**: Transcript generation confirms file existence before proceeding; outline generation skips if transcript is missing — prevents crashes and false success messages  
> ✅ **Normalize Mode**: When `-Normalize` is used, the script only renames existing files to the canonical format and restamps timestamps — no network calls, no transcription, no LLM usage. Safe for bulk maintenance.

---

## 🧰 Helper Scripts

### `helpers/yt2txt.ps1` — Whisper Transcription Fallback

This optional helper handles Whisper transcription when YouTube captions aren't available.

#### When It Runs
- Automatically invoked by `playlist2vault.ps1` when caption download fails (unless `-NoWhisperFallback`)
- Can also be run standalone for one-off transcription tasks

#### Standalone Usage
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

#### Parameters
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

---

### `helpers/setup.ps1` — Windows Dependency Installer

> 🪄 **New users on Windows**: Start here.

Automates the setup of `playlist2vault` on a fresh Windows installation.

#### What It Does
- ✅ Checks and updates PowerShell execution policy (`RemoteSigned`)
- ✅ Detects or installs Winget (with manual fallback instructions)
- ✅ Installs required tools: `yt-dlp`, `Node.js`, `Git`
- ✅ Clones the repo to `~\playlist2vault`
- ✅ Scaffolds `config.local.ps1` from template (or creates minimal config)
- ✅ Verifies all tools are in PATH and working
- ✅ Prints clear next-step instructions

#### Usage
```powershell
# Run PowerShell as Administrator (recommended)
iwr https://raw.githubusercontent.com/asuspades/playlist2vault/main/helpers/setup.ps1 -OutFile setup.ps1
.\setup.ps1
```

> 💡 **Tip**: If installs succeed but commands aren't found, **close and reopen PowerShell** to refresh your PATH.

---

## 🔐 Privacy & Security

- 🔒 **No data leaves your machine** unless you explicitly enable external APIs
- 🍪 Browser cookies are used *only* by `yt-dlp` for authentication; never stored or transmitted by this script
- 🧹 Temporary files are written to `$env:TEMP\vault_{GUID}` and cleaned up post-run
- 🤖 Ollama requests go to `http://127.0.0.1:11434` — fully local, no cloud dependency
- 🛡️ **Regex-Safe File Operations**: Video IDs are escaped before use in file pattern matching — prevents accidental operations on wrong files due to special characters in IDs
- 🚫 **Before contributing**: Run the leak checker to ensure no personal paths are committed:
  ```powershell
  # Scan for hardcoded personal paths, usernames, or absolute C:\ paths
  Select-String -Path .\*.ps1 -Pattern "C:\\Users\\[^\\]+\\|OneDrive|\\Users\\[a-zA-Z]+" -CaseSensitive
  ```

### Configuration Security Model
Paths are resolved in this order (highest precedence first):
1. **Environment Variables** (`$env:PV_*`) — ideal for CI/automation, never committed
2. **Local Config** (`config.local.ps1`) — gitignored by default, for personal overrides
3. **Safe Defaults** — relative to script root or user Documents folder

> ✅ This ensures the script is **GitHub-safe by default**: no hardcoded usernames, no absolute paths, no secrets in source.

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
| Existing files not being renamed | The script matches by `[VIDEO_ID]` using regex-safe escaping — if you manually renamed files, restore the `[ID]` suffix for auto-renaming to work |
| Duplicate files with same ID appearing | The script auto-cleans duplicates after rename; if you see leftovers, they may be from a pre-v1.2 run — manual deletion is safe |
| `ERROR: transcript not found after generation` | Check disk space, permissions, or antivirus interference; retry with `-Force` or inspect `helpers/yt2txt.ps1` output |
| `Normalize: 0 renamed, 0 restamped` | Files may already be in canonical format with correct timestamps; use `-DryRun` to preview what would change |
| `setup.ps1` fails at Winget step | Winget may not be installed on your Windows version. Follow the manual install links printed by the script, or install via Scoop: `iwr -useb get.scoop.sh \| iex` |
| Commands not found after setup | PATH changes may require a new PowerShell session. Close and reopen your terminal, or run `refreshenv` if using Chocolatey. |

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feat/whisper-turbo`
3. Test changes with `-DryRun` first
4. Run the leak checker before pushing:
   ```powershell
   # Scan for hardcoded personal paths, usernames, or absolute paths
   Select-String -Path .\*.ps1 -Pattern "C:\\Users\\[^\\]+\\|OneDrive|\\Users\\[a-zA-Z]+" -CaseSensitive
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
- [ ] Unit tests for `Find-ByVideoId` regex escaping edge cases
- [ ] `-Normalize` dry-run summary report (what would be renamed/restamped)
- [ ] `setup.sh` for WSL/Linux/macOS parity with `helpers/setup.ps1`

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
> **Re-run Safely**: Thanks to regex-safe ID-based matching, you can re-run the script after renaming videos on YouTube — existing transcripts/outlines will be auto-renamed to match, duplicates cleaned up, no data loss.
>
> **Migration from Pre-v1.2**: If you have unnumbered files from older runs, the script will auto-detect them by `[ID]`, rename to the new `position title [ID].ext` format, and clean up any duplicates. No manual intervention needed.
>
> **Bulk Maintenance with `-Normalize`**: Use `-Normalize` to fix naming + timestamps across your entire vault without re-downloading or re-transcribing. Combine with `-DryRun` first to preview changes. Safe, fast, and idempotent.
>
> **Fresh Windows Install?**: Skip manual setup — run `helpers/setup.ps1` to auto-install dependencies and scaffold your config.

```markdown
<!-- Add this badge to your Obsidian notes -->
[![Source](https://img.shields.io/badge/Source-playlist2vault-blue?logo=github)](https://github.com/asuspades/playlist2vault)
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
