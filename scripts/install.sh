#!/bin/bash
# =============================================================================
# Autotest Installer - macOS / Linux
# =============================================================================
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/eugene2candy/autotest-release/main/scripts/install.sh | bash
#
# This script:
#   1. Detects OS and architecture
#   2. Downloads the latest Autotest release from GitHub
#   3. Extracts to ~/.autotest
#   4. Installs backend npm dependencies (source release only; exe releases skip this)
#   5. Adds the 'autotest' CLI command to PATH
#   6. Prints next-step instructions
#
# Supports both executable-based releases (no Node.js required) and
# source-based releases (requires Node.js 20+).
#
# Environment variables:
#   AUTOTEST_VERSION  - Install a specific version (default: latest)
#   AUTOTEST_DIR      - Install directory (default: ~/.autotest)
#   AUTOTEST_ARCHIVE  - Use a local .tar.gz file instead of downloading
#   GITHUB_REPO       - GitHub repository (default: eugene2candy/autotest-release)
# =============================================================================

set -e

# Colors
print_blue()    { printf '\033[0;34m%s\033[0m\n' "$1"; }
print_green()   { printf '\033[0;32m%s\033[0m\n' "$1"; }
print_yellow()  { printf '\033[1;33m%s\033[0m\n' "$1"; }
print_red()     { printf '\033[0;31m%s\033[0m\n' "$1"; }

# Configuration
GITHUB_REPO="${GITHUB_REPO:-eugene2candy/autotest-release}"
INSTALL_DIR="${AUTOTEST_DIR:-$HOME/.autotest}"
VERSION="${AUTOTEST_VERSION:-}"

echo ""
print_blue "========================================="
print_blue "  Autotest Installer                    "
print_blue "========================================="
echo ""

# =============================================================================
# Step 1: Detect OS and architecture
# =============================================================================
print_yellow "Detecting system..."

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    PLATFORM="macOS"
    SETUP_SCRIPT="setup-macos.sh"
    ;;
  Linux)
    PLATFORM="Linux"
    SETUP_SCRIPT="setup-linux.sh"
    ;;
  *)
    print_red "Unsupported OS: $OS"
    echo "For Windows, use: iwr -useb https://raw.githubusercontent.com/eugene2candy/autotest-release/main/scripts/install.ps1 | iex"
    exit 1
    ;;
esac

echo "  Platform: $PLATFORM ($ARCH)"

# =============================================================================
# Step 2: Check prerequisites
# =============================================================================
print_yellow "Checking prerequisites..."

# Check for curl or wget
if command -v curl &>/dev/null; then
  DOWNLOAD="curl -fsSL"
  DOWNLOAD_FILE="curl -fsSL -o"
elif command -v wget &>/dev/null; then
  DOWNLOAD="wget -qO-"
  DOWNLOAD_FILE="wget -qO"
else
  print_red "Error: curl or wget is required"
  exit 1
fi

# Check for tar
if ! command -v tar &>/dev/null; then
  print_red "Error: tar is required"
  exit 1
fi

# Check for Node.js (only required for source-based releases; exe releases embed Node.js)
HAS_NODE=false
if ! command -v node &>/dev/null; then
  print_yellow "  Node.js not found (only needed for source-based releases)"
else
  NODE_VERSION=$(node --version | sed 's/v//' | cut -d. -f1)
  if [ "$NODE_VERSION" -lt 20 ]; then
    print_yellow "  Node.js $(node --version) found (20+ recommended)"
  else
    print_green "Node.js $(node --version) found"
    HAS_NODE=true
  fi
fi

# =============================================================================
# Step 3: Determine version to install
# =============================================================================
print_yellow "Determining version..."

LOCAL_ARCHIVE="${AUTOTEST_ARCHIVE:-}"

if [ -n "$LOCAL_ARCHIVE" ]; then
  # Local archive mode — extract version from filename
  if [ ! -f "$LOCAL_ARCHIVE" ]; then
    print_red "Error: Local archive not found: $LOCAL_ARCHIVE"
    exit 1
  fi
  if [ -z "$VERSION" ]; then
    VERSION=$(basename "$LOCAL_ARCHIVE" | sed 's/autotest-\(.*\)\.tar\.gz/\1/')
    [ "$VERSION" = "$(basename "$LOCAL_ARCHIVE")" ] && VERSION="local"
  fi
  echo "  Version: $VERSION (local archive)"
elif [ -z "$VERSION" ]; then
  # Method 1: GitHub API (may fail due to rate limiting for unauthenticated requests)
  LATEST_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
  if command -v curl &>/dev/null; then
    API_RESPONSE=$(curl -fsSL "$LATEST_URL" 2>&1) || API_RESPONSE=""
    VERSION=$(echo "$API_RESPONSE" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/')
  else
    API_RESPONSE=$(wget -qO- "$LATEST_URL" 2>&1) || API_RESPONSE=""
    VERSION=$(echo "$API_RESPONSE" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/')
  fi

  # Method 2: Fallback — follow the /releases/latest redirect to get the tag from the URL
  # GitHub redirects /releases/latest to /releases/tag/vX.Y.Z
  if [ -z "$VERSION" ]; then
    echo "  GitHub API failed, trying fallback method..."
    RELEASES_URL="https://github.com/${GITHUB_REPO}/releases/latest"
    if command -v curl &>/dev/null; then
      REDIRECT_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASES_URL" 2>/dev/null)
    else
      REDIRECT_URL=$(wget --max-redirect=5 -qO /dev/null --server-response "$RELEASES_URL" 2>&1 | grep -i 'Location:' | tail -1 | sed 's/.*Location: *//;s/\r//')
    fi
    if echo "$REDIRECT_URL" | grep -q '/releases/tag/'; then
      VERSION=$(echo "$REDIRECT_URL" | sed 's|.*/releases/tag/v\{0,1\}||')
    fi
  fi

  if [ -z "$VERSION" ]; then
    print_red "Error: Could not determine latest version from GitHub."
    echo "  API URL: $LATEST_URL"
    echo "  This may be caused by GitHub API rate limiting."
    echo "  Try again in a few minutes, or specify a version:"
    echo "  AUTOTEST_VERSION=1.0.0 curl -fsSL ... | bash"
    exit 1
  fi
  echo "  Version: $VERSION"
else
  echo "  Version: $VERSION"
fi

# =============================================================================
# Step 4: Download release archive (or use local)
# =============================================================================
TEMP_DIR=$(mktemp -d)
TEMP_ARCHIVE="${TEMP_DIR}/autotest.tar.gz"

if [ -n "$LOCAL_ARCHIVE" ]; then
  print_yellow "Using local archive: $LOCAL_ARCHIVE"
  cp "$LOCAL_ARCHIVE" "$TEMP_ARCHIVE"
else
  print_yellow "Downloading Autotest v${VERSION}..."

  # Determine platform-specific archive name
  case "$OS" in
    Darwin)
      case "$ARCH" in
        arm64|aarch64) PLAT_SUFFIX="macos-arm64" ;;
        *)             PLAT_SUFFIX="macos-x64" ;;
      esac
      ;;
    Linux)
      PLAT_SUFFIX="linux-x64"
      ;;
  esac

  # Try platform-specific executable release first, fall back to generic source release
  EXE_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/autotest-${VERSION}-${PLAT_SUFFIX}.tar.gz"
  GENERIC_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/autotest-${VERSION}.tar.gz"
  DOWNLOADED=false

  echo "  Trying: $EXE_URL"
  if $DOWNLOAD_FILE "$TEMP_ARCHIVE" "$EXE_URL" 2>/dev/null && [ -s "$TEMP_ARCHIVE" ]; then
    print_green "Downloaded (executable release)"
    DOWNLOADED=true
  else
    echo "  Executable release not found, trying source release..."
    echo "  Trying: $GENERIC_URL"
    if $DOWNLOAD_FILE "$TEMP_ARCHIVE" "$GENERIC_URL" 2>/dev/null && [ -s "$TEMP_ARCHIVE" ]; then
      print_green "Downloaded (source release)"
      DOWNLOADED=true
    fi
  fi

  if [ "$DOWNLOADED" = "false" ] || [ ! -f "$TEMP_ARCHIVE" ] || [ ! -s "$TEMP_ARCHIVE" ]; then
    print_red "Error: Download failed"
    echo "  Tried: $EXE_URL"
    echo "  Tried: $GENERIC_URL"
    echo "  Make sure the release exists at: https://github.com/${GITHUB_REPO}/releases"
    rm -rf "$TEMP_DIR"
    exit 1
  fi
fi

print_green "Downloaded"

# =============================================================================
# Step 5: Extract to install directory (in-place upgrade)
# =============================================================================
print_yellow "Installing to ${INSTALL_DIR}..."

# Stop running autotest services before updating
if [ -d "$INSTALL_DIR" ]; then
  print_yellow "Existing installation found, performing in-place upgrade..."

  # Try to stop services via autotest CLI
  AUTOTEST_BIN="$INSTALL_DIR/bin/autotest"
  if [ -f "$AUTOTEST_BIN" ]; then
    print_yellow "Stopping running services..."
    bash "$AUTOTEST_BIN" stop 2>/dev/null || true
    sleep 2
  fi

  # Kill any remaining autotest-related processes by checking PID file
  PID_FILE="$INSTALL_DIR/logs/autotest.pid"
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi

  # Remove old application files but preserve user data
  # User data: exports/, packages/, data/, .env, logs/

  # Migrate data from old location (backend/data/) to new location (data/)
  # Old source-based releases stored data at backend/data/; new exe releases use data/
  OLD_DATA_DIR="$INSTALL_DIR/backend/data"
  NEW_DATA_DIR="$INSTALL_DIR/data"
  if [ -d "$OLD_DATA_DIR" ] && [ ! -d "$NEW_DATA_DIR" ]; then
    print_yellow "  Migrating data from backend/data/ to data/..."
    cp -r "$OLD_DATA_DIR" "$NEW_DATA_DIR"
    print_green "  Data migrated"
  elif [ -d "$OLD_DATA_DIR" ] && [ -d "$NEW_DATA_DIR" ]; then
    # Both exist — merge old into new (don't overwrite existing files)
    print_yellow "  Merging backend/data/ into data/..."
    cp -rn "$OLD_DATA_DIR"/* "$NEW_DATA_DIR"/ 2>/dev/null || true
    print_green "  Data merged"
  fi

  for item in "$INSTALL_DIR"/*; do
    name=$(basename "$item")
    case "$name" in
      exports|packages|data|logs) ;; # preserve
      *) rm -rf "$item" ;;
    esac
  done
  # Remove hidden files except .env
  for item in "$INSTALL_DIR"/.*; do
    name=$(basename "$item")
    case "$name" in
      .|..|.env) ;; # preserve
      *) rm -rf "$item" ;;
    esac
  done
fi

# Extract archive
mkdir -p "$INSTALL_DIR"
tar -xzf "$TEMP_ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

# Cleanup temp files
rm -rf "$TEMP_DIR"

print_green "Extracted"

# Detect release type: executable-based or source-based
IS_EXE_RELEASE=false
if [ -f "$INSTALL_DIR/bin/autotest-server" ]; then
  IS_EXE_RELEASE=true
fi

# =============================================================================
# Step 6: Install backend dependencies
# =============================================================================
print_yellow "Installing dependencies..."

if [ "$IS_EXE_RELEASE" = "true" ]; then
  print_green "Executable release detected — skipping npm install"
else
  if [ "$HAS_NODE" = "false" ]; then
    print_red "Error: This is a source-based release and requires Node.js 20+."
    if [ "$PLATFORM" = "macOS" ]; then
      echo "  Install: brew install node"
    else
      echo "  Install: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
    fi
    exit 1
  fi

  print_yellow "Installing backend dependencies..."
  (cd "$INSTALL_DIR/backend" && npm install --production 2>&1) || {
    print_red "Error: Failed to install backend dependencies"
    echo "Try manually: cd $INSTALL_DIR/backend && npm install"
    exit 1
  }
  print_green "Backend dependencies installed"

  # =============================================================================
  # Step 7: Install scripts dependencies (for CLI runner)
  # =============================================================================
  if [ -f "$INSTALL_DIR/scripts/package.json" ]; then
    print_yellow "Installing scripts dependencies..."
    (cd "$INSTALL_DIR/scripts" && npm install --production 2>&1) || true
    print_green "Scripts dependencies installed"
  fi
fi

# =============================================================================
# Step 8: Make scripts executable
# =============================================================================
chmod +x "$INSTALL_DIR/bin/autotest" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bin/autotest-cli" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bin/autotest-server" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true

# =============================================================================
# Step 9: Add to PATH
# =============================================================================
print_yellow "Configuring PATH..."

BIN_DIR="$INSTALL_DIR/bin"
SHELL_CONFIG=""

# Detect shell config file
if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
  SHELL_CONFIG="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ] || [ "$(basename "$SHELL")" = "bash" ]; then
  if [ "$PLATFORM" = "macOS" ]; then
    SHELL_CONFIG="$HOME/.zshrc"  # macOS defaults to zsh
  else
    SHELL_CONFIG="$HOME/.bashrc"
  fi
fi

# Fallback
if [ -z "$SHELL_CONFIG" ]; then
  if [ -f "$HOME/.zshrc" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
  elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_CONFIG="$HOME/.bash_profile"
  else
    SHELL_CONFIG="$HOME/.zshrc"
  fi
fi

# Add to PATH if not already there
if ! grep -q "AUTOTEST_DIR" "$SHELL_CONFIG" 2>/dev/null; then
  echo "" >> "$SHELL_CONFIG"
  echo "# Autotest (added by installer)" >> "$SHELL_CONFIG"
  echo "export AUTOTEST_DIR=\"$INSTALL_DIR\"" >> "$SHELL_CONFIG"
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$SHELL_CONFIG"
  print_green "Added to $SHELL_CONFIG"
else
  print_green "PATH already configured in $SHELL_CONFIG"
fi

# Make available in current session
export PATH="$BIN_DIR:$PATH"

# =============================================================================
# Done!
# =============================================================================
echo ""
print_green "========================================="
print_green "  Autotest v${VERSION} Installed!       "
print_green "========================================="
echo ""
echo "Installation: $INSTALL_DIR"
echo ""
echo "Next steps:"
echo ""
echo "  1. Restart your shell (or run: source $SHELL_CONFIG)"
echo ""
echo "  2. Set up prerequisites (Android SDK, Appium, Java):"
print_yellow "     autotest setup"
echo ""
echo "  3. Start all services:"
print_yellow "     autotest start"
echo ""
echo "  Or launch the emulator separately:"
print_yellow "     autotest emulator"
echo ""
echo "Other commands:"
echo "  autotest run        - Run test sets (CLI)"
echo "  autotest update     - Update to latest version"
echo "  autotest version    - Show version"
echo "  autotest help       - Show all commands"
echo ""
