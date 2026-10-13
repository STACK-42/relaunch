#!/bin/bash
# Installs (or removes) the latest Relaunch release.
#
#   curl -fsSL https://relaunch.stack42.tech/install.sh | bash
#   curl -fsSL https://relaunch.stack42.tech/install.sh | bash -s -- --uninstall
#
# It downloads Relaunch.zip from the latest GitHub release, checks it against
# the published SHA-256, copies Relaunch.app into /Applications (or
# ~/Applications when /Applications isn't writable) and opens it.
#
# For testing: RELAUNCH_BASE_URL overrides where release files come from, and
# RELAUNCH_INSTALL_DIR overrides where the app is installed.

set -euo pipefail

REPO="STACK-42/relaunch"
BASE_URL="${RELAUNCH_BASE_URL:-https://github.com/$REPO/releases/latest/download}"
BUNDLE_ID="com.ahmedalghali.Relaunch"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

check_system() {
  [ "$(uname -s)" = "Darwin" ] || fail "Relaunch only runs on macOS."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] || fail "Relaunch needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."
  [ "$(uname -m)" = "arm64" ] || fail "Release builds are for Apple silicon. On Intel, build from source: https://github.com/$REPO#build-and-install"
}

install_dir() {
  if [ -n "${RELAUNCH_INSTALL_DIR:-}" ]; then echo "$RELAUNCH_INSTALL_DIR"
  elif [ -w /Applications ]; then echo /Applications; else echo "$HOME/Applications"; fi
}

install() {
  check_system
  local dest
  # Global, so the EXIT trap can still see it after this function returns.
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  say "Downloading Relaunch…"
  curl -fL --progress-bar "$BASE_URL/Relaunch.zip" -o "$tmp/Relaunch.zip" \
    || fail "Download failed. Is there a published release at https://github.com/$REPO/releases ?"
  curl -fsSL "$BASE_URL/Relaunch.zip.sha256" -o "$tmp/Relaunch.zip.sha256" \
    || fail "Couldn't download the checksum file."

  say "Verifying checksum…"
  local expected actual
  expected="$(awk '{print $1}' "$tmp/Relaunch.zip.sha256")"
  actual="$(shasum -a 256 "$tmp/Relaunch.zip" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] \
    || fail "Checksum mismatch: the download may be corrupted or tampered with. Nothing was installed."

  ditto -x -k "$tmp/Relaunch.zip" "$tmp/unpacked"
  [ -d "$tmp/unpacked/Relaunch.app" ] || fail "The download didn't contain Relaunch.app."

  dest="$(install_dir)"
  mkdir -p "$dest"
  pkill -x Relaunch 2>/dev/null || true
  rm -rf "$dest/Relaunch.app"
  ditto "$tmp/unpacked/Relaunch.app" "$dest/Relaunch.app"
  say "Installed $dest/Relaunch.app"

  open "$dest/Relaunch.app"
  say "Done. Press ⌥Space, or drag Relaunch from $dest into your Dock and click it."
}

uninstall() {
  say "Removing Relaunch…"
  # Newer versions uninstall themselves: they also turn macOS's own pinch back
  # on and remove the login item. Older ones only need the files removed.
  for app in /Applications/Relaunch.app "$HOME/Applications/Relaunch.app"; do
    bin="$app/Contents/MacOS/Relaunch"
    if [ -x "$bin" ] && [ "$(defaults read "$app/Contents/Info" RelaunchSelfUninstall 2>/dev/null)" = 1 ]; then
      "$bin" --uninstall || true
    fi
  done
  pkill -x Relaunch 2>/dev/null || true
  rm -rf /Applications/Relaunch.app "$HOME/Applications/Relaunch.app"
  rm -rf "$HOME/Library/Application Support/Relaunch"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  say "Relaunch has been removed. Your old Launchpad database was never touched."
}

main() {
  case "${1:-}" in
    --uninstall) uninstall ;;
    "" | --install) install ;;
    -h | --help) echo "Usage: install.sh [--install | --uninstall]" ;;
    *) fail "Unknown option: $1 (use --uninstall)" ;;
  esac
}

# Everything runs from here, so a partially downloaded script does nothing.
main "$@"
