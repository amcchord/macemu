#!/bin/bash
# This script installs required dependencies, clones the macemu repository
# and builds BasiliskII and SheepShaver on macOS.

set -e

# Determine if Xcode Command Line Tools are installed
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode command line tools not found. Installing..."
  xcode-select --install || true
  echo "Please rerun this script after Xcode command line tools are installed."
  exit 1
fi

# Install Homebrew if missing
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -d "/opt/homebrew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# Install required packages
brew install git autoconf automake libtool pkg-config sdl2 gmp mpfr

# Clone repository if not already present
ROOT_DIR="$(pwd)"
if [[ ! -d BasiliskII || ! -d SheepShaver ]]; then
  git clone https://github.com/kanjitalk755/macemu.git macemu
  ROOT_DIR="$ROOT_DIR/macemu"
fi

cd "$ROOT_DIR"

# Build BasiliskII
cd BasiliskII/src/MacOSX
xcodebuild -project BasiliskII.xcodeproj -configuration Release build
cd ../../..

# Build SheepShaver
cd SheepShaver/src/MacOSX
xcodebuild -project SheepShaver.xcodeproj -configuration Release build
cd ../../..


echo "Build complete. Applications are located in:"
echo "  BasiliskII/src/MacOSX/build/Release/BasiliskII.app"
echo "  SheepShaver/src/MacOSX/build/Release/SheepShaver.app"
