#!/bin/sh
# Build and install a signed binary; never start a service or load the Dock addition.
set -eu

: "${YABAI_SIGNING_IDENTITY:?Set YABAI_SIGNING_IDENTITY to a persistent codesigning identity}"
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${YABAI_INSTALL_DIR:-"$HOME/.local/bin"}
state=${YABAI_BUILD_STATE:-"$HOME/.local/state/yabai-source"}
if pgrep -x yabai >/dev/null; then
    echo 'Stop yabai before replacing its binary.' >&2
    exit 1
fi

cd "$repo"
make install
codesign --force --sign "$YABAI_SIGNING_IDENTITY" bin/yabai
codesign --verify --strict bin/yabai
mkdir -p "$destination" "$state"
if [ -e "$destination/yabai" ]; then
    backup=$(mktemp -d "$state/previous.XXXXXX")
    cp -p "$destination/yabai" "$backup/yabai"
    echo "Previous binary: $backup/yabai"
fi
temporary=$(mktemp "$destination/.yabai.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
install -m 755 bin/yabai "$temporary"
codesign --verify --strict "$temporary"
mv -f "$temporary" "$destination/yabai"
{
    date -u '+built_at=%Y-%m-%dT%H:%M:%SZ'
    printf 'source_commit=%s\n' "$(git rev-parse HEAD)"
    printf 'source_dirty=%s\n' "$(git status --porcelain | wc -l | tr -d ' ')"
    "$destination/yabai" --version
    shasum -a 256 "$destination/yabai"
} > "$state/installed.txt"
cat "$state/installed.txt"
echo 'Installed only. Accessibility permission and an exclusive manager session are required before starting.'
