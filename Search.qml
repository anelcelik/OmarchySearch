import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Search.js" as Search

// Alfred/Raycast-style launcher: one popup, fuzzy search across installed
// apps (via Omarchy's own shell.appLibrary) and files (via `fd | fzf
// --filter`, see Search.js). Structured like the built-in Emojis/Clipboard
// overlays -- same PanelWindow/BorderSurface/keyCatcher pattern -- so it
// looks and behaves consistently with the rest of the shell.
Item {
  id: root

  property string homeDir: Quickshell.env("HOME")
  property string pluginDir: root.homeDir + "/.config/omarchy/plugins/anel.search"
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var config: ({ maxResults: 10, showHiddenFiles: true, searchHome: true })
  property var fileLines: []
  property string calcResultText: ""
  property var sysInfoRows: []

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(48), Style.font.title + Style.spacing.rowPaddingX * 2)

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    root.fileLines = []
    root.calcResultText = ""
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "anel.search")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function currentAppEntries() {
    if (root.filterText.length === 0) return []
    if (!root.shell || !root.shell.appLibrary) return []
    // sortedEntries() returns wrapper rows shaped { entry, score, key, name }
    // (confirmed by reading Menu.qml's own mergeAppRows(), which does the
    // same unwrap) -- not DesktopEntry objects directly. Passing the
    // wrapper straight through left appRow()'s entry.id/entry.icon lookups
    // silently undefined, so launch() got called with an empty id and
    // no-op'd (AppLibrary.launch has an early `if (!id) return`) -- no
    // crash, no log line, just "press Enter, nothing happens".
    var wrapped = root.shell.appLibrary.sortedEntries(root.filterText)
    var out = []
    for (var i = 0; i < wrapped.length; i++) out.push(wrapped[i].entry)
    return out
  }

  function rebuildDisplay() {
    var appEntries = root.currentAppEntries()
    var rows = []
    if (root.calcResultText.length > 0 && Search.looksLikeMath(root.filterText)) {
      rows.push(Search.calcRow(root.filterText, root.calcResultText))
    }
    if (root.sysInfoRows.length > 0 && Search.parseSysInfoQuery(root.filterText)) {
      rows = rows.concat(root.sysInfoRows)
    }
    var merged = root.filterText.length === 0 ? [] : Search.mergeRows(
      appEntries, root.fileLines, root.config, root.homeDir,
      function(e) { return root.shell ? root.shell.appLibrary.entryName(e) : String(e.name || "") },
      function(e) { return root.shell ? root.shell.appLibrary.entrySubtext(e) : "" },
      function(icon) { return root.shell ? root.shell.appLibrary.iconSource(icon) : "" }
    )
    rows = rows.concat(merged)
    if (rows.length > root.config.maxResults) rows = rows.slice(0, root.config.maxResults)

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) displayModel.append(rows[i])

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    cursorActive = displayModel.count > 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    if (nextFilter.length === 0) {
      fileSearch.running = false
      root.fileLines = []
      calcProcess.running = false
      root.calcResultText = ""
      sysInfoProcess.running = false
      root.sysInfoRows = []
    } else {
      fileSearchDebounce.restart() // file results follow shortly after
      if (Search.looksLikeMath(nextFilter)) {
        // No debounce: awk is a near-instant subprocess, and a calculator
        // should feel immediate rather than laggy like the file search.
        calcOutput.text = ""
        calcProcess.command = ["bash", "-c", Search.buildCalcCommand(nextFilter)]
        calcProcess.running = true
      } else {
        calcProcess.running = false
        root.calcResultText = ""
      }
      var sysInfoQuery = Search.parseSysInfoQuery(nextFilter)
      if (sysInfoQuery) {
        // No debounce here either -- only fires on an exact keyword
        // match (not on every partial keystroke while typing toward
        // one), so it's a one-shot cost, not a per-character spam risk.
        sysInfoOutput.text = ""
        sysInfoProcess.command = ["bash", "-c", Search.buildSysInfoCommand(root.pluginDir, sysInfoQuery.keyword, sysInfoQuery.arg, Util.shellQuote)]
        sysInfoProcess.running = true
      } else {
        sysInfoProcess.running = false
        root.sysInfoRows = []
      }
    }
    root.rebuildDisplay()
  }

  function select(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "calc" || row.kind === "sysinfo") {
      root.dismiss()
      if (row.calcResult.length > 0) Util.execDetached("wl-copy " + Util.shellQuote(row.calcResult))
    } else if (row.kind === "app") {
      root.dismiss()
      if (root.shell && root.shell.appLibrary) root.shell.appLibrary.launch(row.appId, row.appName)
    } else if (row.path.length > 0) {
      root.dismiss()
      // open-file.sh handles the case plain `xdg-open` gets wrong: a
      // file whose default handler is a terminal app (e.g. nvim, the
      // default text/plain handler here) launched with no TTY just hangs
      // forever with nothing visible -- confirmed live via several stuck
      // nvim/xdg-open processes, one holding a swapfile lock on the file
      // being "opened". See that script for the terminal-vs-GUI check.
      Util.execDetached(Util.shellQuote(root.pluginDir + "/open-file.sh") + " " + Util.shellQuote(row.path))
    }
  }

  ListModel { id: displayModel }

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/search.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.config = Search.parseConfig(text())
    onFileChanged: root.config = Search.parseConfig(text())
    onLoadFailed: root.config = Search.parseConfig("{}")
  }

  // Debounced so a fast typist doesn't spawn one fd|fzf pipeline per
  // keystroke -- only after input settles for a moment.
  Timer {
    id: fileSearchDebounce
    interval: 120
    onTriggered: {
      fileSearchOutput.text = ""
      fileSearch.command = ["bash", "-c", Search.buildFileSearchCommand(root.filterText, root.config, root.homeDir, Util.shellQuote)]
      fileSearch.running = true
    }
  }

  QtObject {
    id: fileSearchOutput
    property string text: ""
  }

  Process {
    id: fileSearch
    stdout: SplitParser { onRead: function(line) { fileSearchOutput.text += line + "\n" } }
    onExited: {
      var lines = fileSearchOutput.text.split("\n").filter(function(l) { return l.length > 0 })
      root.fileLines = lines
      if (root.filterText.length > 0) root.rebuildDisplay() // merge in file results now that they've arrived
    }
  }

  QtObject {
    id: calcOutput
    property string text: ""
  }

  Process {
    id: calcProcess
    stdout: SplitParser { onRead: function(line) { calcOutput.text += line } }
    onExited: function(code) {
      // Division by zero etc. exits nonzero with no useful output --
      // just show nothing rather than a stray error row.
      root.calcResultText = code === 0 ? calcOutput.text.trim() : ""
      if (Search.looksLikeMath(root.filterText)) root.rebuildDisplay()
    }
  }

  QtObject {
    id: sysInfoOutput
    property string text: ""
  }

  Process {
    id: sysInfoProcess
    stdout: SplitParser { onRead: function(line) { sysInfoOutput.text += line + "\n" } }
    onExited: function(code) {
      if (code !== 0) {
        // Unknown keyword or sysinfo.sh's own case fell through --
        // exit(1) from that script means "not actually a sysinfo query",
        // so show nothing rather than a stray error row.
        root.sysInfoRows = []
      } else {
        var lines = sysInfoOutput.text.split("\n").filter(function(l) { return l.length > 0 })
        var rows = []
        for (var i = 0; i < lines.length; i++) {
          var row = Search.sysInfoRowFromLine(lines[i])
          if (row) rows.push(row)
        }
        root.sysInfoRows = rows
      }
      if (Search.parseSysInfoQuery(root.filterText)) root.rebuildDisplay()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "anel-search"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(80)
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || " search anything…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property int index
              required property string kind
              required property string primary
              required property string secondary
              required property string iconGlyph
              required property string iconImage

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Item {
                  width: Style.space(28)
                  height: parent.height

                  Image {
                    visible: row.iconImage.length > 0
                    anchors.centerIn: parent
                    width: Style.space(22)
                    height: Style.space(22)
                    source: row.iconImage
                    asynchronous: true
                    smooth: true
                  }

                  Text {
                    visible: row.iconImage.length === 0
                    anchors.centerIn: parent
                    text: row.iconGlyph
                    textFormat: Text.PlainText
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                  }
                }

                Column {
                  width: parent.width - Style.space(28) - parent.spacing
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    width: parent.width
                    text: row.primary
                    textFormat: Text.PlainText
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideMiddle
                  }

                  Text {
                    visible: row.secondary.length > 0
                    width: parent.width
                    text: row.secondary
                    textFormat: Text.PlainText
                    color: row.hasCursor ? root.selectedText : root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0 && root.filterText.length > 0

            Text {
              text: ""
              textFormat: Text.PlainText
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: "No matches for “" + root.filterText + "”"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
