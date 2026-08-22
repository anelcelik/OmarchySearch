import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Search.js" as Search

// Search v2: Alfred/Raycast-style launcher with categorized results,
// preview pane, real TextInput for editable queries, and all apps
// shown by default. Follows the PanelWindow/BorderSurface/keyCatcher
// pattern used by the built-in Clipboard and Emojis overlays.
Item {
  id: root

  property string homeDir: Quickshell.env("HOME")
  property string pluginDir: root.homeDir + "/.config/omarchy/plugins/anel.search-v2"
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var config: ({ maxResults: 50, showHiddenFiles: true, searchHome: true })
  property var fileLines: []
  property string calcResultText: ""
  property var sysInfoRows: []

  // Category tabs: "all", "apps", "files", "system"
  property string activeCategory: "all"
  readonly property var categories: ["all", "apps", "files", "system"]
  readonly property var categoryLabels: ({ all: "All", apps: "Apps", files: "Files", system: "System" })

  // Theme tokens — shared [menu] surface
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
  // Wider card to accommodate the preview pane (same as Clipboard)
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(48), Style.font.title + Style.spacing.rowPaddingX * 2)
  property int headerRowHeight: Math.max(Style.space(28), Style.font.caption + Style.space(8))
  property int tabBarHeight: Math.max(Style.space(32), Style.font.body + Style.space(12))

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    root.fileLines = []
    root.calcResultText = ""
    root.sysInfoRows = []
    root.activeCategory = "all"
    root.updateDefaultFileSearch()
    root.rebuildDisplay()
    Qt.callLater(function() { searchInput.forceActiveFocus(); searchInput.text = "" })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "anel.search-v2")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function currentAppEntries() {
    if (!root.shell || !root.shell.appLibrary) return []
    // Always get entries -- empty query returns ALL apps (sorted alphabetically
    // by the library); non-empty query returns fuzzy-matched results.
    var wrapped = root.shell.appLibrary.sortedEntries(root.filterText)
    var out = []
    for (var i = 0; i < wrapped.length; i++) out.push(wrapped[i].entry)
    return out
  }

  function rebuildDisplay() {
    var appEntries = root.currentAppEntries()
    var rows = []

    if (root.filterText.length === 0) {
      // ── Empty search: default state ──
      var appRows = Search.allAppsRows(
        appEntries,
        function(e) { return root.shell ? root.shell.appLibrary.entryName(e) : String(e.name || "") },
        function(e) { return root.shell ? root.shell.appLibrary.entrySubtext(e) : "" },
        function(icon) { return root.shell ? root.shell.appLibrary.iconSource(icon) : "" }
      )
      rows = rows.concat(appRows)

      // Add system help commands
      var sysHelp = Search.systemHelpRows()
      rows = rows.concat(sysHelp)

      // If activeCategory is files and no query, show recent file search results (home dir)
      if (root.fileLines.length > 0) {
        var fRows = []
        for (var j = 0; j < root.fileLines.length; j++) {
           var r = Search.fileRowFromLine(root.fileLines[j], root.homeDir)
           if (r) fRows.push(r)
        }
        rows = rows.concat(fRows)
      }
    } else {
      // ── Active search: merge calc + sysinfo + apps + files ──
      if (root.calcResultText.length > 0 && Search.looksLikeMath(root.filterText)) {
        rows.push(Search.calcRow(root.filterText, root.calcResultText))
      }
      if (root.sysInfoRows.length > 0 && Search.parseSysInfoQuery(root.filterText)) {
        rows = rows.concat(root.sysInfoRows)
      }
      var merged = Search.mergeRows(
        appEntries, root.fileLines, root.config, root.homeDir,
        function(e) { return root.shell ? root.shell.appLibrary.entryName(e) : String(e.name || "") },
        function(e) { return root.shell ? root.shell.appLibrary.entrySubtext(e) : "" },
        function(icon) { return root.shell ? root.shell.appLibrary.iconSource(icon) : "" }
      )
      rows = rows.concat(merged)
    }

    // Apply category filter
    rows = Search.filterByKind(rows, root.activeCategory)

    // Cap results ONLY when searching (otherwise show all apps/files)
    if (root.filterText.length > 0 && rows.length > root.config.maxResults) {
      rows = rows.slice(0, root.config.maxResults)
    }

    // Insert section headers in "all" mode when searching
    if (root.activeCategory === "all" && root.filterText.length > 0) {
      rows = Search.insertSectionHeaders(rows)
    }

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) displayModel.append(rows[i])

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    cursorActive = displayModel.count > 0

    // Skip header rows for initial selection
    if (cursorActive && displayModel.count > 0 && displayModel.get(selectedIndex).kind === "header") {
      root.skipToNextSelectable(1)
    }

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function updateDefaultFileSearch() {
    if (root.filterText.length > 0) return
    if (root.activeCategory !== "files" && root.activeCategory !== "all") return
    if (root.fileLines.length > 0) return // already loaded

    fileSearchOutput.text = ""
    fileSearch.command = ["bash", "-c", "fd --max-depth 1 --color=never --hidden --exclude .git . " + Util.shellQuote(root.homeDir) + " | sort | head -n " + root.config.maxResults]
    fileSearch.running = true
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
      root.updateDefaultFileSearch()
    } else {
      fileSearchDebounce.restart()
      if (Search.looksLikeMath(nextFilter)) {
        calcOutput.text = ""
        calcProcess.command = ["bash", "-c", Search.buildCalcCommand(nextFilter)]
        calcProcess.running = true
      } else {
        calcProcess.running = false
        root.calcResultText = ""
      }
      var sysInfoQuery = Search.parseSysInfoQuery(nextFilter)
      if (sysInfoQuery) {
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

  // Skip header rows when navigating
  function skipToNextSelectable(direction) {
    if (displayModel.count === 0) return
    var start = root.selectedIndex
    var count = displayModel.count
    for (var i = 0; i < count; i++) {
      if (displayModel.get(root.selectedIndex).kind !== "header") return
      root.selectedIndex = (root.selectedIndex + direction + count) % count
      if (root.selectedIndex === start) break // all headers somehow
    }
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    // Skip header rows
    root.skipToNextSelectable(delta < 0 ? -1 : 1)
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    root.skipToNextSelectable(1)
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function cycleCategory(delta) {
    var idx = root.categories.indexOf(root.activeCategory)
    idx = (idx + delta + root.categories.length) % root.categories.length
    root.activeCategory = root.categories[idx]
    root.selectedIndex = 0
    if (root.filterText.length === 0) root.updateDefaultFileSearch()
    root.rebuildDisplay()
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "header") return // headers aren't activatable
    if (row.kind === "sysinfo-help") {
      searchInput.text = row.primary.split(" ")[0] + " "
      searchInput.forceActiveFocus()
    } else if (row.kind === "calc" || row.kind === "sysinfo") {
      root.dismiss()
      if (row.calcResult.length > 0) Util.execDetached("wl-copy " + Util.shellQuote(row.calcResult))
    } else if (row.kind === "app") {
      root.dismiss()
      if (root.shell && root.shell.appLibrary) root.shell.appLibrary.launch(row.appId, row.appName)
    } else if (row.path.length > 0) {
      root.dismiss()
      Util.execDetached(Util.shellQuote(root.pluginDir + "/open-file.sh") + " " + Util.shellQuote(row.path))
    }
  }

  function copyIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "header") return
    root.dismiss()
    if (row.kind === "calc" || row.kind === "sysinfo") {
      if (row.calcResult.length > 0) Util.execDetached("wl-copy " + Util.shellQuote(row.calcResult))
    } else if (row.kind === "app") {
      Util.execDetached("wl-copy " + Util.shellQuote(row.appName))
    } else if (row.path.length > 0) {
      Util.execDetached(Util.shellQuote(root.pluginDir + "/open-file.sh") + " --copy-path " + Util.shellQuote(row.path))
    }
  }

  function openParentIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "header") return
    if (row.path.length > 0) {
      root.dismiss()
      Util.execDetached(Util.shellQuote(root.pluginDir + "/open-file.sh") + " --open-parent " + Util.shellQuote(row.path))
    }
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    if (displayModel.get(index).kind === "header") return
    root.cursorActive = true
    root.selectedIndex = index
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/search.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.config = Search.parseConfig(text())
    onFileChanged: root.config = Search.parseConfig(text())
    onLoadFailed: root.config = Search.parseConfig("{}")
  }

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
      if (root.filterText.length > 0) root.rebuildDisplay()
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
    WlrLayershell.namespace: "anel-search-v2"
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
      anchors.verticalCenterOffset: -Style.space(40)
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ── Search input (real TextInput for cursor movement) ──
        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          TextInput {
            id: searchInput
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            clip: true
            selectByMouse: true
            selectionColor: root.selectedBackground
            selectedTextColor: root.selectedText

            onTextChanged: {
              root.setFilter(searchInput.text)
            }

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (searchInput.text.length > 0) {
                  searchInput.text = ""
                } else {
                  root.dismiss()
                }
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.select(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.select(1)
                event.accepted = true
              } else if (event.key === Qt.Key_PageUp) {
                root.select(-6)
                event.accepted = true
              } else if (event.key === Qt.Key_PageDown) {
                root.select(6)
                event.accepted = true
              } else if (event.key === Qt.Key_Tab) {
                root.cycleCategory(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Backtab) {
                root.cycleCategory(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.cursorActive) {
                  if (event.modifiers & Qt.AltModifier) root.openParentIndex(root.selectedIndex)
                  else if (event.modifiers & Qt.ShiftModifier) root.copyIndex(root.selectedIndex)
                  else root.activateIndex(root.selectedIndex)
                }
                event.accepted = true
              }
              // Left/Right, Home/End, Ctrl+A, etc. fall through to TextInput
              // natively — this is the arrow-key cursor fix.
            }
          }

          // Placeholder text (shown when input is empty)
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: " search anything…"
            visible: searchInput.text.length === 0
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        // ── Category tabs ──
        Row {
          width: parent.width
          height: root.tabBarHeight
          spacing: Style.space(4)

          Repeater {
            model: root.categories

            Rectangle {
              required property string modelData
              width: tabLabel.implicitWidth + Style.space(20)
              height: root.tabBarHeight
              radius: root.cornerRadius
              color: root.activeCategory === modelData ? root.selectedBackground : "transparent"

              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: root.categoryLabels[modelData] || modelData
                color: root.activeCategory === modelData ? root.selectedText : root.foreground
                opacity: root.activeCategory === modelData ? 1 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: root.activeCategory === modelData
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.activeCategory = modelData
                  root.selectedIndex = 0
                  root.rebuildDisplay()
                  searchInput.forceActiveFocus()
                }
              }
            }
          }
        }

        // ── Main content: list + preview split ──
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.tabBarHeight - root.contentSpacing * 2

          Row {
            anchors.fill: parent
            spacing: 0

            // ── Left half: result list ──
            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
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
                  required property string kindLabel

                  readonly property bool isHeader: kind === "header"
                  readonly property bool hasCursor: !isHeader && root.cursorActive && index === root.selectedIndex

                  width: ListView.view.width
                  height: isHeader ? root.headerRowHeight : root.rowHeight
                  radius: isHeader ? 0 : root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  // ── Section header ──
                  Row {
                    visible: row.isHeader
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(4)
                    anchors.rightMargin: Style.space(4)
                    spacing: Style.space(8)

                    Text {
                      text: row.primary
                      color: root.foreground
                      opacity: 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.capitalization: Font.AllUppercase
                    }

                    Rectangle {
                      width: parent.width - parent.children[0].implicitWidth - parent.spacing
                      height: 1
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.foreground
                      opacity: 0.15
                    }
                  }

                  // ── Normal row ──
                  Row {
                    visible: !row.isHeader
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
                        visible: row.iconImage.length === 0 && !row.isHeader
                        anchors.centerIn: parent
                        text: row.iconGlyph
                        textFormat: Text.PlainText
                        color: row.hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                      }
                    }

                    Column {
                      width: parent.width - Style.space(28) - Style.space(50) - parent.spacing * 2
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

                    // Kind label hint (right side)
                    Text {
                      visible: !row.isHeader && row.kindLabel.length > 0
                      width: Style.space(50)
                      anchors.verticalCenter: parent.verticalCenter
                      text: row.kindLabel
                      textFormat: Text.PlainText
                      color: row.hasCursor ? root.selectedText : root.foreground
                      opacity: 0.35
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: row.isHeader ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onPositionChanged: function(mouse) {
                      if (!row.isHeader) root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: {
                      if (row.isHeader) return
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.activateIndex(row.index)
                    }
                  }
                }
              }
            }

            // ── Right half: preview pane ──
            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              property var activeRow: displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null
              property bool hasPreview: activeRow && activeRow.kind !== "header" && activeRow.preview && activeRow.preview.length > 0

              // Divider line
              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              // Preview content
              Column {
                visible: parent.hasPreview
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.topMargin: Style.space(8)
                spacing: Style.space(12)

                // Icon or glyph
                Item {
                  width: parent.width
                  height: Style.space(48)

                  Image {
                    visible: parent.parent.parent.activeRow && parent.parent.parent.activeRow.iconImage && parent.parent.parent.activeRow.iconImage.length > 0
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(40)
                    height: Style.space(40)
                    source: parent.parent.parent.activeRow ? parent.parent.parent.activeRow.iconImage : ""
                    asynchronous: true
                    smooth: true
                  }

                  Text {
                    visible: !parent.children[0].visible && parent.parent.parent.activeRow
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.parent.parent.activeRow ? parent.parent.parent.activeRow.iconGlyph : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                  }
                }

                // Title
                Text {
                  width: parent.width
                  text: parent.parent.activeRow ? parent.parent.activeRow.primary : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  wrapMode: Text.WrapAnywhere
                  elide: Text.ElideRight
                  maximumLineCount: 2
                }

                // Kind badge
                Rectangle {
                  visible: parent.parent.activeRow && parent.parent.activeRow.kindLabel && parent.parent.activeRow.kindLabel.length > 0
                  width: kindBadgeText.implicitWidth + Style.space(12)
                  height: kindBadgeText.implicitHeight + Style.space(6)
                  radius: root.cornerRadius
                  color: Util.alpha(root.selectedBackground, 0.3)

                  Text {
                    id: kindBadgeText
                    anchors.centerIn: parent
                    text: parent.parent.parent.activeRow ? parent.parent.parent.activeRow.kindLabel : ""
                    color: root.foreground
                    opacity: 0.7
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                // Preview text
                Text {
                  width: parent.width
                  text: parent.parent.activeRow ? parent.parent.activeRow.preview : ""
                  color: root.foreground
                  opacity: 0.72
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WrapAnywhere
                  elide: Text.ElideRight
                  maximumLineCount: 10
                }

                // Action hints at bottom
                Column {
                  width: parent.width
                  spacing: Style.space(2)

                  Rectangle {
                    width: parent.width
                    height: 1
                    color: root.foreground
                    opacity: 0.1
                  }

                  Text {
                    text: "↵ Open  ⇧↵ Copy  ⌥↵ Folder"
                    color: root.foreground
                    opacity: 0.35
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // Empty state for preview
              Text {
                visible: !parent.hasPreview
                anchors.centerIn: parent
                text: displayModel.count === 0 ? "" : "Select an item\nto preview"
                color: root.foreground
                opacity: 0.3
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }

          // ── Empty state ──
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
              text: "No matches for \u201c" + root.filterText + "\u201d"
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
