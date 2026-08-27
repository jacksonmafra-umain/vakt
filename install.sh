#!/bin/bash
#
# Installs VAKT: copies the app into place and clears the download quarantine
# flag that would otherwise make macOS refuse to open it.
#
# Every step is printed before it runs. Read it before you run it — this script
# tells Gatekeeper to trust an app that Apple has not notarised, which is only a
# reasonable thing to do for software you have decided to trust.
#
#   ./install.sh                       install to /Applications and open it
#   ./install.sh --launch-agent        start VAKT at login, and after a force-quit
#   ./install.sh --dest ~/Applications install somewhere else
#   ./install.sh --no-open             install without launching
#   ./install.sh --dry-run             print what would happen, change nothing
#
set -euo pipefail

APP_NAME="VAKT.app"
BUNDLE_ID="com.jacksonmafra.vakt"
AGENT_PLIST="com.jacksonmafra.vakt.plist"

DEST="/Applications"
OPEN_AFTER=yes
INSTALL_AGENT=no
DRY_RUN=no

here() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
SCRIPT_DIR="$(here)"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m warning:\033[0m %s\n' "$1"; }
die()  { printf '\033[31m error:\033[0m %s\n' "$1" >&2; exit 1; }

run() {
    printf '    %s\n' "$*"
    if [ "$DRY_RUN" = no ]; then "$@"; fi
}

# macOS still ships bash 3.2, where "${ARRAY[@]}" on an empty array trips
# `set -u`. So sudo is a wrapper, not an array prefix.
NEEDS_SUDO=no
priv() {
    if [ "$NEEDS_SUDO" = yes ]; then run sudo "$@"; else run "$@"; fi
}

# Writability of the destination, judged on the closest ancestor that exists —
# the directory itself may only be created a step later, and on a dry run it is
# never created at all.
dest_is_writable() {
    local dir="$1"
    while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir="$(dirname "$dir")"; done
    [ -w "$dir" ]
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dest)         DEST="${2:?--dest needs a directory}"; shift 2 ;;
        --no-open)      OPEN_AFTER=no; shift ;;
        --launch-agent) INSTALL_AGENT=yes; shift ;;
        --dry-run)      DRY_RUN=yes; shift ;;
        -h|--help)      sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "unknown option: $1" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "VAKT is a macOS app."

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 14 ]; then
    die "VAKT needs macOS 14 or later. This is $(sw_vers -productVersion)."
fi

SOURCE_APP="$SCRIPT_DIR/$APP_NAME"
[ -d "$SOURCE_APP" ] || die "$APP_NAME is not next to this script. Unzip the release and run it from there."

TARGET="$DEST/$APP_NAME"

if [ "$DRY_RUN" = yes ]; then
    warn "dry run: nothing will be changed."
fi

# 1. Nothing good comes of overwriting a bundle that is currently executing.
if pgrep -qf "$APP_NAME/Contents/MacOS/VAKT"; then
    say "VAKT is running. Stopping it first."
    if launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
        warn "a LaunchAgent is loaded and would relaunch it mid-copy; unloading."
        run launchctl bootout "gui/$(id -u)/$BUNDLE_ID"
    fi
    run pkill -f "$APP_NAME/Contents/MacOS/VAKT"
    sleep 1
fi

# 2. Copy.
say "Installing to $TARGET"
[ -d "$DEST" ] || run mkdir -p "$DEST"

if ! dest_is_writable "$DEST"; then
    warn "$DEST is not writable by $(whoami); the copy needs administrator rights."
    NEEDS_SUDO=yes
fi

if [ -d "$TARGET" ]; then
    priv rm -rf "$TARGET"
fi
priv ditto "$SOURCE_APP" "$TARGET"

# 3. Clear the quarantine flag. Without this macOS refuses to open the app, or
#    claims it is "damaged", because it arrived from a browser download and is
#    not notarised.
say "Clearing the download quarantine flag"
priv xattr -dr com.apple.quarantine "$TARGET"

# 4. Confirm the bundle is intact. Ad-hoc signing is expected here: this build
#    carries no Developer ID, so `spctl` will still say "rejected" and that is
#    not a failure — step 3 is what lets it open anyway.
say "Verifying the signature"
if [ "$DRY_RUN" = no ]; then
    if codesign --verify --strict "$TARGET" 2>/dev/null; then
        AUTHORITY="$(codesign -dv "$TARGET" 2>&1 | awk -F= '/^Authority/{print $2; exit}')"
        printf '    intact — signed by: %s\n' "${AUTHORITY:-ad-hoc (no Developer ID)}"
    else
        die "the copied bundle does not verify. Delete $TARGET and download the release again."
    fi
fi

# 5. Optional: survive a force-quit.
if [ "$INSTALL_AGENT" = yes ]; then
    say "Installing the LaunchAgent (starts VAKT at login, relaunches if killed)"
    SOURCE_PLIST="$SCRIPT_DIR/$AGENT_PLIST"
    [ -f "$SOURCE_PLIST" ] || die "$AGENT_PLIST is not next to this script."
    if [ "$TARGET" != "/Applications/$APP_NAME" ]; then
        warn "the LaunchAgent points at /Applications/$APP_NAME; edit ~/Library/LaunchAgents/$AGENT_PLIST if you installed elsewhere."
    fi
    run mkdir -p "$HOME/Library/LaunchAgents"
    run cp "$SOURCE_PLIST" "$HOME/Library/LaunchAgents/$AGENT_PLIST"
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
    run launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT_PLIST"
fi

# 6. Launch.
if [ "$OPEN_AFTER" = yes ]; then
    say "Opening VAKT"
    run open "$TARGET"
fi

cat <<'DONE'

Installed. VAKT is a menu-bar app: look for the eye icon, there is no Dock icon
and no main window. With no face on file it opens the enrolment window by itself.

Three things worth doing next:

  1. Require the password immediately after the screen locks, or VAKT locks and
     an intruder wakes it straight back up:

       sysadminctl -screenLock immediate -password -

  2. Grant camera access when asked. Without it VAKT cannot see anything.

  3. Turn on "Start watching as soon as VAKT launches" in Settings. Starting at
     login only launches the app — without that toggle it comes up disarmed and
     waits for you to remember.

The camera LED lights whenever VAKT samples. It is wired to the sensor in
hardware — treat the blinking LED as an honest "armed" indicator.

To remove everything later, see INSTALL.md § Uninstalling in the repository.
DONE
