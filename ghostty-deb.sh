#!/usr/bin/env bash
set -euo pipefail

# Detect architecture early — fail fast on unsupported platforms
DEB_ARCH="$(dpkg --print-architecture)"
case "$(uname -m)" in
  x86_64)  ZIG_ARCH="x86_64" ;;
  aarch64) ZIG_ARCH="aarch64" ;;
  *)
    echo "ERROR: Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$EUID" -eq 0 ]]; then
  echo "ERROR: Do not run this script as root. It invokes sudo where needed." >&2
  exit 1
fi

GHOSTTY_BASE="$HOME/ghostty-install"
GHOSTTY_DIR="$GHOSTTY_BASE/ghostty"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"

APP_ID="com.mitchellh.ghostty"
GHOSTTY_BIN="/usr/local/bin/ghostty"

PKG_NAME="ghostty-deb-local"
PKG_MAINTAINER="ghostty-deb@bradsec.com"
BUILD_ROOT="$GHOSTTY_BASE/deb-build"
DEB_OUT="$GHOSTTY_BASE"

ZIG_BASE="/opt/zig"
ZIG_CURRENT="$ZIG_BASE/current"
ZIG_BIN="$ZIG_CURRENT/zig"

BACKUP_FILE="$HOME/.config/ghostty-default-terminal"
SOURCE_UPDATED=false
YES=false
_ZIG_TARBALL=""
_ZIG_EXTRACTED=""
_BUILT_DEB=""

cleanup_on_error() {
  set +e
  [[ -n "$_ZIG_TARBALL" ]]   && rm -f "$_ZIG_TARBALL"
  [[ -n "$_ZIG_EXTRACTED" ]] && rm -rf "$_ZIG_EXTRACTED"
  [[ -d "$BUILD_ROOT" ]]     && rm -rf "$BUILD_ROOT"
}

trap 'echo "ERROR: script failed at line $LINENO" >&2; cleanup_on_error' ERR

usage() {
  cat <<EOF
Usage: $0 [option]

Options:
  --install           Clone Ghostty, install required Zig, build .deb, install it
  --update            Pull latest Ghostty, install required Zig, build .deb, install it
  --make-default      Make Ghostty the default x-terminal-emulator
  --restore-default   Restore original Debian terminal
  --uninstall         Remove Ghostty package and restore original terminal
  --build-deb         Build .deb only, do not install
  --version           Show installed version and latest available upstream
  --yes, -y           Auto-accept all prompts (for unattended runs)
  --help              Show help
EOF
}

install_deps() {
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    ca-certificates \
    xz-utils \
    dpkg-dev \
    blueprint-compiler \
    libgtk-4-dev \
    libgtk4-layer-shell-dev \
    libadwaita-1-dev \
    libxml2-utils \
    gettext \
    desktop-file-utils \
    libgtk-4-bin
}

clone_if_needed() {
  mkdir -p "$GHOSTTY_BASE"
  if [[ ! -d "$GHOSTTY_DIR/.git" ]]; then
    git clone "$GHOSTTY_REPO" "$GHOSTTY_DIR"
  fi
}

update_source() {
  git -C "$GHOSTTY_DIR" fetch origin --prune

  local current tracking fetch
  current="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
  tracking="$(git -C "$GHOSTTY_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    || tracking="origin/HEAD"
  fetch="$(git -C "$GHOSTTY_DIR" rev-parse "$tracking" 2>/dev/null)" || {
    echo "WARNING: Could not resolve upstream tracking branch; assuming update is needed." >&2
    SOURCE_UPDATED=true
    return 0
  }

  if [[ "$current" == "$fetch" ]]; then
    SOURCE_UPDATED=false
    return 0
  fi

  if ! git -C "$GHOSTTY_DIR" diff --quiet HEAD 2>/dev/null; then
    echo "WARNING: Ghostty source has local modifications that will be discarded."
    if [[ "$YES" != true ]]; then
      local answer
      read -r -p "Continue and discard local changes? [y/N] " answer
      if [[ "${answer,,}" != "y" ]]; then
        echo "Aborted."
        exit 0
      fi
    fi
  fi

  git -C "$GHOSTTY_DIR" reset --hard "$tracking"
  SOURCE_UPDATED=true
}

detect_zig_version() {
  local version=""

  if [[ -f "$GHOSTTY_DIR/build.zig.zon" ]]; then
    version="$(grep -Eo 'minimum_zig_version\s*=\s*"[0-9]+\.[0-9]+\.[0-9]+"' "$GHOSTTY_DIR/build.zig.zon" \
      | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' \
      | head -n1)" || true
  fi

  if [[ -z "$version" && -f "$GHOSTTY_DIR/src/build/zig.zig" ]]; then
    version="$(grep -Eo 'parse\("[0-9]+\.[0-9]+\.[0-9]+"\)' "$GHOSTTY_DIR/src/build/zig.zig" \
      | head -n1 \
      | sed -E 's/parse\("([0-9]+\.[0-9]+\.[0-9]+)"\)/\1/')" || true
  fi

  if [[ -z "$version" ]]; then
    echo "ERROR: Could not detect required Zig version." >&2
    echo "  Checked: $GHOSTTY_DIR/build.zig.zon" >&2
    echo "  Checked: $GHOSTTY_DIR/src/build/zig.zig" >&2
    if [[ -f "$GHOSTTY_DIR/build.zig.zon" ]]; then
      echo "  Relevant lines in build.zig.zon:" >&2
      grep -i zig "$GHOSTTY_DIR/build.zig.zon" | head -5 >&2 || true
    fi
    exit 1
  fi

  echo "$version"
}

install_zig() {
  local version="$1"
  local zig_dir="$ZIG_BASE/$version"

  if [[ -x "$zig_dir/zig" ]]; then
    echo "Zig $version already installed."
  else
    echo "==> Installing Zig $version..."

    local tarball_new="zig-${ZIG_ARCH}-linux-${version}.tar.xz"
    local tarball_old="zig-linux-${ZIG_ARCH}-${version}.tar.xz"
    local tarball_path_new="/tmp/${tarball_new}"
    local tarball_path_old="/tmp/${tarball_old}"

    local url_new="https://ziglang.org/download/${version}/${tarball_new}"
    local url_old="https://ziglang.org/download/${version}/${tarball_old}"

    rm -rf "/tmp/zig-${ZIG_ARCH}-linux-${version}" \
           "/tmp/zig-linux-${ZIG_ARCH}-${version}" \
           "$tarball_path_new" \
           "$tarball_path_old"

    local expected_sha256=""
    expected_sha256="$(curl -fsSL "https://ziglang.org/download/index.json" \
      | jq -r ".\"${version}\".\"${ZIG_ARCH}-linux\".shasum // empty" 2>/dev/null)" || true

    local extracted_dir tarball_path
    if curl -fLo "$tarball_path_new" "$url_new" 2>/dev/null; then
      _ZIG_TARBALL="$tarball_path_new"
      extracted_dir="/tmp/zig-${ZIG_ARCH}-linux-${version}"
      tarball_path="$tarball_path_new"
    elif curl -fLo "$tarball_path_old" "$url_old"; then
      _ZIG_TARBALL="$tarball_path_old"
      extracted_dir="/tmp/zig-linux-${ZIG_ARCH}-${version}"
      tarball_path="$tarball_path_old"
    else
      echo "ERROR: Could not download Zig $version." >&2
      echo "Tried:" >&2
      echo "  $url_new" >&2
      echo "  $url_old" >&2
      exit 1
    fi

    if [[ -n "$expected_sha256" ]]; then
      echo "==> Verifying Zig tarball checksum..."
      local actual_sha256
      actual_sha256="$(sha256sum "$tarball_path" | awk '{print $1}')"
      if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        echo "ERROR: Checksum mismatch for $(basename "$tarball_path")" >&2
        echo "  Expected: $expected_sha256" >&2
        echo "  Got:      $actual_sha256" >&2
        rm -f "$tarball_path"
        _ZIG_TARBALL=""
        exit 1
      fi
      echo "Checksum OK."
    else
      echo "WARNING: Could not fetch checksum for Zig $version — skipping verification."
    fi

    tar -xf "$tarball_path" -C /tmp
    _ZIG_EXTRACTED="$extracted_dir"
    rm -f "$tarball_path"
    _ZIG_TARBALL=""

    sudo mkdir -p "$ZIG_BASE"
    sudo rm -rf "$zig_dir"
    sudo mv "$extracted_dir" "$zig_dir"
    _ZIG_EXTRACTED=""
  fi

  sudo ln -sfn "$zig_dir" "$ZIG_CURRENT"

  echo "Using Zig: $("$ZIG_BIN" version)"
}

ghostty_version() {
  local tag
  tag="$(git -C "$GHOSTTY_DIR" describe --tags --always --dirty 2>/dev/null || echo "unknown")"

  local version="${tag#v}"

  if [[ ! "$version" =~ ^[0-9] ]]; then
    local date_suffix
    date_suffix="$(git -C "$GHOSTTY_DIR" log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)"
    version="0~${version}+${date_suffix}"
  fi

  echo "${version//[^A-Za-z0-9.+~-]/-}"
}

build_deb() {
  local version="$1"
  local pkg_dir="$BUILD_ROOT/pkg"
  local install_prefix="$pkg_dir/usr/local"
  local deb_file="$DEB_OUT/${PKG_NAME}_${version}_${DEB_ARCH}.deb"

  rm -rf "$BUILD_ROOT"
  rm -f "$DEB_OUT/${PKG_NAME}_"*"_${DEB_ARCH}.deb"
  mkdir -p "$install_prefix" "$DEB_OUT"

  echo "==> Cleaning old Zig build output..."
  rm -rf "$GHOSTTY_DIR/.zig-cache" "$GHOSTTY_DIR/zig-out"

  echo "==> Building and installing Ghostty into package staging..."
  (
    cd "$GHOSTTY_DIR"
    "$ZIG_BIN" build -p "$install_prefix" -Doptimize=ReleaseFast
  )

  if [[ ! -x "$install_prefix/bin/ghostty" ]]; then
    echo "ERROR: Build completed but ghostty binary not found at $install_prefix/bin/ghostty" >&2
    exit 1
  fi

  echo "==> Ensuring GNOME icons are packaged..."
  for size in 16 32 64 128 256 512 1024; do
    local src="$GHOSTTY_DIR/images/gnome/${size}.png"
    local dest="$install_prefix/share/icons/hicolor/${size}x${size}/apps/${APP_ID}.png"
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
    fi
  done

  echo "==> Fixing desktop launcher in package..."
  if [[ -f "$install_prefix/share/applications/${APP_ID}.desktop" ]]; then
    sed -i \
      -e "s|^Exec=.*|Exec=${GHOSTTY_BIN}|g" \
      -e "s|^Icon=.*|Icon=${APP_ID}|g" \
      "$install_prefix/share/applications/${APP_ID}.desktop"
  fi

  mkdir -p "$pkg_dir/DEBIAN"

  cat > "$pkg_dir/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $version
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Maintainer: $PKG_MAINTAINER
Depends: libc6, libgtk-4-1, libadwaita-1-0, libgtk4-layer-shell0
Description: Ghostty terminal emulator local Zig build for Debian
 Locally built Ghostty terminal emulator packaged as a Debian package.
EOF

  cat > "$pkg_dir/DEBIAN/postinst" <<'DEBSCRIPT'
#!/bin/sh
set -eu
gtk-update-icon-cache -f /usr/local/share/icons/hicolor >/dev/null 2>&1 || true
update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
DEBSCRIPT

  cat > "$pkg_dir/DEBIAN/postrm" <<'DEBSCRIPT'
#!/bin/sh
set -eu
gtk-update-icon-cache -f /usr/local/share/icons/hicolor >/dev/null 2>&1 || true
update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
DEBSCRIPT

  chmod 755 "$pkg_dir/DEBIAN/postinst" "$pkg_dir/DEBIAN/postrm"

  echo "==> Building .deb..."
  dpkg-deb --root-owner-group --build "$pkg_dir" "$deb_file"

  _BUILT_DEB="$deb_file"
  echo "Built package: $deb_file"
}

install_latest_deb() {
  local deb_file="$1"

  if [[ ! -f "$deb_file" ]]; then
    echo "ERROR: .deb not found: $deb_file" >&2
    exit 1
  fi

  echo "==> Installing $deb_file..."
  sudo apt-get install -y --no-install-recommends "$deb_file"

  mkdir -p "$HOME/.local/share/applications"

  if [[ -f "/usr/local/share/applications/${APP_ID}.desktop" ]]; then
    cp "/usr/local/share/applications/${APP_ID}.desktop" \
       "$HOME/.local/share/applications/${APP_ID}.desktop"
  fi

  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

  "$GHOSTTY_BIN" --version || true
}

save_original_terminal() {
  mkdir -p "$HOME/.config"
  if [[ -f "$BACKUP_FILE" ]]; then
    echo "Original terminal backup already exists: $(cat "$BACKUP_FILE")"
    return
  fi
  local current
  current="$(update-alternatives --query x-terminal-emulator 2>/dev/null | awk '/Value:/ {print $2}')"
  if [[ -n "${current:-}" && "$current" != "$GHOSTTY_BIN" ]]; then
    echo "$current" > "$BACKUP_FILE"
    echo "Saved original terminal: $current"
  fi
}

make_default() {
  if [[ ! -x "$GHOSTTY_BIN" ]]; then
    echo "ERROR: Ghostty is not installed at $GHOSTTY_BIN" >&2
    exit 1
  fi

  save_original_terminal

  sudo update-alternatives --install \
    /usr/bin/x-terminal-emulator \
    x-terminal-emulator \
    "$GHOSTTY_BIN" 60

  sudo update-alternatives --set x-terminal-emulator "$GHOSTTY_BIN"

  echo "Ghostty is now the default terminal."
}

restore_default() {
  if [[ -f "$BACKUP_FILE" ]]; then
    local original
    original="$(cat "$BACKUP_FILE")"
    if [[ -x "$original" ]]; then
      sudo update-alternatives --set x-terminal-emulator "$original"
      echo "Restored terminal to: $original"
      return
    else
      echo "WARNING: Saved terminal $original no longer exists." >&2
    fi
  fi

  local terminal
  for terminal in \
    /usr/bin/gnome-terminal.wrapper \
    /usr/bin/kgx \
    /usr/bin/xterm \
    /usr/bin/konsole \
    /usr/bin/xfce4-terminal \
    /usr/bin/rxvt; do
    if [[ -x "$terminal" ]]; then
      sudo update-alternatives --set x-terminal-emulator "$terminal" \
        && echo "Restored terminal to: $terminal" \
        && return
    fi
  done

  echo "Could not auto-restore default terminal." >&2
  echo "Available alternatives:" >&2
  update-alternatives --list x-terminal-emulator >&2 || true
  echo "Run: sudo update-alternatives --config x-terminal-emulator" >&2
  return 1
}

uninstall_ghostty() {
  restore_default \
    || echo "WARNING: Could not restore default terminal — run 'sudo update-alternatives --config x-terminal-emulator' manually." >&2

  sudo update-alternatives --remove x-terminal-emulator "$GHOSTTY_BIN" 2>/dev/null || true

  local apt_err
  apt_err="$(mktemp)"
  sudo apt-get purge -y "$PKG_NAME" 2>"$apt_err" || true
  grep -v "not empty so not removed" "$apt_err" >&2 || true
  rm -f "$apt_err"

  rm -f "$HOME/.local/share/applications/${APP_ID}.desktop"

  sudo rm -f "$GHOSTTY_BIN"
  sudo rm -f "/usr/local/share/applications/${APP_ID}.desktop"
  sudo rm -f "/usr/local/share/metainfo/${APP_ID}.metainfo.xml"
  sudo rm -f "/usr/local/share/dbus-1/services/${APP_ID}.service"
  sudo rm -f "/usr/local/share/systemd/user/app-${APP_ID}.service"
  sudo find /usr/local/share/icons/hicolor -name "${APP_ID}.png" -delete 2>/dev/null || true

  sudo gtk-update-icon-cache -f /usr/local/share/icons/hicolor 2>/dev/null || true
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  sudo update-desktop-database /usr/local/share/applications 2>/dev/null || true

  echo "Ghostty uninstalled."
}

prompt_make_default() {
  local current
  current="$(update-alternatives --query x-terminal-emulator 2>/dev/null | awk '/Value:/ {print $2}')"

  if [[ "${current:-}" == "$GHOSTTY_BIN" ]]; then
    echo "Ghostty is already the default terminal."
    return
  fi

  if [[ "$YES" == true ]]; then
    make_default
    return
  fi

  local answer
  read -r -p "Make Ghostty the default terminal emulator? [y/N] " answer
  if [[ "${answer,,}" == "y" ]]; then
    make_default
  fi
}

compile_and_package() {
  local zig_version
  zig_version="$(detect_zig_version)"
  echo "Detected required Zig version: $zig_version"
  install_zig "$zig_version"

  local version
  version="$(ghostty_version)"
  build_deb "$version"
}

install_ghostty() {
  install_deps
  clone_if_needed
  compile_and_package
  install_latest_deb "$_BUILT_DEB"
  prompt_make_default
}

update_ghostty() {
  # git must be available before we can clone; install it if missing
  if ! command -v git &>/dev/null; then
    echo "==> git not found; installing before source check..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends git
  fi

  clone_if_needed
  update_source

  if [[ "$SOURCE_UPDATED" == false ]]; then
    echo "Ghostty is already up to date. Nothing to rebuild."
    exit 0
  fi

  install_deps
  compile_and_package
  install_latest_deb "$_BUILT_DEB"
  prompt_make_default
}

build_deb_only() {
  install_deps
  clone_if_needed
  compile_and_package
}

show_version() {
  echo "Installed:"
  local installed_output=""
  if [[ -x "$GHOSTTY_BIN" ]]; then
    installed_output="$("$GHOSTTY_BIN" --version)"
    echo "$installed_output"
  else
    echo "  Ghostty is not installed."
  fi

  echo ""
  echo "Latest stable release (upstream):"
  local latest=""
  latest="$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote --tags "$GHOSTTY_REPO" 2>/dev/null \
    | grep -Eo 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1 \
    | sed 's|refs/tags/||')" || true

  if [[ -n "${latest:-}" ]]; then
    echo "  $latest"
  else
    echo "  Could not determine latest version (check network/repo access)."
  fi

  if echo "$installed_output" | grep -q 'channel: tip'; then
    echo ""
    echo "  Note: your install is a tip (main branch) build, which is ahead of"
    echo "  the latest stable release. This is expected if you built from main."
  fi
}

confirm() {
  [[ "$YES" == true ]] && return
  local answer
  read -r -p "Continue? [y/N] " answer
  if [[ "${answer,,}" != "y" ]]; then
    echo "Aborted."
    exit 0
  fi
}

# Pre-scan for --yes/-y so it can appear anywhere in the argument list
_ARGS=()
for _arg in "$@"; do
  case "$_arg" in
    --yes|-y) YES=true ;;
    *) _ARGS+=("$_arg") ;;
  esac
done
set -- "${_ARGS[@]+"${_ARGS[@]}"}"
unset _arg _ARGS

case "${1:-}" in
  --install)
    cat <<EOF

  Install Ghostty
  ---------------
  This will:
    - Install build dependencies via apt-get
    - Clone the Ghostty source from GitHub (if not already present)
    - Detect and download the required Zig compiler to /opt/zig
    - Verify the Zig tarball checksum before installing
    - Build Ghostty with -Doptimize=ReleaseFast
    - Package the result as a .deb and install it via apt-get

EOF
    confirm
    install_ghostty
    ;;
  --update)
    cat <<EOF

  Update Ghostty
  --------------
  This will:
    - Check for new commits in the Ghostty upstream repo
    - If up to date: exit without any changes
    - If update available: install/refresh build dependencies, rebuild, and reinstall

EOF
    confirm
    update_ghostty
    ;;
  --make-default)
    cat <<EOF

  Make Ghostty the Default Terminal
  ----------------------------------
  This will:
    - Save your current default terminal to ~/.config/ghostty-default-terminal
    - Register Ghostty with update-alternatives and set it as x-terminal-emulator

EOF
    confirm
    make_default
    ;;
  --restore-default)
    cat <<EOF

  Restore Original Default Terminal
  -----------------------------------
  This will:
    - Read the saved terminal from ~/.config/ghostty-default-terminal
    - Restore it as the active x-terminal-emulator via update-alternatives
    - Fall back to common terminals if no backup is found

EOF
    confirm
    restore_default
    ;;
  --uninstall)
    cat <<EOF

  Uninstall Ghostty
  -----------------
  This will:
    - Restore your original default terminal (if a backup exists)
    - Remove Ghostty from update-alternatives
    - Purge the ghostty-deb-local package via apt-get
    - Delete all installed Ghostty files (binary, icons, desktop entries)

EOF
    confirm
    uninstall_ghostty
    ;;
  --build-deb)
    cat <<EOF

  Build .deb Only
  ---------------
  This will:
    - Install build dependencies via apt-get
    - Clone the Ghostty source from GitHub (if not already present)
    - Detect and download the required Zig compiler to /opt/zig
    - Verify the Zig tarball checksum before installing
    - Build Ghostty and produce a .deb in ~/ghostty-install/
    - The package will NOT be installed

EOF
    confirm
    build_deb_only
    ;;
  --version)
    show_version
    ;;
  --help|-h|"")
    usage
    ;;
  *)
    echo "Unknown option: $1"
    usage
    exit 1
    ;;
esac
