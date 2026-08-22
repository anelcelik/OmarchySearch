#!/bin/bash
# Opens a file for the anel.search-v2 plugin.
#
# Uses `gio open` (same mechanism as file managers like Nautilus/Thunar)
# to match the user's actual default application preferences. Falls back
# to `xdg-open` if gio is unavailable.
#
# v2 flags:
#   --copy-path   Copy the file's absolute path to the clipboard (wl-copy)
#   --open-parent Open the containing directory instead of the file
set -euo pipefail

action="open"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --copy-path)   action="copy-path"; shift ;;
    --open-parent) action="open-parent"; shift ;;
    *) shift ;;
  esac
done

path="${1:?usage: open-file.sh [--copy-path|--open-parent] <path>}"
parent="$(dirname -- "$path")"

if [ "$action" = "copy-path" ]; then
  abs="$(realpath -- "$path" 2>/dev/null || echo "$path")"
  printf '%s' "$abs" | wl-copy
  exit 0
fi

if [ "$action" = "open-parent" ]; then
  gio open "$parent" 2>/dev/null || xdg-open "$parent"
  exit 0
fi

# Default action: open the file using gio (same as file managers).
# gio open handles MIME type detection more accurately than xdg-open
# and respects the same default-app preferences as the file manager.
if command -v gio &>/dev/null; then
  gio open "$path" || gio open "$parent"
else
  xdg-open "$path" || xdg-open "$parent"
fi
