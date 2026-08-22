# Omarchy Search v2

A vastly improved Alfred/Raycast-style search and launcher plugin for the Omarchy shell environment, designed with a focus on speed, precision, and usability. 

*Based on the original `anel.search` plugin by **anel**.*

## Key Features & Improvements (vs v1)

- **Editable Text Cursor**: The search input is now a proper `TextInput` field, allowing you to use your left/right arrow keys to navigate and fix typos without having to delete the entire word.
- **Split-Pane Layout with Previews**: Features a modernized UI with a wider, 875x600 layout and a dynamic preview pane on the right side. It provides detailed info about the currently selected item before you open it.
- **Categorized Tabs**: Filter your search instantly by switching between dedicated categories. The UI clearly separates results with section headers when in "All" mode.
- **Smart Empty States**: 
  - Opening the search immediately shows all installed applications (just like the default Omarchy App Menu) without the 50-item limit until you start typing.
  - The **Files** tab automatically populates with the contents of your home directory (`~/`) when the search is empty.
  - The **System** tab features a helpful cheat sheet of commands (cpu, ram, temp, etc.) when the search is empty.
- **Correct Default Applications**: Opening files now relies on `gio open` to perfectly respect your system's default MIME type application associations (e.g., opening `.md` files in your preferred text editor instead of a terminal editor).

## Categories

1. **All**: Merges results across Apps, Files, Calculations, and System Commands with clear section headers.
2. **Apps**: Filters for installed system applications and scripts.
3. **Files**: Performs rapid file system searches (powered by `fd`). 
4. **System**: Access to quick system information metrics and utilities (e.g., `cpu`, `ram`, `gpu`, `temp`, `battery`, `disk`, `ip`, `usb`, `pkg`, `sha256`).

## Keybinds & Navigation

| Keybind | Action |
| :--- | :--- |
| **`Alt + Space`** | Toggle the Search v2 overlay |
| **`Tab`** | Cycle to the next category tab |
| **`Shift + Tab`** | Cycle to the previous category tab |
| **`↑ / ↓`** | Navigate up or down the search results list |
| **`← / →`** | Move the text cursor to edit your search query |
| **`Enter`** | Launch the selected app, open file, or execute system command |
| **`Esc`** | Dismiss the search overlay |

## Prerequisites

- **Omarchy Shell**
- **`fd`**: Required for lightning-fast file searching.
- **`wl-copy`**: Required to copy calculation results to clipboard.
- **`gio`**: Required for respecting default desktop application associations.

## Author & Credits

- Original Creator: **anel**
- Improvements: **Antigravity IDE**

## License
MIT
