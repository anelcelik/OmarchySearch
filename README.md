# Search

Alfred/Raycast-style launcher for Omarchy: one popup, fuzzy search across
installed apps, files/directories, and a live arithmetic calculator.

## Features

- **Hotkey**: `SUPER + ;` opens/closes the popup.
- **Apps**: ranked by Omarchy's own app search (`shell.appLibrary`), same
  engine the Omarchy menu's Apps submenu uses. Enter launches.
- **Files & directories**: fuzzy-ranked via `fd | fzf --filter` under
  your home directory (or `/` if `searchHome: false`). No custom fuzzy
  matcher written for this -- `fzf` does the ranking. Enter opens the
  file; if its default handler is a terminal app (e.g. `nvim`), the
  containing folder opens instead of launching a hung, invisible
  terminal session (see `open-file.sh` for why).
- **Calculator**: type an arithmetic expression (digits, `+ - * / % ^ ()`
  only, an optional leading/trailing `=` is fine too) and the result
  appears as the top row instantly, no debounce. Enter copies the result
  to the clipboard. Evaluated by `awk` (`bc` isn't installed on this
  system; `awk`'s `BEGIN{print (...)}` handles the same operators fine)
  -- the query is whitelist-checked against a digits/operators-only regex
  before it ever reaches a shell command, so nothing else can end up in
  that `awk` invocation.
- **System info**: type one of the keywords below (some take an
  argument) for an instant, read-only result. Enter copies the value
  where there's an obvious one to copy (IP, hash, temperature, battery
  %). All logic lives in `sysinfo.sh`, one command per keyword --
  `free`/`lscpu`/`sensors`/`upower`/`df`/`ip`/`pacman`/`sha256sum` under
  the hood, nothing that changes system state.

  | Keyword | Example | Shows |
  |---|---|---|
  | `cpu` | `cpu` | Model, core count, load average |
  | `ram` / `memory` | `ram` | Used / total / available |
  | `gpu` | `gpu` | Model, current busy % |
  | `temp` / `temperature` | `temp` | Highest current sensor reading |
  | `battery` / `bat` | `battery` | Charge %, charging/discharging |
  | `disk` | `disk` or `disk ~/Downloads` | Mounted disks, or one dir's size |
  | `ip` | `ip` | Local + public IP |
  | `usb` | `usb` | Connected USB devices |
  | `pkg` | `pkg firefox` | Installed/available version via pacman |
  | `sha256` / `md5` | `sha256 ~/file` | Checksum of a file |

## Installation

1. Clone this repo into Omarchy's user plugin directory:

   ```bash
   git clone <this-repo-url> ~/.config/omarchy/plugins/anel.search
   ```

2. Enable the plugin:

   ```bash
   omarchy plugin enable anel.search
   ```

3. Load the keybind. This plugin does **not** touch your Hyprland config
   automatically -- add this line yourself to `~/.config/hypr/bindings.lua`:

   ```lua
   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/anel.search/hypr-bindings.lua")
   ```

4. Reload Hyprland (`hyprctl reload`, then check `hyprctl configerrors`
   comes back empty) and restart the shell so the overlay actually picks
   up the plugin (`omarchy restart shell` -- see "Developing this
   plugin" below for why a plain hot-reload isn't reliable here).

5. (Optional) copy the example config to customize result count/search
   scope -- see Configuration below.

## Removal

1. Remove the `dofile(...)` line you added to
   `~/.config/hypr/bindings.lua`, then `hyprctl reload`.
2. Disable and remove the plugin:

   ```bash
   omarchy plugin disable anel.search
   omarchy plugin remove anel.search
   ```
3. Optionally delete `~/.config/omarchy/search.json` if you created one.

## Configuration

`~/.config/omarchy/search.json`:

```json
{
  "maxResults": 10,
  "showHiddenFiles": true,
  "searchHome": true
}
```

Hot-reloads on save. `searchHome: false` searches from `/` instead of
your home directory.

## Requirements

`fd`, `fzf`, `awk`, `xdg-open`, `wl-copy`, `free`, `lscpu`, `sensors`
(lm_sensors), `upower`, `df`, `du`, `ip`, `curl`, `pacman`, `sha256sum`,
`md5sum` -- all standard on Omarchy/Arch. `sensors`/`upower` need actual
hardware sensors/a battery to return anything meaningful; harmless if
absent (`temp`/`battery` just report nothing found).

## Structure

- `manifest.json` / `Search.qml` -- the Omarchy shell overlay plugin.
- `Search.js` -- pure backend logic (config parsing, command building,
  row merging) kept separate from the UI so it's testable/readable on
  its own.
- `open-file.sh` -- the terminal-vs-GUI handler check for opening files.
- `sysinfo.sh` -- one case per system-info keyword.
- `hypr-bindings.lua` -- the `SUPER + ;` keybind. Hyprland owns
  keybindings, not the shell, so this is sourced via `dofile(...)` from
  `~/.config/hypr/bindings.lua` rather than living in the QML.

## Developing this plugin

`keepLoaded: true` overlays don't reliably pick up file-watcher
hot-reloads once already loaded -- editing the QML/JS files logs "Local
plugin changed, reloading" but the *already-running* instance can keep
executing stale code for many edits afterward (confirmed live: removed
`console.warn` debug lines kept firing minutes and several edits later).
Run `omarchy restart shell` after edits before trusting a test -- it's
cheap and doesn't touch open apps/windows, just the bar/overlay process.

## Roadmap

Not built yet: Ctrl+Enter/Alt+Enter actions, Tab to switch search modes,
windows provider, per-result action menus, and a deliberately-deferred
batch of destructive power actions (raw shell exec, process kill,
systemd start/stop/restart) that needs a confirmation-dialog UI built
first, plus a "cheat" natural-language-to-command lookup that needs
feasibility research. v1 scope was apps + files + Enter-to-open/launch;
the calculator and system-info providers were added afterward.

## License

[MIT](LICENSE)
