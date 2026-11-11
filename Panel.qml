import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Configurable, read-only Git branch monitoring. The helper performs one live
// remote query per repository and never fetches or changes a repository.
Panel {
  id: root
  moduleName: "smartalb.branch-watch"
  ipcTarget: "smartalb.branch-watch"
  manageIpc: true

  readonly property string pluginVersion: "0.1.0"
  readonly property string scriptDir: decodeURIComponent(Qt.resolvedUrl("bin").toString().replace("file://", ""))
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/branch-watch.json"
  readonly property string fontFam: bar ? bar.fontFamily : Style.font.family
  readonly property color fg: root.barForeground
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  property var config: defaultConfig()
  property var rows: []
  property string lastCheck: ""
  property string probeError: ""
  property bool receivedResult: false
  property int rowsRevision: 0

  onRowsRevisionChanged: Qt.callLater(function() { content.forceLayout() })

  function defaultConfig() {
    return { schemaVersion: 1, intervalMinutes: 10, notifications: true, repositories: [] }
  }

  function normalizeConfig(value) {
    var source = value && typeof value === "object" ? value : ({})
    var interval = Math.floor(Number(source.intervalMinutes))
    if (!isFinite(interval) || interval < 1) interval = 10
    interval = Math.min(interval, 1440)
    var repositories = []
    var input = Array.isArray(source.repositories) ? source.repositories : []
    for (var i = 0; i < input.length && repositories.length < 24; i++) {
      var raw = input[i]
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue
      var rawBranches = Array.isArray(raw.branches) ? raw.branches : []
      var branches = []
      var seen = ({})
      for (var b = 0; b < rawBranches.length && branches.length < 16; b++) {
        var candidate = rawBranches[b]
        if (typeof candidate === "string") candidate = { name: candidate }
        if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) continue
        var branchName = String(candidate.name || "").slice(0, 256)
        if (!branchName || seen[branchName]) continue
        seen[branchName] = true
        branches.push({
          name: branchName,
          label: String(candidate.label || branchName.slice(0, 1).toUpperCase()).slice(0, 12)
        })
      }
      repositories.push({
        id: String(raw.id || "repo-" + i).slice(0, 128),
        name: String(raw.name || "Repository " + (i + 1)).slice(0, 128),
        label: String(raw.label || raw.name || "GIT").slice(0, 12),
        path: String(raw.path || "").slice(0, 4096),
        remote: String(raw.remote || "origin").slice(0, 512),
        notifications: raw.notifications !== false,
        branches: branches
      })
    }
    return {
      schemaVersion: 1,
      intervalMinutes: interval,
      notifications: source.notifications !== false,
      repositories: repositories
    }
  }

  function loadConfig(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      root.config = root.normalizeConfig(parsed)
      root.probeError = ""
    } catch (error) {
      root.config = root.defaultConfig()
      root.probeError = "Invalid configuration: " + error
    }
    refreshSoon.restart()
  }

  function saveConfig(next) {
    var normalized = root.normalizeConfig(next)
    root.config = normalized
    configFile.setText(JSON.stringify(normalized, null, 2) + "\n")
    refreshSoon.restart()
  }

  function updateGlobals(interval, notifications) {
    var next = JSON.parse(JSON.stringify(root.config))
    next.intervalMinutes = interval
    next.notifications = notifications
    root.saveConfig(next)
  }

  function refresh() {
    if (checkProc.running) return
    root.receivedResult = false
    checkProc.running = true
  }

  function rowLabel(row) {
    var label = String(row.branchLabel || "")
    return label || String(row.branch || "?").slice(0, 1).toUpperCase()
  }

  function statusColor(state) {
    switch (state) {
      case "current": return "#78c88a"
      case "behind": return "#ef7777"
      case "ahead": case "diverged": case "different": return "#eea25a"
      case "error": return "#e5c76b"
      default: return Color.muted
    }
  }

  function tooltip(row) {
    var labels = {
      current: "Up to date",
      behind: "New remote commits available",
      ahead: "Local branch is ahead",
      diverged: "Local and remote histories diverged",
      different: "Different commit; history unknown without fetching",
      missing: "Local branch is missing",
      error: "Check failed"
    }
    var lines = [String(row.repoName || "Repository") + " · " + String(row.branch || "")]
    var known = labels[row.state] || String(row.message || "Not checked yet")
    if (root.probeError) {
      lines.push("Last known status: " + known)
      lines.push(root.probeError)
      lines.push("Data may be stale")
    } else {
      lines.push(known)
      if (row.message && row.message !== labels[row.state]) lines.push(String(row.message))
    }
    if (row.checkout) lines.push("Checked out: " + row.checkout)
    lines.push("Remote: " + String(row.remoteName || "origin"))
    if (checkProc.running) lines.push("Checking …")
    else if (root.lastCheck) lines.push((root.probeError ? "Last successful check: " : "Checked ") + root.lastCheck)
    return lines.join("\n")
  }

  function groups() {
    var revision = root.rowsRevision
    var byId = ({})
    var list = []
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      var id = String(row.repoId || "repo-" + i)
      if (!byId[id]) {
        byId[id] = { id: id, name: row.repoName, label: row.repoLabel, branches: [] }
        list.push(byId[id])
      }
      byId[id].branches.push(row)
    }
    return list
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: {
      root.config = root.defaultConfig()
      refreshSoon.restart()
    }
    onFileChanged: reload()
  }

  Process {
    id: checkProc
    command: [root.scriptDir + "/omarchy-branch-watch-check", "--json", "--config", root.configPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""))
          if (data.schemaVersion !== 1 || !Array.isArray(data.rows)) throw new Error("Incomplete probe data")
          var allowed = ["current", "behind", "ahead", "diverged", "different", "missing", "error"]
          for (var i = 0; i < data.rows.length; i++) {
            if (allowed.indexOf(String(data.rows[i].state)) === -1) throw new Error("Invalid branch state")
          }
          root.rows = data.rows
          root.rowsRevision++
          root.lastCheck = Qt.formatDateTime(new Date(data.checkedAt), "yyyy-MM-dd HH:mm")
          root.probeError = ""
          root.receivedResult = true
        } catch (error) {
          root.probeError = "No valid response from the Branch Watch helper"
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.probeError = (exitCode === 124 || exitCode === 137)
        ? "Branch Watch timed out" : "Branch Watch helper exited with error " + exitCode
      else if (!root.receivedResult && !root.probeError) root.probeError = "Branch Watch helper returned no result"
    }
  }

  Component.onDestruction: checkProc.running = false
  Component.onCompleted: refreshSoon.restart()

  Timer {
    id: pollTimer
    interval: Math.max(1, Number(root.config.intervalMinutes) || 10) * 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: refreshSoon
    interval: 50
    repeat: false
    onTriggered: root.refresh()
  }

  implicitWidth: content.implicitWidth
  implicitHeight: content.implicitHeight

  Grid {
    id: content
    columns: root.vertical ? 1 : Math.max(1, root.groups().length)
    spacing: Style.space(3)

    WidgetButton {
      visible: root.groups().length === 0
      bar: root.bar
      text: "GIT"
      fixedWidth: root.vertical ? root.barSize : -1
      fixedHeight: root.barSize
      tooltipText: root.probeError || "Branch Watch has no repositories. Right-click to configure."
      onPressed: function(button) {
        if (button === Qt.RightButton) root.toggle()
        else root.refresh()
      }
    }

    Repeater {
      model: root.groups()

      Item {
        id: repoGroup
        required property var modelData
        required property int index
        implicitWidth: root.vertical ? root.barSize : groupRow.implicitWidth + Style.space(index > 0 ? 10 : 0)
        implicitHeight: root.vertical ? groupRow.implicitHeight + Style.space(index > 0 ? 10 : 0) : root.barSize

        Rectangle {
          visible: repoGroup.index > 0
          color: Util.alpha(root.fg, 0.18)
          width: root.vertical ? root.barSize - Style.space(10) : Style.space(1)
          height: root.vertical ? Style.space(1) : Style.space(12)
          x: root.vertical ? Style.space(5) : 0
          y: root.vertical ? 0 : (parent.height - height) / 2
        }

        Grid {
          id: groupRow
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          columns: root.vertical ? 1 : repoGroup.modelData.branches.length + 1
          rows: root.vertical ? repoGroup.modelData.branches.length + 1 : 1
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: String(repoGroup.modelData.label || repoGroup.modelData.name || "GIT")
            color: Util.alpha(root.fg, 0.65)
            font.family: root.fontFam
            font.pixelSize: Math.max(8, Style.font.caption - 1)
            font.bold: true
            width: root.vertical ? root.barSize : implicitWidth
            height: root.vertical ? implicitHeight : root.barSize
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          Repeater {
            model: repoGroup.modelData.branches

            WidgetButton {
              id: chip
              required property var modelData
              readonly property string branchStatus: root.probeError ? "error" : String(modelData.state || "error")
              readonly property color branchColor: root.statusColor(branchStatus)
              readonly property bool emphasized: ["behind", "ahead", "diverged", "different", "error"].indexOf(branchStatus) !== -1
              bar: root.bar
              text: root.rowLabel(modelData)
              labelVisible: false
              fixedWidth: root.vertical ? root.barSize : chipBody.implicitWidth + Style.space(13)
              fixedHeight: root.vertical ? chipBody.implicitWidth + Style.space(13) : root.barSize
              tooltipText: root.tooltip(modelData)
              onPressed: function(button) {
                if (button === Qt.RightButton) root.toggle()
                else root.refresh()
              }

              Rectangle {
                anchors.fill: parent
                anchors.topMargin: Style.space(3)
                anchors.bottomMargin: Style.space(3)
                anchors.leftMargin: root.vertical ? Style.space(3) : 0
                anchors.rightMargin: root.vertical ? Style.space(3) : 0
                radius: Style.space(4)
                color: chip.emphasized
                  ? Util.alpha(chip.branchColor, chip.tooltipHovered ? 0.20 : 0.11)
                  : Util.alpha(chip.foreground, chip.tooltipHovered ? 0.13 : 0.055)
                border.width: 1
                border.color: chip.emphasized
                  ? Util.alpha(chip.branchColor, chip.tooltipHovered ? 0.32 : 0.20)
                  : Util.alpha(chip.foreground, chip.tooltipHovered ? 0.18 : 0.06)
                Behavior on color { ColorAnimation { duration: Style.duration(120) } }
                Behavior on border.color { ColorAnimation { duration: Style.duration(120) } }
              }

              Row {
                id: chipBody
                anchors.centerIn: parent
                spacing: Style.space(5)
                rotation: root.vertical ? -90 : 0
                Rectangle {
                  id: statusDot
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: chip.branchColor
                  opacity: checkProc.running ? 0.45 : 1
                  Behavior on opacity { NumberAnimation { duration: Style.duration(150) } }
                  SequentialAnimation on scale {
                    running: chip.branchStatus === "behind" && !checkProc.running
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 1.28; duration: Style.duration(850); easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1.28; to: 1; duration: Style.duration(850); easing.type: Easing.InOutSine }
                    onRunningChanged: if (!running) statusDot.scale = 1
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.rowLabel(chip.modelData)
                  color: chip.foreground
                  font.family: chip.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                visible: Boolean(chip.modelData.checkedOut)
                color: Util.alpha(chip.foreground, 0.65)
                width: root.vertical ? Style.space(1) : chip.width - Style.space(14)
                height: root.vertical ? chip.height - Style.space(14) : Style.space(1)
                x: root.vertical ? chip.width - Style.space(4) : Style.space(7)
                y: root.vertical ? Style.space(7) : chip.height - Style.space(4)
              }
            }
          }
        }
      }
    }
  }

  // A KeyboardPanel needs a real bar window backend. Keep it unloaded in
  // headless validation and before the shell attaches this widget to a bar.
  Loader {
    active: root.bar !== null
    sourceComponent: Component {
      KeyboardPanel {
        id: settingsPanel
        anchorItem: content
        owner: root
        bar: root.bar
        open: root.opened
        contentWidth: fittedContentWidth(Style.space(430))
        contentHeight: fittedContentHeight(Math.min(settingsLoader.item ? settingsLoader.item.implicitHeight : 0, Style.space(620)))

        Loader {
          id: settingsLoader
          active: root.opened
          width: parent.width
          sourceComponent: Component {
            Flickable {
          id: scroller
          implicitHeight: Math.min(form.implicitHeight, Style.space(620))
          contentWidth: width
          contentHeight: form.implicitHeight
          clip: true

          Column {
            id: form
            width: scroller.width
            spacing: Style.space(8)
            property int editIndex: -2

            function startAdd() {
              editIndex = -1
              nameField.text = ""
              labelField.text = ""
              pathField.text = ""
              remoteField.text = "origin"
              branchesField.text = ""
              repoNotifications.checked = true
              nameField.forceActiveFocus()
            }

            function startEdit(index) {
              var repo = root.config.repositories[index]
              editIndex = index
              nameField.text = String(repo.name || "")
              labelField.text = String(repo.label || "")
              pathField.text = String(repo.path || "")
              remoteField.text = String(repo.remote || "origin")
              var parts = []
              var branches = Array.isArray(repo.branches) ? repo.branches : []
              for (var i = 0; i < branches.length; i++) {
                var branch = typeof branches[i] === "string" ? { name: branches[i] } : branches[i]
                if (!branch || !branch.name) continue
                parts.push(String(branch.name) + (branch.label ? "=" + String(branch.label) : ""))
              }
              branchesField.text = parts.join(", ")
              repoNotifications.checked = repo.notifications !== false
            }

            function parsedBranches(text) {
              var result = []
              var seen = ({})
              var parts = String(text || "").split(",")
              for (var i = 0; i < parts.length && result.length < 16; i++) {
                var token = parts[i].trim()
                if (!token) continue
                var equal = token.indexOf("=")
                var name = (equal < 0 ? token : token.slice(0, equal)).trim()
                var label = (equal < 0 ? name.slice(0, 1).toUpperCase() : token.slice(equal + 1)).trim()
                if (!name || seen[name]) continue
                seen[name] = true
                result.push({ name: name, label: label || name.slice(0, 1).toUpperCase() })
              }
              return result
            }

            function commitEdit() {
              var name = nameField.text.trim()
              var path = pathField.text.trim()
              if (!name || !path) {
                editorError.text = "Name and local path are required."
                return
              }
              if (editIndex < 0 && root.config.repositories.length >= 24) {
                editorError.text = "The limit of 24 repositories has been reached."
                return
              }
              var next = JSON.parse(JSON.stringify(root.config))
              var existing = editIndex >= 0 ? next.repositories[editIndex] : null
              var record = {
                id: existing && existing.id ? existing.id : "repo-" + Date.now(),
                name: name,
                label: labelField.text.trim() || name.slice(0, 4).toUpperCase(),
                path: path,
                remote: remoteField.text.trim() || "origin",
                notifications: repoNotifications.checked,
                branches: parsedBranches(branchesField.text)
              }
              if (editIndex >= 0) next.repositories[editIndex] = record
              else next.repositories.push(record)
              root.saveConfig(next)
              editIndex = -2
            }

            function removeEdit() {
              if (editIndex < 0) { editIndex = -2; return }
              var next = JSON.parse(JSON.stringify(root.config))
              next.repositories.splice(editIndex, 1)
              root.saveConfig(next)
              editIndex = -2
            }

            PanelSectionHeader {
              text: "Branch Watch"
              foreground: root.fg
              fontFamily: root.fontFam
            }

            Text {
              width: form.width
              textFormat: Text.PlainText
              text: "Read-only live comparison of local branches with any Git remote."
              wrapMode: Text.WordWrap
              color: Util.alpha(root.fg, 0.70)
              font.family: root.fontFam
              font.pixelSize: Style.font.caption
            }

            NumberField {
              width: form.width
              label: "Check every (minutes)"
              field.editable: false
              value: Number(root.config.intervalMinutes) || 10
              from: 1
              to: 1440
              stepSize: 1
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fontFam
              onModified: function(value) { root.updateGlobals(value, root.config.notifications !== false) }
            }

            Toggle {
              width: form.width
              label: "Desktop notifications"
              description: "Notify once when a new differing remote commit appears"
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fontFam
              checked: root.config.notifications !== false
              onClicked: root.updateGlobals(root.config.intervalMinutes, !checked)
            }

            PanelSectionHeader {
              text: "Repositories"
              foreground: root.fg
              fontFamily: root.fontFam
            }

            Repeater {
              model: root.config.repositories
              Rectangle {
                required property var modelData
                required property int index
                width: form.width
                height: Style.space(46)
                radius: Style.cornerRadius
                color: repoMouse.containsMouse ? Util.alpha(root.fg, 0.10) : Util.alpha(root.fg, 0.05)
                border.width: 1
                border.color: Util.alpha(root.fg, 0.10)
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(24)
                  textFormat: Text.PlainText
                  text: String(parent.modelData.name || "Repository") + "  ·  " + String(parent.modelData.remote || "origin")
                  elide: Text.ElideMiddle
                  color: root.fg
                  font.family: root.fontFam
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  id: repoMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: form.startEdit(parent.index)
                }
              }
            }

            Rectangle {
              visible: root.config.repositories.length < 24
              width: form.width
              height: Style.space(40)
              radius: Style.cornerRadius
              color: addMouse.containsMouse ? Util.alpha(Color.accent, 0.20) : Util.alpha(Color.accent, 0.10)
              border.width: 1
              border.color: Util.alpha(Color.accent, 0.35)
              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "+ Add repository"
                color: root.fg
                font.family: root.fontFam
                font.pixelSize: Style.font.body
                font.bold: true
              }
              MouseArea {
                id: addMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: form.startAdd()
              }
            }

            Text {
              visible: root.config.repositories.length >= 24
              width: form.width
              textFormat: Text.PlainText
              text: "Repository limit reached (24)."
              color: Util.alpha(root.fg, 0.65)
              font.family: root.fontFam
              font.pixelSize: Style.font.caption
            }

            Column {
              visible: form.editIndex >= -1
              width: form.width
              spacing: Style.space(6)

              Text { text: form.editIndex < 0 ? "Add repository" : "Edit repository"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.subtitle; font.bold: true }
              Text { text: "Name"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField { id: nameField; width: parent.width; placeholderText: "Backend"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam }
              Text { text: "Short bar label"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField { id: labelField; width: parent.width; placeholderText: "API"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam }
              Text { text: "Local repository path"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField { id: pathField; width: parent.width; placeholderText: "~/projects/backend"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam }
              Text { text: "Git remote name or URL"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField { id: remoteField; width: parent.width; placeholderText: "origin"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam }
              Text { text: "Branches — branch=label, comma separated; blank detects main, master, or another default"; textFormat: Text.PlainText; width: parent.width; wrapMode: Text.WordWrap; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField { id: branchesField; width: parent.width; placeholderText: "develop=D, master=M"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam }
              Toggle { id: repoNotifications; width: parent.width; label: "Notifications for this repository"; foreground: root.fg; accent: Color.accent; fontFamily: root.fontFam; checked: true }
              Text { id: editorError; width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap; color: "#ef7777"; font.family: root.fontFam; font.pixelSize: Style.font.caption }

              Row {
                spacing: Style.space(8)
                Repeater {
                  model: ["Save", form.editIndex >= 0 ? "Remove" : "Cancel"]
                  Rectangle {
                    required property string modelData
                    required property int index
                    width: Style.space(100)
                    height: Style.space(38)
                    radius: Style.cornerRadius
                    color: actionMouse.containsMouse ? Util.alpha(index === 0 ? Color.accent : root.fg, 0.22) : Util.alpha(index === 0 ? Color.accent : root.fg, 0.11)
                    border.width: 1
                    border.color: Util.alpha(index === 0 ? Color.accent : root.fg, 0.30)
                    Text { anchors.centerIn: parent; text: parent.modelData; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.body }
                    MouseArea {
                      id: actionMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        editorError.text = ""
                        if (parent.index === 0) form.commitEdit()
                        else form.removeEdit()
                      }
                    }
                  }
                }
              }
            }

            Text {
              width: form.width
              textFormat: Text.PlainText
              text: root.configPath
              elide: Text.ElideMiddle
              color: Util.alpha(root.fg, 0.45)
              font.family: root.fontFam
              font.pixelSize: Style.font.caption
            }
          }
            }
          }
        }
      }
    }
  }
}
