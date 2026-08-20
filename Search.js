// Backend logic for the search overlay: config parsing, the fd/fzf file
// search command, the calculator, and merging everything into one ranked
// list. Deliberately no home-grown fuzzy matcher or expression parser
// here -- apps are ranked by Omarchy's own AppLibrary/AppSearch
// (shell.appLibrary.sortedEntries), files are ranked by piping fd's
// listing through `fzf --filter`, and arithmetic is evaluated by `awk`
// (bc/qalc aren't installed on this system; awk is, and its BEGIN{print
// (...)} form handles + - * / % ^ and parens fine).

function parseConfig(raw) {
  var defaults = { maxResults: 10, showHiddenFiles: true, searchHome: true }
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

// Builds the `fd ... | fzf --filter ... | head -n N` shell command. Every
// dynamic piece (query, search root) goes through shellQuote so odd
// characters in a query can't break out of the command string.
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

// Whitelist-only check: digits, whitespace, and arithmetic operators, at
// least one of which must actually be an operator. Rejects anything with
// a letter or other character, so a query is never handed to awk unless
// it's already provably just numbers/operators -- no separate shell
// -escaping needed for the expression itself before it reaches awk's
// BEGIN block.
//
// A leading or trailing "=" is stripped first -- typing "300*3=" or
// "=300*3" (real-calculator/spreadsheet habits) is common, but "=" isn't
// a valid awk expression character, so without this a query like that
// would silently fail MATH_CHARS and fall through to a plain (empty)
// text search with no visible explanation why.
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

// fd marks directories with a trailing "/" in its output -- that's the
// only signal needed to tell files and directories apart without a
// separate stat() per row. Every row (calc/app/file/dir) carries the
// same set of keys so ListModel.append() sees a consistent role set
// regardless of which kind of row comes first.
function fileRowFromLine(line, home) {
  var raw = String(line || "")
  if (raw.length === 0) return null
  var isDir = raw.charAt(raw.length - 1) === "/"
  var path = isDir ? raw.slice(0, -1) : raw
  return {
    kind: isDir ? "dir" : "file",
    primary: collapseHome(path, home),
    secondary: "",
    iconGlyph: isDir ? "" : "", // nf-fa-folder / nf-fa-file
    iconImage: "",
    path: path,
    appId: "",
    appName: "",
    calcResult: ""
  }
}

function appRow(entry, entryName, entrySubtext, iconSource) {
  return {
    kind: "app",
    primary: entryName(entry),
    secondary: entrySubtext(entry),
    iconGlyph: "",
    iconImage: iconSource(entry.icon),
    path: "",
    appId: String(entry.id || ""),
    appName: entryName(entry),
    calcResult: ""
  }
}

function calcRow(query, resultText) {
  return {
    kind: "calc",
    primary: normalizeMathQuery(query) + " = " + resultText,
    secondary: "Press Enter to copy",
    iconGlyph: "", // nf-fa-calculator
    iconImage: "",
    path: "",
    appId: "",
    appName: "",
    calcResult: resultText
  }
}

// System-info provider: an exact keyword (optionally followed by an
// argument, e.g. "disk ~/Downloads" or "pkg firefox") dispatches to
// sysinfo.sh, which does the actual work (free/lscpu/sensors/upower/df/
// ip/pacman/sha256sum -- all read-only, nothing here changes system
// state). Kept as a single external script rather than inline commands
// here so each metric's shell logic can be tested/fixed on its own (see
// that script's history: the temp reading was initially broken by
// picking up a sensor's uncalibrated threshold value instead of an
// actual reading).
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
// (one command can produce several rows, e.g. "disk" listing multiple
// mounts, or "ip" listing local + public).
function sysInfoRowFromLine(line) {
  var parts = String(line || "").split("\t")
  if (parts.length < 3) return null
  return {
    kind: "sysinfo",
    primary: parts[1] || "",
    secondary: parts[2] || "",
    iconGlyph: parts[0] || "",
    iconImage: "",
    path: "",
    appId: "",
    appName: "",
    calcResult: parts[3] || ""
  }
}

// Apps first (already relevance-sorted by AppSearch), then files fill the
// remaining slots up to maxResults. The calculator row (if any) is
// prepended by the caller, not here -- it isn't ranked against apps/files,
// it's just always first when present.
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
