// Backend logic for the search overlay v2: config parsing, the fd/fzf file
// search command, the calculator, category filtering, section headers,
// preview data, and merging everything into one ranked list.
//
// v2 changes from v1:
//   - maxResults default 10 → 50
//   - allAppsRows() for showing all apps when search is empty
//   - filterByKind() for category tabs
//   - sectionHeaderRow() for visual separators in "All" mode
//   - Richer file rows with extension descriptions
//   - preview field on all row types
//   - File type icon glyphs

function parseConfig(raw) {
  var defaults = { maxResults: 50, showHiddenFiles: true, searchHome: true }
  try {
    var parsed = JSON.parse(String(raw || "{}"))
    return {
      maxResults: typeof parsed.maxResults === "number" && parsed.maxResults > 0 ? parsed.maxResults : defaults.maxResults,
      showHiddenFiles: typeof parsed.showHiddenFiles === "boolean" ? parsed.showHiddenFiles : defaults.showHiddenFiles,
      searchHome: typeof parsed.searchHome === "boolean" ? parsed.searchHome : defaults.searchHome
    }
  } catch (e) {
    return defaults
  }
}

function collapseHome(path, home) {
  var p = String(path || "")
  var h = String(home || "")
  if (h.length > 0 && p.indexOf(h) === 0) return "~" + p.slice(h.length)
  return p
}

// ── File type descriptions & icons ──────────────────────────────────────
// Maps lowercase extensions to [description, nerdFontGlyph].
var FILE_TYPES = {
  // Documents
  "pdf": ["PDF document", ""],
  "doc": ["Word document", ""],
  "docx": ["Word document", ""],
  "odt": ["OpenDocument text", ""],
  "rtf": ["Rich text", ""],
  "txt": ["Plain text", ""],
  "md": ["Markdown", ""],
  "tex": ["LaTeX document", ""],
  // Spreadsheets
  "xls": ["Excel spreadsheet", ""],
  "xlsx": ["Excel spreadsheet", ""],
  "ods": ["OpenDocument spreadsheet", ""],
  "csv": ["CSV data", ""],
  // Presentations
  "ppt": ["PowerPoint", ""],
  "pptx": ["PowerPoint", ""],
  "odp": ["OpenDocument presentation", ""],
  // Images
  "png": ["PNG image", ""],
  "jpg": ["JPEG image", ""],
  "jpeg": ["JPEG image", ""],
  "gif": ["GIF image", ""],
  "svg": ["SVG image", ""],
  "webp": ["WebP image", ""],
  "bmp": ["Bitmap image", ""],
  "ico": ["Icon file", ""],
  // Video
  "mp4": ["MP4 video", ""],
  "mkv": ["MKV video", ""],
  "avi": ["AVI video", ""],
  "mov": ["QuickTime video", ""],
  "webm": ["WebM video", ""],
  // Audio
  "mp3": ["MP3 audio", ""],
  "flac": ["FLAC audio", ""],
  "ogg": ["Ogg audio", ""],
  "wav": ["WAV audio", ""],
  "m4a": ["AAC audio", ""],
  // Archives
  "zip": ["ZIP archive", ""],
  "tar": ["Tar archive", ""],
  "gz": ["Gzip archive", ""],
  "xz": ["XZ archive", ""],
  "bz2": ["Bzip2 archive", ""],
  "7z": ["7-Zip archive", ""],
  "rar": ["RAR archive", ""],
  // Code
  "js": ["JavaScript", ""],
  "ts": ["TypeScript", ""],
  "py": ["Python", ""],
  "rs": ["Rust", ""],
  "go": ["Go", ""],
  "c": ["C source", ""],
  "cpp": ["C++ source", ""],
  "h": ["C header", ""],
  "java": ["Java", ""],
  "rb": ["Ruby", ""],
  "sh": ["Shell script", ""],
  "bash": ["Bash script", ""],
  "zsh": ["Zsh script", ""],
  "lua": ["Lua", ""],
  "html": ["HTML", ""],
  "css": ["CSS", ""],
  "json": ["JSON", ""],
  "xml": ["XML", ""],
  "yaml": ["YAML", ""],
  "yml": ["YAML", ""],
  "toml": ["TOML", ""],
  "ini": ["Config file", ""],
  "conf": ["Config file", ""],
  "qml": ["QML", ""],
  // System
  "so": ["Shared library", ""],
  "deb": ["Debian package", ""],
  "rpm": ["RPM package", ""],
  "AppImage": ["AppImage", ""],
  "desktop": ["Desktop entry", ""],
  "service": ["Systemd service", ""]
}

function fileExtension(path) {
  var dot = String(path || "").lastIndexOf(".")
  if (dot < 0 || dot === path.length - 1) return ""
  return path.slice(dot + 1).toLowerCase()
}

function fileTypeInfo(path) {
  var ext = fileExtension(path)
  if (ext && FILE_TYPES[ext]) return FILE_TYPES[ext]
  return null
}

function parentDir(path, home) {
  var p = String(path || "")
  var slash = p.lastIndexOf("/")
  if (slash <= 0) return "/"
  return collapseHome(p.slice(0, slash), home)
}

function basename(path) {
  var p = String(path || "")
  var slash = p.lastIndexOf("/")
  return slash >= 0 ? p.slice(slash + 1) : p
}

// ── Command builders ────────────────────────────────────────────────────

function buildFileSearchCommand(query, cfg, home, shellQuote) {
  var root = cfg.searchHome ? home : "/"
  var fdArgs = ["fd", "--color=never"]
  if (cfg.showHiddenFiles) fdArgs.push("--hidden", "--exclude", ".git")
  fdArgs.push(".", shellQuote(root))
  var fdCmd = fdArgs.join(" ")
  var fzfCmd = "fzf --filter " + shellQuote(query)
  var headCmd = "head -n " + String(Math.max(1, cfg.maxResults))
  return fdCmd + " | " + fzfCmd + " | " + headCmd
}

var MATH_CHARS = /^[\d\s+\-*/^%().]+$/
var MATH_HAS_OPERATOR = /[+\-*/^%]/
function normalizeMathQuery(query) {
  return String(query || "").trim().replace(/^=+\s*/, "").replace(/\s*=+$/, "").trim()
}
function looksLikeMath(query) {
  var q = normalizeMathQuery(query)
  if (q.length === 0) return false
  if (!MATH_CHARS.test(q)) return false
  if (!MATH_HAS_OPERATOR.test(q)) return false
  return true
}

function buildCalcCommand(query) {
  return "awk 'BEGIN{print (" + normalizeMathQuery(query) + ")}'"
}

// ── System info ─────────────────────────────────────────────────────────

var SYSINFO_KEYWORDS = ["cpu", "ram", "memory", "gpu", "temp", "temperature", "battery", "bat", "disk", "ip", "usb", "pkg", "sha256", "md5", "hash"]

function parseSysInfoQuery(query) {
  var q = String(query || "").trim()
  if (q.length === 0) return null
  var parts = q.split(/\s+/)
  var keyword = parts[0].toLowerCase()
  if (SYSINFO_KEYWORDS.indexOf(keyword) === -1) return null
  return { keyword: keyword, arg: parts.slice(1).join(" ") }
}

function buildSysInfoCommand(pluginDir, keyword, arg, shellQuote) {
  var cmd = shellQuote(pluginDir + "/sysinfo.sh") + " " + shellQuote(keyword)
  if (arg.length > 0) cmd += " " + shellQuote(arg)
  return cmd
}

// sysinfo.sh emits glyph<TAB>primary<TAB>secondary<TAB>copyValue per row
function sysInfoRowFromLine(line) {
  var parts = String(line || "").split("\t")
  if (parts.length < 3) return null
  var copyVal = parts[3] || ""
  return {
    kind: "sysinfo",
    primary: parts[1] || "",
    secondary: parts[2] || "",
    iconGlyph: parts[0] || "",
    iconImage: "",
    path: "",
    appId: "",
    appName: "",
    calcResult: copyVal,
    preview: (parts[1] || "") + (parts[2] ? "\n" + parts[2] : "") + (copyVal ? "\n\nCopy: " + copyVal : ""),
    kindLabel: "System"
  }
}

// ── Row builders ────────────────────────────────────────────────────────

function fileRowFromLine(line, home) {
  var raw = String(line || "")
  if (raw.length === 0) return null
  var isDir = raw.charAt(raw.length - 1) === "/"
  var path = isDir ? raw.slice(0, -1) : raw
  var typeInfo = isDir ? null : fileTypeInfo(path)
  var desc = typeInfo ? typeInfo[0] : ""
  var icon = isDir ? "" : (typeInfo ? typeInfo[1] : "") // nf-fa-folder / typed or generic file
  var dir = parentDir(path, home)
  var secondary = desc ? desc + " · " + dir : dir
  return {
    kind: isDir ? "dir" : "file",
    primary: basename(path),
    secondary: secondary,
    iconGlyph: icon,
    iconImage: "",
    path: path,
    appId: "",
    appName: "",
    calcResult: "",
    preview: collapseHome(path, home) + (desc ? "\n" + desc : "") + "\nIn: " + dir,
    kindLabel: isDir ? "Folder" : "File"
  }
}

function appRow(entry, entryName, entrySubtext, iconSource) {
  var name = entryName(entry)
  var sub = entrySubtext(entry)
  return {
    kind: "app",
    primary: name,
    secondary: sub,
    iconGlyph: "",
    iconImage: iconSource(entry.icon),
    path: "",
    appId: String(entry.id || ""),
    appName: name,
    calcResult: "",
    preview: name + (sub ? "\n" + sub : "") + "\nID: " + String(entry.id || ""),
    kindLabel: "App"
  }
}

function calcRow(query, resultText) {
  var expr = normalizeMathQuery(query)
  return {
    kind: "calc",
    primary: expr + " = " + resultText,
    secondary: "Press Enter to copy",
    iconGlyph: "", // nf-fa-calculator
    iconImage: "",
    path: "",
    appId: "",
    appName: "",
    calcResult: resultText,
    preview: expr + "\n= " + resultText,
    kindLabel: "Calc"
  }
}

// ── Section headers ─────────────────────────────────────────────────────

function sectionHeaderRow(title) {
  return {
    kind: "header",
    primary: title,
    secondary: "",
    iconGlyph: "",
    iconImage: "",
    path: "",
    appId: "",
    appName: "",
    calcResult: "",
    preview: "",
    kindLabel: ""
  }
}

// ── Category filtering ──────────────────────────────────────────────────

// activeCategory: "all", "apps", "files", "system"
function filterByKind(rows, activeCategory) {
  if (activeCategory === "all") return rows
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var kind = rows[i].kind
    if (activeCategory === "apps" && kind === "app") out.push(rows[i])
    else if (activeCategory === "files" && (kind === "file" || kind === "dir")) out.push(rows[i])
    else if (activeCategory === "system" && (kind === "sysinfo" || kind === "calc" || kind === "sysinfo-help")) out.push(rows[i])
  }
  return out
}

// ── System Help (empty search) ──────────────────────────────────────────

function systemHelpRows() {
  var rows = []
  var helps = [
    { k: "cpu", d: "Show CPU information", i: "" },
    { k: "ram", d: "Show Memory usage", i: "" },
    { k: "gpu", d: "Show GPU information", i: "󰢮" },
    { k: "temp", d: "Show Temperature sensors", i: "" },
    { k: "battery", d: "Show Battery status", i: "" },
    { k: "disk", d: "Show Disk usage", i: "󰋊" },
    { k: "ip", d: "Show Network IP addresses", i: "󰩟" },
    { k: "usb", d: "Show USB devices", i: "" },
    { k: "pkg <name>", d: "Search pacman packages", i: "󰏔" },
    { k: "sha256 <file>", d: "Compute file SHA256 hash", i: "󰕥" }
  ]
  for (var i = 0; i < helps.length; i++) {
    rows.push({
      kind: "sysinfo-help",
      primary: helps[i].k,
      secondary: helps[i].d,
      iconGlyph: helps[i].i,
      iconImage: "",
      path: "",
      appId: "",
      appName: "",
      calcResult: "",
      preview: helps[i].k + "\n" + helps[i].d + "\n\nPress Enter to use this command.",
      kindLabel: "System Cmd"
    })
  }
  return rows
}

// ── All-apps listing (empty search) ─────────────────────────────────────

function allAppsRows(appEntries, entryName, entrySubtext, iconSource) {
  var rows = []
  for (var i = 0; i < appEntries.length; i++) {
    rows.push(appRow(appEntries[i], entryName, entrySubtext, iconSource))
  }
  // Sort alphabetically by primary name
  rows.sort(function(a, b) {
    var al = a.primary.toLowerCase()
    var bl = b.primary.toLowerCase()
    if (al < bl) return -1
    if (al > bl) return 1
    return 0
  })
  return rows
}

// ── Merge results (search active) ───────────────────────────────────────

// Apps first (already relevance-sorted by AppSearch), then files fill the
// remaining slots up to maxResults. The calculator row (if any) is
// prepended by the caller, not here.
function mergeRows(appEntries, fileLines, cfg, home, entryName, entrySubtext, iconSource) {
  var rows = []
  var appBudget = Math.min(appEntries.length, Math.max(1, Math.floor(cfg.maxResults / 2)))
  for (var i = 0; i < appBudget && rows.length < cfg.maxResults; i++) {
    rows.push(appRow(appEntries[i], entryName, entrySubtext, iconSource))
  }
  for (var j = 0; j < fileLines.length && rows.length < cfg.maxResults; j++) {
    var row = fileRowFromLine(fileLines[j], home)
    if (row) rows.push(row)
  }
  return rows
}

// Insert section headers between groups of different kinds in "All" mode.
function insertSectionHeaders(rows) {
  if (rows.length === 0) return rows
  var out = []
  var lastKindGroup = ""
  for (var i = 0; i < rows.length; i++) {
    var kind = rows[i].kind
    if (kind === "header") continue // shouldn't happen, but be safe
    var group = kind === "app" ? "apps" : (kind === "file" || kind === "dir") ? "files" : (kind === "sysinfo") ? "system" : (kind === "calc") ? "calculator" : "other"
    if (group !== lastKindGroup) {
      var titles = { apps: "Apps", files: "Files & Folders", system: "System Info", calculator: "Calculator", other: "Other" }
      out.push(sectionHeaderRow(titles[group] || group))
      lastKindGroup = group
    }
    out.push(rows[i])
  }
  return out
}
