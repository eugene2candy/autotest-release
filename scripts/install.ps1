# =============================================================================
# Autotest Installer - Windows
# =============================================================================
# One-line install:
#   iwr -useb https://raw.githubusercontent.com/eugene2candy/autotest-release/main/scripts/install.ps1 | iex
#
# This script:
#   1. Detects archive format (.zip or .tar.gz)
#   2. Downloads the latest Autotest release from GitHub (or uses a local file)
#   3. Extracts to %LOCALAPPDATA%\autotest
#   4. Installs backend npm dependencies (source release only; exe releases skip this)
#   5. Adds the 'autotest' CLI command to PATH
#   6. Prints next-step instructions
#
# Supports both executable-based releases (no Node.js required) and
# source-based releases (requires Node.js 20+).
#
# Environment variables:
#   AUTOTEST_VERSION  - Install a specific version (default: latest)
#   AUTOTEST_DIR      - Install directory (default: %LOCALAPPDATA%\autotest)
#   AUTOTEST_ARCHIVE  - Use a local .zip or .tar.gz file instead of downloading
#   GITHUB_REPO       - GitHub repository (default: eugene2candy/autotest-release)
# =============================================================================

$ErrorActionPreference = "Stop"

# Configuration
$GitHubRepo = if ($env:GITHUB_REPO) { $env:GITHUB_REPO } else { "eugene2candy/autotest-release" }
$InstallDir = if ($env:AUTOTEST_DIR) { $env:AUTOTEST_DIR } else { "$env:LOCALAPPDATA\autotest" }
$Version = $env:AUTOTEST_VERSION
$LocalArchive = $env:AUTOTEST_ARCHIVE

Write-Host ""
Write-Host "=========================================" -ForegroundColor Blue
Write-Host "  Autotest Installer                    " -ForegroundColor Blue
Write-Host "=========================================" -ForegroundColor Blue
Write-Host ""

# =============================================================================
# Step 1: Check prerequisites
# =============================================================================
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

# Check for Node.js (only required for source-based releases; exe releases embed Node.js)
$hasNode = $false
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Host "  Node.js not found (only needed for source-based releases)" -ForegroundColor Yellow
} else {
    $nodeVersion = (node --version) -replace 'v', '' -replace '\..*', ''
    if ([int]$nodeVersion -lt 20) {
        Write-Host "  Node.js $(node --version) found (20+ recommended)" -ForegroundColor Yellow
    } else {
        Write-Host "  Node.js $(node --version) found" -ForegroundColor Green
        $hasNode = $true
    }
}

# =============================================================================
# Step 2: Determine version
# =============================================================================
Write-Host "Determining version..." -ForegroundColor Yellow

$tempDir = Join-Path $env:TEMP "autotest-install-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

# Track archive format for extraction later
$archiveFormat = $null  # "zip" or "targz"
$tempArchive = $null

if ($LocalArchive) {
    # --- Local archive mode ---
    # Resolve relative paths against the current working directory
    if (-not [System.IO.Path]::IsPathRooted($LocalArchive)) {
        $LocalArchive = Join-Path (Get-Location).Path $LocalArchive
    }
    if (-not (Test-Path $LocalArchive)) {
        Write-Host "Error: Local archive not found: $LocalArchive" -ForegroundColor Red
        exit 1
    }
    # Resolve to full absolute path (expand ../, ./, etc.)
    $LocalArchive = (Resolve-Path $LocalArchive).Path

    # Detect format from extension
    if ($LocalArchive -match '\.zip$') {
        $archiveFormat = "zip"
        $tempArchive = Join-Path $tempDir "autotest.zip"
    } elseif ($LocalArchive -match '\.tar\.gz$' -or $LocalArchive -match '\.tgz$') {
        $archiveFormat = "targz"
        $tempArchive = Join-Path $tempDir "autotest.tar.gz"
    } else {
        Write-Host "Error: Unsupported archive format. Use .zip or .tar.gz" -ForegroundColor Red
        exit 1
    }

    # Extract version from filename if not explicitly set
    if (-not $Version) {
        $baseName = [System.IO.Path]::GetFileName($LocalArchive)
        if ($baseName -match '^autotest-(.+)\.(zip|tar\.gz|tgz)$') {
            $Version = $Matches[1]
        } else {
            $Version = "local"
        }
    }

    Copy-Item -Path $LocalArchive -Destination $tempArchive
    Write-Host "  Version: $Version (local archive)" -ForegroundColor White
} else {
    # --- Remote download mode ---
    if (-not $Version) {
        # Method 1: GitHub API (may fail due to rate limiting for unauthenticated requests)
        $latestUrl = "https://api.github.com/repos/$GitHubRepo/releases/latest"
        try {
            $response = Invoke-RestMethod -Uri $latestUrl -ErrorAction Stop
            $Version = $response.tag_name -replace '^v', ''
        } catch {
            $apiError = $_.Exception.Message
            Write-Host "  GitHub API failed: $apiError" -ForegroundColor Gray
            Write-Host "  Trying fallback method..." -ForegroundColor Gray
        }

        # Method 2: Fallback — follow the /releases/latest redirect to get the tag from the URL
        # GitHub redirects /releases/latest to /releases/tag/vX.Y.Z, so we can extract the version
        if (-not $Version) {
            try {
                $releasesUrl = "https://github.com/$GitHubRepo/releases/latest"
                $headResponse = Invoke-WebRequest -Uri $releasesUrl -Method Head -MaximumRedirection 0 -ErrorAction SilentlyContinue
                $redirectUrl = $headResponse.Headers.Location
                if (-not $redirectUrl) {
                    # PowerShell 7+ may auto-follow redirects; check the final URL
                    $getResponse = Invoke-WebRequest -Uri $releasesUrl -ErrorAction Stop
                    $redirectUrl = $getResponse.BaseResponse.RequestMessage.RequestUri.ToString()
                }
                if ($redirectUrl -match '/releases/tag/v?(.+)$') {
                    $Version = $Matches[1]
                }
            } catch {
                # Silently continue to error below
            }
        }

        if (-not $Version) {
            Write-Host "Error: Could not determine latest version from GitHub." -ForegroundColor Red
            Write-Host "  API URL: $latestUrl" -ForegroundColor Gray
            Write-Host "  This may be caused by GitHub API rate limiting." -ForegroundColor Gray
            Write-Host "  Try again in a few minutes, or specify a version:" -ForegroundColor Yellow
            Write-Host "  `$env:AUTOTEST_VERSION='1.0.0'; iwr -useb ... | iex" -ForegroundColor Yellow
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            exit 1
        }
    }

    Write-Host "  Version: $Version" -ForegroundColor White

    # =============================================================================
    # Step 3: Download release archive
    # =============================================================================
    Write-Host "Downloading Autotest v${Version}..." -ForegroundColor Yellow

    # Try platform-specific executable release first, then fall back to generic source release
    $exeZipUrl = "https://github.com/$GitHubRepo/releases/download/v$Version/autotest-$Version-win-x64.zip"
    $genericZipUrl = "https://github.com/$GitHubRepo/releases/download/v$Version/autotest-$Version.zip"
    $genericTargzUrl = "https://github.com/$GitHubRepo/releases/download/v$Version/autotest-$Version.tar.gz"
    $downloaded = $false

    # Attempt platform-specific .zip download (exe release)
    $tempArchive = Join-Path $tempDir "autotest.zip"
    Write-Host "  Trying: $exeZipUrl" -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $exeZipUrl -OutFile $tempArchive -ErrorAction Stop
        $archiveFormat = "zip"
        $downloaded = $true
        Write-Host "  Downloaded (executable release)" -ForegroundColor Green
    } catch {
        # Exe release not available, try generic .zip (source release)
        Write-Host "  Executable release not found, trying source release..." -ForegroundColor Gray
        Write-Host "  Trying: $genericZipUrl" -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $genericZipUrl -OutFile $tempArchive -ErrorAction Stop
            $archiveFormat = "zip"
            $downloaded = $true
            Write-Host "  Downloaded (.zip)" -ForegroundColor Green
        } catch {
            # .zip not available, try .tar.gz
            Write-Host "  .zip not found, trying .tar.gz..." -ForegroundColor Gray
            $tempArchive = Join-Path $tempDir "autotest.tar.gz"
            try {
                Invoke-WebRequest -Uri $genericTargzUrl -OutFile $tempArchive -ErrorAction Stop
                $archiveFormat = "targz"
                $downloaded = $true
                Write-Host "  Downloaded (.tar.gz)" -ForegroundColor Green
            } catch {
                Write-Host "Error: Download failed" -ForegroundColor Red
                Write-Host "  Tried: $exeZipUrl" -ForegroundColor Gray
                Write-Host "  Tried: $genericZipUrl" -ForegroundColor Gray
                Write-Host "  Tried: $genericTargzUrl" -ForegroundColor Gray
                Write-Host "  Make sure the release exists at: https://github.com/$GitHubRepo/releases" -ForegroundColor Gray
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
                exit 1
            }
        }
    }
}

# =============================================================================
# Step 4: Extract to install directory (in-place upgrade)
# =============================================================================
Write-Host "Installing to $InstallDir..." -ForegroundColor Yellow

# Stop running autotest services before updating
if (Test-Path $InstallDir) {
    Write-Host "  Existing installation found, performing in-place upgrade..." -ForegroundColor Yellow

    # Try to stop services via autotest CLI
    $autotestBin = Join-Path $InstallDir "bin\autotest.ps1"
    if (Test-Path $autotestBin) {
        Write-Host "  Stopping running services..." -ForegroundColor Yellow
        try {
            & powershell -File $autotestBin stop 2>$null
        } catch { }
        Start-Sleep -Seconds 2
    }

    # Kill any remaining autotest-related processes by checking PID file
    $pidFile = Join-Path $InstallDir "logs\autotest.pid"
    if (Test-Path $pidFile) {
        $pid = (Get-Content $pidFile -Raw).Trim()
        if ($pid) {
            try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch { }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    # Remove old application files but preserve user data
    # User data: exports/, packages/, data/, .env, logs/
    $preserveDirs = @("exports", "packages", "data", "logs")
    $preserveFiles = @(".env")

    # Migrate data from old location (backend/data/) to new location (data/)
    # Old source-based releases stored data at backend/data/; new exe releases use data/
    $oldDataDir = Join-Path $InstallDir "backend\data"
    $newDataDir = Join-Path $InstallDir "data"
    if ((Test-Path $oldDataDir) -and -not (Test-Path $newDataDir)) {
        Write-Host "  Migrating data from backend\data\ to data\..." -ForegroundColor Yellow
        Copy-Item -Path $oldDataDir -Destination $newDataDir -Recurse -Force
        Write-Host "  Data migrated" -ForegroundColor Green
    } elseif ((Test-Path $oldDataDir) -and (Test-Path $newDataDir)) {
        # Both exist — merge old into new (don't overwrite existing files)
        Write-Host "  Merging backend\data\ into data\..." -ForegroundColor Yellow
        Get-ChildItem -Path $oldDataDir -Recurse | ForEach-Object {
            $destPath = $_.FullName.Replace($oldDataDir, $newDataDir)
            if (-not (Test-Path $destPath)) {
                if ($_.PSIsContainer) {
                    New-Item -ItemType Directory -Force -Path $destPath | Out-Null
                } else {
                    $destDir = Split-Path -Parent $destPath
                    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                    Copy-Item -Path $_.FullName -Destination $destPath
                }
            }
        }
        Write-Host "  Data merged" -ForegroundColor Green
    }

    Get-ChildItem -Path $InstallDir -Force | Where-Object {
        $name = $_.Name
        -not ($preserveDirs -contains $name) -and -not ($preserveFiles -contains $name)
    } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Extract archive based on format
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

if ($archiveFormat -eq "zip") {
    # .zip: extract to temp, then copy contents (Expand-Archive has no --strip-components)
    $extractDir = Join-Path $tempDir "extracted"
    Expand-Archive -Path $tempArchive -DestinationPath $extractDir -Force

    # Find the top-level directory inside the zip (e.g., autotest-1.0.0/)
    $innerDirs = Get-ChildItem -Path $extractDir -Directory
    if ($innerDirs.Count -eq 1) {
        # Single top-level folder — copy its contents (strip one component)
        # Use Copy-Item to merge with preserved user data directories
        Get-ChildItem -Path $innerDirs[0].FullName | Copy-Item -Destination $InstallDir -Recurse -Force
    } else {
        # No single wrapper dir — copy everything directly
        Get-ChildItem -Path $extractDir | Copy-Item -Destination $InstallDir -Recurse -Force
    }
} else {
    # .tar.gz: use tar which overwrites files but merges directories naturally
    tar -xzf $tempArchive -C $InstallDir --strip-components=1
}

# Cleanup temp files
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

Write-Host "  Extracted" -ForegroundColor Green

# Detect release type: executable-based or source-based
$isExeRelease = Test-Path (Join-Path $InstallDir "bin\autotest-server.exe")

# =============================================================================
# Step 5: Install backend dependencies (source releases only)
# =============================================================================
if (-not $isExeRelease) {
    if (-not $hasNode) {
        Write-Host "Error: This is a source-based release and requires Node.js 20+." -ForegroundColor Red
        Write-Host "Install Node.js: winget install OpenJS.NodeJS.LTS" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Installing backend dependencies..." -ForegroundColor Yellow
    Push-Location (Join-Path $InstallDir "backend")
    try {
        npm install --production 2>&1 | Out-Null
        Write-Host "  Backend dependencies installed" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to install backend dependencies" -ForegroundColor Red
        Write-Host "  Try manually: cd $InstallDir\backend && npm install" -ForegroundColor Yellow
        Pop-Location
        exit 1
    }
    Pop-Location
} else {
    Write-Host "Executable release detected — skipping npm install" -ForegroundColor Green
}

# =============================================================================
# Step 6: Install scripts dependencies (source releases only)
# =============================================================================
$scriptsPackageJson = Join-Path $InstallDir "scripts\package.json"
if ((-not $isExeRelease) -and (Test-Path $scriptsPackageJson)) {
    Write-Host "Installing scripts dependencies..." -ForegroundColor Yellow
    Push-Location (Join-Path $InstallDir "scripts")
    try {
        npm install --production 2>&1 | Out-Null
        Write-Host "  Scripts dependencies installed" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Scripts npm install failed (non-critical)" -ForegroundColor Yellow
    }
    Pop-Location
}

# =============================================================================
# Step 7: Add to PATH
# =============================================================================
Write-Host "Configuring PATH..." -ForegroundColor Yellow

$binDir = Join-Path $InstallDir "bin"

# Set AUTOTEST_DIR environment variable
[Environment]::SetEnvironmentVariable("AUTOTEST_DIR", $InstallDir, "User")
$env:AUTOTEST_DIR = $InstallDir

# Add bin directory to user PATH
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$binDir;$currentPath", "User")
    Write-Host "  Added $binDir to PATH" -ForegroundColor Green
} else {
    Write-Host "  PATH already configured" -ForegroundColor Green
}

# Update current session PATH
$env:PATH = "$binDir;$env:PATH"

# =============================================================================
# Done!
# =============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Autotest v${Version} Installed!       " -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Installation: $InstallDir"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host ""
Write-Host "  1. Close and reopen PowerShell (to pick up PATH changes)" -ForegroundColor White
Write-Host ""
Write-Host "  2. Set up prerequisites (Android SDK, Appium, Java):" -ForegroundColor White
Write-Host "     autotest setup" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. Start all services:" -ForegroundColor White
Write-Host "     autotest start" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Or launch the emulator separately:" -ForegroundColor White
Write-Host "     autotest emulator" -ForegroundColor Yellow
Write-Host ""
Write-Host "Other commands:" -ForegroundColor White
Write-Host "  autotest run        - Run test sets (CLI)" -ForegroundColor Gray
Write-Host "  autotest update     - Update to latest version" -ForegroundColor Gray
Write-Host "  autotest version    - Show version" -ForegroundColor Gray
Write-Host "  autotest help       - Show all commands" -ForegroundColor Gray
Write-Host ""
