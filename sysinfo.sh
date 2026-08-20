#!/bin/bash
# System-info provider for anel.search. One keyword in, one or more
# result rows out, tab-separated: glyph<TAB>primary<TAB>secondary<TAB>copyValue
# (copyValue is what Enter copies to the clipboard; empty if nothing
# sensible to copy). Read-only everywhere -- nothing here changes system
# state, so there's no confirmation step to design for this batch.
set -uo pipefail
keyword="${1:-}"
arg="${2:-}"

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

case "$keyword" in
  cpu)
    model=$(lscpu | awk -F': +' '/^Model name/{print $2}')
    cores=$(nproc)
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    row "" "$model" "$cores cores -- load avg $load" ""
    ;;

  ram|memory)
    read -r _ total used free _ _ avail < <(free -h | awk '/^Mem:/{print}')
    row "" "$used used / $total total" "$avail available" ""
    ;;

  gpu)
    model=$(lspci | grep -iE "vga|3d|display" | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //')
    card=$(find /sys/class/drm -maxdepth 1 -iname "card[0-9]" | sort | head -1)
    busy=""
    [ -n "$card" ] && [ -f "$card/device/gpu_busy_percent" ] && busy=$(cat "$card/device/gpu_busy_percent" 2>/dev/null)
    if [ -n "$busy" ]; then
      row "" "$model" "$busy% busy" ""
    else
      row "" "$model" "" ""
    fi
    ;;

  temp|temperature)
    # Highest single reading across all sensors -- simplest "is anything
    # running hot" signal without picking one chip's naming scheme. The
    # sed strips parenthetical content first: `sensors` prints low/high
    # /crit *threshold* values inline in parens (e.g. "high = +65261.8°C",
    # an uncalibrated placeholder on this board) -- without stripping
    # those, the naive grep+sort picked up a threshold instead of an
    # actual reading, showing a nonsense 65261.8°C "temperature".
    reading=$(sensors 2>/dev/null | sed -E 's/\([^)]*\)//g' | grep -oE '[+-][0-9]+\.[0-9]+°C' | sed -E 's/[+°C]//g' | sort -rn | head -1)
    if [ -n "$reading" ]; then
      row "" "${reading}°C" "highest sensor reading" "${reading}°C"
    else
      row "" "No temperature sensors found" "" ""
    fi
    ;;

  battery|bat)
    dev=$(upower -e 2>/dev/null | grep -i battery | head -1)
    if [ -z "$dev" ]; then
      row "" "No battery detected" "" ""
    else
      pct=$(upower -i "$dev" | awk -F': +' '/percentage/{print $2}')
      state=$(upower -i "$dev" | awk -F': +' '/state/{print $2}')
      row "" "$pct" "$state" "$pct"
    fi
    ;;

  disk)
    if [ -n "$arg" ]; then
      expanded="${arg/#\~/$HOME}"
      if [ -e "$expanded" ]; then
        size=$(du -sh -- "$expanded" 2>/dev/null | cut -f1)
        row "" "$arg" "$size" "$size"
      else
        row "" "No such path: $arg" "" ""
      fi
    else
      df -h --output=source,target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null \
        | awk '!seen[$1]++' | tail -n +2 | while read -r src target size used avail pcent; do
          row "" "$target" "$used / $size used ($pcent)" ""
        done
    fi
    ;;

  ip)
    local_ips=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | tr '\n' ' ')
    row "" "${local_ips:-none found}" "local" "${local_ips% }"
    public_ip=$(timeout 3 curl -4 -s ifconfig.me 2>/dev/null)
    if [ -n "$public_ip" ]; then
      row "" "$public_ip" "public" "$public_ip"
    fi
    ;;

  usb)
    found=0
    for d in /sys/bus/usb/devices/*/; do
      [ -f "${d}product" ] || continue
      product=$(cat "${d}product" 2>/dev/null)
      vendor=$(cat "${d}idVendor" 2>/dev/null)
      pid=$(cat "${d}idProduct" 2>/dev/null)
      row "" "$product" "$vendor:$pid" ""
      found=1
    done
    [ "$found" = 0 ] && row "" "No USB devices found" "" ""
    ;;

  pkg)
    if [ -z "$arg" ]; then
      row "" "pkg <name> -- type a package name" "" ""
    elif pacman -Qi -- "$arg" >/dev/null 2>&1; then
      ver=$(pacman -Qi -- "$arg" | awk -F': +' '/^Version/{print $2}')
      size=$(pacman -Qi -- "$arg" | awk -F': +' '/^Installed Size/{print $2}')
      row "" "$arg (installed)" "$ver -- $size" ""
    elif pacman -Si -- "$arg" >/dev/null 2>&1; then
      ver=$(pacman -Si -- "$arg" | awk -F': +' '/^Version/{print $2}')
      row "" "$arg (not installed)" "available: $ver" ""
    else
      row "" "$arg: not found in repos" "" ""
    fi
    ;;

  sha256|md5|hash)
    algo="sha256sum"
    [ "$keyword" = "md5" ] && algo="md5sum"
    if [ -z "$arg" ]; then
      row "" "$keyword <path> -- type a file path" "" ""
    elif [ -f "$arg" ]; then
      sum=$("$algo" -- "$arg" | cut -d' ' -f1)
      row "" "$sum" "$(basename -- "$arg")" "$sum"
    else
      row "" "No such file: $arg" "" ""
    fi
    ;;

  *)
    exit 1
    ;;
esac
