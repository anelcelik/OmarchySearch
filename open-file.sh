#!/bin/bash
# Opens a file for the anel.search plugin.
#
# Plain `xdg-open` works fine for GUI-handled files (e.g. .odt ->
# LibreOffice). It does NOT work for files whose default handler is a
# terminal app (e.g. nvim, the default text/plain handler on this
# system): launched with no TTY, it just sits there forever with nothing
# visible. Confirmed live -- multiple stuck nvim/xdg-open processes piled
# up, one even holding a swapfile lock on the file being "opened".
#
# Tried wrapping terminal handlers in `xdg-terminal-exec` instead; that
# didn't reliably open a visible window in this environment either, for
# reasons not fully pinned down. Rather than keep chasing it, this just
# skips launching a terminal handler entirely and reveals the containing
# folder -- the file is still one click away, and nothing hangs.
set -euo pipefail
path="${1:?usage: open-file.sh <path>}"
parent="$(dirname -- "$path")"

find_desktop_file() {
  local id="$1" dir
  for dir in "$HOME/.local/share/applications" /usr/local/share/applications /usr/share/applications; do
    [ -f "$dir/$id" ] && { echo "$dir/$id"; return 0; }
  done
  return 1
}

mime=$(xdg-mime query filetype "$path" 2>/dev/null || true)
desktop_id=$(xdg-mime query default "$mime" 2>/dev/null || true)
desktop_file=""
[ -n "$desktop_id" ] && desktop_file=$(find_desktop_file "$desktop_id" || true)

if [ -n "$desktop_file" ] && grep -q "^Terminal=true" "$desktop_file"; then
  xdg-open "$parent"
else
  xdg-open "$path" || xdg-open "$parent"
fi
