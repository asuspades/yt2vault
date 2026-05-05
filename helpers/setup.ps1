# playlist2vault Setup Script for Windows
# Run this in PowerShell (Admin recommended but not required)

Write-Host "=== 🎬 playlist2vault Windows Setup ===" -ForegroundColor Cyan

# ─────────────────────────────────────────
# 0. Execution Policy Check (critical for fresh installs)
# ─────────────────────────────────────────
Write-Host "`n[0/6] Checking execution policy..." -ForegroundColor Yellow
$execPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($execPolicy -eq 'Restricted') {
    Write-Host "  ⚠ Execution policy is Restricted. Setting to RemoteSigned for current user..." -ForegroundColor Yellow
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
    Write-Host "  ✓ Policy updated. You can revert later with: Set-ExecutionPolicy Restricted -Scope CurrentUser" -ForegroundColor Green
} else {
    Write-Host "  ✓ Execution policy: $execPolicy (no change needed)" -ForegroundColor Green
}

# ─────────────────────────────────────────
# 1. PowerShell version check
# ─────────────────────────────────────────
Write-Host "`n[1/6] Checking PowerShell version..." -ForegroundColor Yellow
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -ge 5) {
    Write-Host "  ✓ PowerShell $psVersion detected" -ForegroundColor Green
} else {
    Write-Host "  ✗ PowerShell 5.1+ required. Current: $psVersion" -ForegroundColor Red
    Write-Host "  → Download: https://aka.ms/PowerShell" -ForegroundColor DarkGray
    exit 1
}

# ─────────────────────────────────────────
# 2. Admin privilege hint (non-blocking)
# ─────────────────────────────────────────
Write-Host "`n[2/6] Checking privileges..." -ForegroundColor Yellow
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "  ✓ Running as Administrator (optimal for installs)" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Not running as Admin. Installs may require manual approval or fail." -ForegroundColor Yellow
    Write-Host "  → To re-run as Admin: Right-click PowerShell → 'Run as administrator'" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────
# 3. Winget availability + fallback
# ─────────────────────────────────────────
Write-Host "`n[3/6] Checking package manager..." -ForegroundColor Yellow
$useWinget = $false
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "  ✓ Winget found" -ForegroundColor Green
    $useWinget = $true
} else {
    Write-Host "  ⚠ Winget not found." -ForegroundColor Yellow
    Write-Host "  → Option A: Install via Microsoft Store (search 'App Installer')" -ForegroundColor DarkGray
    Write-Host "  → Option B: Use Scoop: iwr -useb get.scoop.sh | iex" -ForegroundColor DarkGray
    Write-Host "  → Option C: Install tools manually (links below)" -ForegroundColor DarkGray
}

# Helper function for installs
function Install-WithFallback {
    param($WingetId, $DisplayName, $ManualUrl, $CommandToVerify)
    
    Write-Host "  Installing $DisplayName..." -ForegroundColor Cyan
    
    # Check if already available
    if (Get-Command $CommandToVerify -ErrorAction SilentlyContinue) {
        Write-Host "    ✓ $DisplayName already installed: $(& $CommandToVerify --version 2>$null)" -ForegroundColor Green
        return $true
    }
    
    # Try winget
    if ($useWinget) {
        winget install -e --id $WingetId --silent --accept-source-agreements --accept-package-agreements 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ✓ $DisplayName installed via winget" -ForegroundColor Green
            return $true
        }
    }
    
    # Fallback message
    Write-Host "    ⚠ Could not auto-install $DisplayName." -ForegroundColor Yellow
    Write-Host "      → Manual install: $ManualUrl" -ForegroundColor DarkGray
    return $false
}

# ─────────────────────────────────────────
# 4. Install required tools
# ─────────────────────────────────────────
Write-Host "`n[4/6] Installing required tools..." -ForegroundColor Yellow

Install-WithFallback -WingetId "yt-dlp.yt-dlp" -DisplayName "yt-dlp" -ManualUrl "https://github.com/yt-dlp/yt-dlp/releases" -CommandToVerify "yt-dlp"
Install-WithFallback -WingetId "OpenJS.NodeJS.LTS" -DisplayName "Node.js" -ManualUrl "https://nodejs.org" -CommandToVerify "node"

# ─────────────────────────────────────────
# 5. Install Git if missing
# ─────────────────────────────────────────
Write-Host "`n[5/6] Checking Git..." -ForegroundColor Yellow
Install-WithFallback -WingetId "Git.Git" -DisplayName "Git" -ManualUrl "https://git-scm.com/download/win" -CommandToVerify "git"

# ─────────────────────────────────────────
# 6. Clone repository + setup config
# ─────────────────────────────────────────
Write-Host "`n[6/6] Setting up playlist2vault..." -ForegroundColor Yellow

$targetDir = "$env:USERPROFILE\playlist2vault"
if (Test-Path $targetDir) {
    Write-Host "  ✓ Repository already exists at $targetDir" -ForegroundColor Green
} else {
    git clone https://github.com/asuspades/playlist2vault.git $targetDir 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Cloned to $targetDir" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Clone failed. Try manual download: https://github.com/asuspades/playlist2vault/archive/refs/heads/main.zip" -ForegroundColor Red
        exit 1
    }
}

# Create config file
Set-Location $targetDir
$configExample = "config.local.ps1.example"
$configLocal = "config.local.ps1"

if (Test-Path $configExample) {
    if (-not (Test-Path $configLocal)) {
        Copy-Item $configExample $configLocal
        Write-Host "  ✓ Created $configLocal from template" -ForegroundColor Green
    } else {
        Write-Host "  ✓ $configLocal already exists (preserved)" -ForegroundColor Green
    }
} else {
    Write-Host "  ⚠ Template $configExample not found. Creating minimal config..." -ForegroundColor Yellow
    @'
# Minimal config for playlist2vault
$script:ConfigOverride = @{
    # Required: Set these to your paths
    ObsidianRoot   = "$env:USERPROFILE\Documents\Obsidian\Youtube Channel Vault"
    TranscriptRoot = "$env:USERPROFILE\Documents\YouTube Transcripts"
    
    # Optional: Override helper paths if not using defaults
    # Yt2TxtScript   = "C:\path\to\yt2txt.ps1"
    # WhisperDir     = "C:\path\to\whisper\output"
    # AudioDir       = "C:\path\to\audio\cache"
    # NodeExe        = "node"  # or full path like "C:\Program Files\nodejs\node.exe"
}
'@ | Out-File -FilePath $configLocal -Encoding utf8
    Write-Host "  ✓ Created minimal $configLocal" -ForegroundColor Green
}

# ─────────────────────────────────────────
# 7. Post-install verification
# ─────────────────────────────────────────
Write-Host "`n=== 🔍 Verifying Install ===" -ForegroundColor Cyan

$checks = @{
    "yt-dlp" = { yt-dlp --version 2>$null }
    "node"   = { node --version 2>$null }
    "git"    = { git --version 2>$null }
    "PowerShell script" = { Test-Path ".\playlist2vault.ps1" }
}

$allGood = $true
foreach ($name in $checks.Keys) {
    $result = & $checks[$name]
    if ($result) {
        Write-Host "  ✓ $name: $result" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $name: NOT FOUND" -ForegroundColor Red
        $allGood = $false
    }
}

if (-not $allGood) {
    Write-Host "`n  ⚠ Some tools aren't in PATH yet. Try:" -ForegroundColor Yellow
    Write-Host "    • Closing and reopening PowerShell" -ForegroundColor DarkGray
    Write-Host "    • Running: refreshenv  (if using Chocolatey)" -ForegroundColor DarkGray
    Write-Host "    • Logging out and back in" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────
# 8. Next steps
# ─────────────────────────────────────────
Write-Host "`n=== 🚀 Setup Complete! ===" -ForegroundColor Cyan
Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "1. Edit config:" -ForegroundColor Yellow
Write-Host "   notepad.exe $targetDir\config.local.ps1" -ForegroundColor White
Write-Host "`n2. Set your paths (ObsidianRoot, TranscriptRoot)" -ForegroundColor Yellow
Write-Host "`n3. Test run (dry mode):" -ForegroundColor Yellow
Write-Host "   cd $targetDir" -ForegroundColor White
Write-Host "   .\playlist2vault.ps1 -Source 'https://youtube.com/playlist?list=YOUR_ID' -DryRun" -ForegroundColor White
Write-Host "`n4. Optional: Enable AI outlines" -ForegroundColor Yellow
Write-Host "   • Install Ollama: https://ollama.com" -ForegroundColor White
Write-Host "   • Pull model: ollama pull gemma3:27b" -ForegroundColor White

# Optional tools summary
Write-Host "`n=== 🧰 Optional Enhancements ===" -ForegroundColor Cyan
Write-Host "- Ollama (local LLM outlines): https://ollama.com" -ForegroundColor White
Write-Host "- Whisper (offline transcription): pip install faster-whisper" -ForegroundColor White
Write-Host "- Browser cookies: Install Firefox/Chrome for age-restricted content" -ForegroundColor White
Write-Host "- Obsidian plugins: 'Watch' for auto-reload, 'Dataview' for querying notes" -ForegroundColor White

# Final reminder
Write-Host "`n💡 Tip: Run with -Verbose for detailed logs during first use." -ForegroundColor DarkGray
