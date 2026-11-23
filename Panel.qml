import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Configurable, read-only Git branch monitoring. The helper performs one live
// remote query per repository and never fetches or changes a repository.
Panel {
  id: root
  moduleName: "smartalb.branch-watch"
  ipcTarget: "smartalb.branch-watch"
  manageIpc: true

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
  property bool refreshPending: false
  property bool folderDialogActive: false
  property bool editorDirty: false
  property bool closeConfirmation: false
  property int configRevision: 0
  property int activeProbeRevision: -1
  property int rowsRevision: 0

  onRowsRevisionChanged: Qt.callLater(function() { content.forceLayout() })

  // Protect in-progress repository edits from outside-click dismissal. The
  // folder picker bypasses this guard while the form stays loaded off-screen.
  function close() {
    if (root.editorDirty && !root.folderDialogActive) {
      root.closeConfirmation = true
      return
    }
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function discardEditorAndClose() {
    root.editorDirty = false
    root.closeConfirmation = false
    root.controller.hide()
  }

  function defaultConfig() {
    return { schemaVersion: 1, intervalMinutes: 10, notifications: true, repositories: [] }
  }

  function normalizeConfig(value) {
    var source = value && typeof value === "object" ? value : ({})
    var interval = Math.floor(Number(source.intervalMinutes))
    if (!isFinite(interval) || interval < 1) interval = 10
    interval = Math.min(interval, 1440)
    var repositories = []
    var repositoryIds = ({})
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
        var branchKey = "\u0001" + branchName
        if (!branchName || seen[branchKey]) continue
        seen[branchKey] = true
        branches.push({
          name: branchName,
          label: String(candidate.label || branchName.slice(0, 1).toUpperCase()).slice(0, 12)
        })
      }
      var baseId = String(raw.id || "repo-" + i).slice(0, 128)
      var uniqueId = baseId
      var suffix = 2
      while (repositoryIds["\u0001" + uniqueId])
        uniqueId = baseId.slice(0, Math.max(1, 128 - String(suffix).length - 1)) + "-" + suffix++
      repositoryIds["\u0001" + uniqueId] = true
      repositories.push({
        id: uniqueId,
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
      root.configRevision++
      root.probeError = ""
    } catch (error) {
      root.config = root.defaultConfig()
      root.configRevision++
      root.probeError = "Invalid configuration: " + error
    }
    refreshSoon.restart()
  }

  function saveConfig(next) {
    var normalized = root.normalizeConfig(next)
    root.config = normalized
    root.configRevision++
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
    if (checkProc.running) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    root.activeProbeRevision = root.configRevision
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
      var id = String(row.repoKey || row.repoId || "repo-" + i)
      var groupKey = "\u0001" + id
      if (!byId[groupKey]) {
        byId[groupKey] = { id: id, name: row.repoName, label: row.repoLabel, branches: [] }
        list.push(byId[groupKey])
      }
      byId[groupKey].branches.push(row)
    }
    return list
  }

  function repositorySummary(repository, repositoryIndex) {
    var revision = root.rowsRevision
    var id = String(repository.id || "")
    var counts = ({current: 0, behind: 0, ahead: 0, diverged: 0,
      different: 0, missing: 0, error: 0})
    var total = 0
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      var rowKey = String(row.repoKey || "")
      if (rowKey) {
        if (rowKey.indexOf(String(repositoryIndex) + ":") !== 0) continue
        if (rowKey.slice(rowKey.indexOf(":") + 1) !== id) continue
      } else if (String(row.repoId || "") !== id) continue
      var state = String(row.state || "error")
      if (counts[state] === undefined) counts[state] = 0
      counts[state]++
      total++
    }
    if (total === 0) return "Not checked yet"
    var parts = []
    if (counts.current) parts.push(counts.current + " current")
    if (counts.behind) parts.push(counts.behind + " behind")
    var different = counts.ahead + counts.diverged + counts.different
    if (different) parts.push(different + " different")
    if (counts.missing) parts.push(counts.missing + " missing")
    if (counts.error) parts.push(counts.error + " error")
    return parts.join(" · ") + (root.lastCheck ? " · " + root.lastCheck : "")
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
      root.configRevision++
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
          root.receivedResult = true
          if (root.activeProbeRevision !== root.configRevision) {
            root.refreshPending = true
            return
          }
          root.rows = data.rows
          root.rowsRevision++
          root.lastCheck = Qt.formatDateTime(new Date(data.checkedAt), "yyyy-MM-dd HH:mm")
          root.probeError = ""
        } catch (error) {
          if (root.activeProbeRevision === root.configRevision)
            root.probeError = "No valid response from the Branch Watch helper"
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (root.activeProbeRevision === root.configRevision) {
        if (exitCode !== 0) root.probeError = (exitCode === 124 || exitCode === 137)
          ? "Branch Watch timed out" : "Branch Watch helper exited with error " + exitCode
        else if (!root.receivedResult && !root.probeError) root.probeError = "Branch Watch helper returned no result"
      }
      if (root.refreshPending || root.activeProbeRevision !== root.configRevision)
        Qt.callLater(root.refresh)
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
          active: root.opened || root.folderDialogActive
          width: parent.width
          sourceComponent: Component {
            Item {
              id: settingsBody
              readonly property real footerSpace: editorActions.visible
                ? editorActions.implicitHeight + Style.space(8) : 0
              implicitHeight: Math.min(form.implicitHeight + footerSpace, Style.space(620))

              Flickable {
          id: scroller
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(0, parent.height - settingsBody.footerSpace)
          contentWidth: width
          contentHeight: form.implicitHeight
          clip: true

          Column {
            id: form
            width: scroller.width
            spacing: Style.space(8)
            property int editIndex: -2
            property string editId: ""
            property bool confirmRemove: false
            property bool confirmCancel: false
            property int editSession: 0
            property string editBaseline: ""
            property var branchLabelDrafts: ({})
            property int branchDraftRevision: 0
            property var discoveredBranches: []
            property bool branchDiscoveryLoading: false
            property bool branchDiscoveryReceived: false
            property bool branchDiscoveryTruncated: false
            property bool branchListExpanded: false
            property string branchDiscoveryError: ""
            property string activeDiscoveryKey: ""
            property int activeDiscoverySession: -1
            property string validationState: "unknown"
            property string validationMessage: "Repository not validated yet."
            property string detectedDefaultBranch: ""

            function startAdd() {
              if (root.editorDirty) {
                root.closeConfirmation = true
                return
              }
              editIndex = -1
              editSession++
              editBaseline = ""
              editorError.text = ""
              editId = ""
              confirmRemove = false
              confirmCancel = false
              nameField.text = ""
              labelField.text = ""
              pathField.text = ""
              remoteField.text = "origin"
              branchesField.text = ""
              resetBranchLabelDrafts([])
              discoveredBranches = []
              branchDiscoveryTruncated = false
              branchListExpanded = false
              branchDiscoveryError = ""
              branchFilter.text = ""
              validationState = "unknown"
              validationMessage = "Repository not validated yet."
              detectedDefaultBranch = ""
              repoNotifications.checked = true
              root.editorDirty = false
              root.closeConfirmation = false
              if (branchDiscoveryProc.running) branchDiscoveryProc.running = false
              branchDiscoveryLoading = false
              nameField.forceActiveFocus()
            }

            function startEdit(index) {
              if (root.editorDirty) {
                root.closeConfirmation = true
                return
              }
              var repo = root.config.repositories[index]
              editIndex = index
              editSession++
              editId = String(repo.id || "")
              editBaseline = JSON.stringify(repo)
              editorError.text = ""
              confirmRemove = false
              confirmCancel = false
              nameField.text = String(repo.name || "")
              labelField.text = String(repo.label || "")
              pathField.text = String(repo.path || "")
              remoteField.text = String(repo.remote || "origin")
              var parts = []
              var branches = Array.isArray(repo.branches) ? repo.branches : []
              for (var i = 0; i < branches.length; i++) {
                var branch = typeof branches[i] === "string" ? { name: branches[i] } : branches[i]
                if (!branch || !branch.name) continue
                parts.push({name: String(branch.name), label: String(branch.label || "")})
              }
              branchesField.text = formatBranches(parts)
              resetBranchLabelDrafts(parts)
              discoveredBranches = []
              branchDiscoveryTruncated = false
              branchListExpanded = false
              branchDiscoveryError = ""
              branchFilter.text = ""
              validationState = "unknown"
              validationMessage = "Select Discover branches to validate the repository and remote."
              detectedDefaultBranch = ""
              repoNotifications.checked = repo.notifications !== false
              root.editorDirty = false
              root.closeConfirmation = false
              if (branchDiscoveryProc.running) branchDiscoveryProc.running = false
              branchDiscoveryLoading = false
            }

            function markDirty() {
              root.editorDirty = true
              root.closeConfirmation = false
              confirmCancel = false
            }

            function invalidateValidation() {
              if (branchDiscoveryProc.running) branchDiscoveryProc.running = false
              branchDiscoveryLoading = false
              validationState = "unknown"
              validationMessage = "Repository settings changed; validate again."
              detectedDefaultBranch = ""
              discoveredBranches = []
              branchDiscoveryTruncated = false
              branchListExpanded = false
            }

            function parsedBranches(text) {
              var result = []
              var seen = ({})
              var input = String(text || "")
              var namePart = ""
              var labelPart = ""
              var inLabel = false
              var escaped = false

              function appendBranch() {
                var name = namePart.trim()
                var label = (inLabel ? labelPart : name.slice(0, 1).toUpperCase()).trim()
                var branchKey = "\u0001" + name
                if (!name || seen[branchKey]) return
                seen[branchKey] = true
                result.push({ name: name, label: label || name.slice(0, 1).toUpperCase() })
              }

              for (var i = 0; i < input.length; i++) {
                var character = input.charAt(i)
                if (escaped) {
                  if (inLabel) labelPart += character
                  else namePart += character
                  escaped = false
                } else if (character === "\\") {
                  escaped = true
                } else if (character === "=" && !inLabel) {
                  inLabel = true
                } else if (character === ",") {
                  appendBranch()
                  namePart = ""
                  labelPart = ""
                  inLabel = false
                } else if (inLabel) {
                  labelPart += character
                } else {
                  namePart += character
                }
              }
              if (escaped) {
                if (inLabel) labelPart += "\\"
                else namePart += "\\"
              }
              appendBranch()
              return result
            }

            function branchDraftKey(name) {
              return "\u0001" + String(name || "")
            }

            function resetBranchLabelDrafts(branches) {
              var drafts = ({})
              for (var i = 0; i < branches.length; i++) {
                var branch = typeof branches[i] === "string" ? {name: branches[i]} : branches[i]
                if (!branch || !branch.name) continue
                drafts[branchDraftKey(branch.name)] = String(branch.label
                  || String(branch.name).slice(0, 1).toUpperCase())
              }
              branchLabelDrafts = drafts
              branchDraftRevision++
            }

            function branchLabelDraft(name, fallback) {
              var revision = branchDraftRevision
              var value = branchLabelDrafts[branchDraftKey(name)]
              return value === undefined ? String(fallback || "") : String(value)
            }

            function setBranchLabelDraft(name, label) {
              branchLabelDrafts[branchDraftKey(name)] = String(label || "")
              branchDraftRevision++
              markDirty()
            }

            function selectedBranchesWithDraftLabels() {
              var revision = branchDraftRevision
              var selected = parsedBranches(branchesField.text)
              for (var i = 0; i < selected.length; i++) {
                var draft = branchLabelDrafts[branchDraftKey(selected[i].name)]
                if (draft !== undefined)
                  selected[i].label = String(draft || "").trim()
                    || String(selected[i].name).slice(0, 1).toUpperCase()
              }
              return selected
            }

            function expandedPath(path) {
              var value = String(path || "").trim()
              if (value === "~") return Quickshell.env("HOME")
              if (value.indexOf("~/") === 0) return Quickshell.env("HOME") + value.slice(1)
              return value
            }

            function chooseRepositoryFolder() {
              var start = expandedPath(pathField.text)
              repositoryFolderDialog.currentFolder = Util.fileUrl(start || Quickshell.env("HOME"))
              // KeyboardPanel is a layer-shell surface and would otherwise
              // remain above the native picker. Keep this form loaded while
              // closing the panel, then open the dialog after focus is freed.
              root.folderDialogActive = true
              root.close()
              Qt.callLater(repositoryFolderDialog.open)
            }

            function returnFromFolderDialog() {
              root.open()
              Qt.callLater(function() { root.folderDialogActive = false })
            }

            function selectedLocalPath(url) {
              var value = String(url || "")
              if (value.indexOf("file://") !== 0) return ""
              return decodeURIComponent(value.slice(7))
            }

            function discoveryKey() {
              return expandedPath(pathField.text) + "\u0000" + (remoteField.text.trim() || "origin")
            }

            function discoveryRequestCurrent() {
              return activeDiscoverySession === editSession
                && activeDiscoveryKey === discoveryKey()
            }

            function discoverBranches() {
              if (branchListExpanded) {
                branchListExpanded = false
                return
              }
              if (discoveredBranches.length > 0
                  && activeDiscoverySession === editSession
                  && activeDiscoveryKey === discoveryKey()) {
                branchListExpanded = true
                return
              }
              if (!pathField.text.trim()) {
                branchDiscoveryError = "Select or enter a local repository first."
                return
              }
              if (branchDiscoveryProc.running) return
              branchDiscoveryError = ""
              discoveredBranches = []
              branchDiscoveryTruncated = false
              branchListExpanded = false
              branchDiscoveryReceived = false
              branchDiscoveryLoading = true
              validationState = "checking"
              validationMessage = "Checking repository and remote…"
              activeDiscoverySession = editSession
              activeDiscoveryKey = discoveryKey()
              branchDiscoveryProc.running = true
            }

            function branchIsSelected(name) {
              var selected = parsedBranches(branchesField.text)
              for (var i = 0; i < selected.length; i++)
                if (selected[i].name === name) return true
              return false
            }

            function selectedBranches() {
              return selectedBranchesWithDraftLabels()
            }

            function removeBranch(name) {
              var selected = selectedBranchesWithDraftLabels()
              for (var i = 0; i < selected.length; i++) {
                if (selected[i].name === name) {
                  selected.splice(i, 1)
                  branchesField.text = formatBranches(selected)
                  delete branchLabelDrafts[branchDraftKey(name)]
                  branchDraftRevision++
                  branchDiscoveryError = ""
                  markDirty()
                  return
                }
              }
            }

            function toggleBranch(name) {
              var selected = selectedBranchesWithDraftLabels()
              for (var i = 0; i < selected.length; i++) {
                if (selected[i].name === name) {
                  removeBranch(name)
                  return
                }
              }
              if (selected.length >= 16) {
                branchDiscoveryError = "At most 16 branches can be monitored per repository."
                return
              }
              var defaultLabel = name.slice(0, 1).toUpperCase()
              selected.push({name: name, label: defaultLabel})
              branchLabelDrafts[branchDraftKey(name)] = defaultLabel
              branchDraftRevision++
              branchesField.text = formatBranches(selected)
              branchDiscoveryError = ""
              markDirty()
            }

            function duplicateBranchLabels() {
              var selected = selectedBranchesWithDraftLabels()
              var labels = ({})
              var duplicates = []
              for (var i = 0; i < selected.length; i++) {
                var label = String(selected[i].label || "")
                var key = "\u0001" + label
                if (labels[key] && duplicates.indexOf(label) === -1) duplicates.push(label)
                labels[key] = true
              }
              return duplicates
            }

            function formatBranches(branches) {
              var parts = []
              function escaped(value) {
                return String(value || "").replace(/\\/g, "\\\\").replace(/,/g, "\\,").replace(/=/g, "\\=")
              }
              for (var i = 0; i < branches.length; i++) {
                var branch = typeof branches[i] === "string" ? {name: branches[i]} : branches[i]
                if (!branch || !branch.name) continue
                parts.push(escaped(branch.name) + "="
                  + escaped(branch.label || String(branch.name).slice(0, 1).toUpperCase()))
              }
              return parts.join(", ")
            }

            function filteredDiscoveredBranches() {
              var needle = branchFilter.text.trim().toLowerCase()
              if (!needle) return discoveredBranches
              var filtered = []
              for (var i = 0; i < discoveredBranches.length; i++) {
                if (String(discoveredBranches[i].name || "").toLowerCase().indexOf(needle) !== -1)
                  filtered.push(discoveredBranches[i])
              }
              return filtered
            }

            function branchDescription(branch) {
              var location = branch.local && branch.remote ? "Local + Remote"
                : branch.remote ? "Remote only" : "Local only"
              var details = []
              if (branch.default) details.push("Default")
              if (branch.checkedOut) details.push("Checked out")
              return (branchIsSelected(String(branch.name || "")) ? "✓  " : "○  ")
                + String(branch.name || "") + "  ·  " + location
                + (details.length ? "  ·  " + details.join(", ") : "")
            }

            function currentEditIndex() {
              if (!editId) return editIndex
              for (var i = 0; i < root.config.repositories.length; i++) {
                if (String(root.config.repositories[i].id || "") === editId) return i
              }
              return -1
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
              var selectedBranches = selectedBranchesWithDraftLabels()
              if (selectedBranches.length > 16) {
                editorError.text = "At most 16 branches can be monitored per repository."
                return
              }
              var next = JSON.parse(JSON.stringify(root.config))
              var targetIndex = currentEditIndex()
              if (editIndex >= 0 && targetIndex < 0) {
                editorError.text = "This repository was changed or removed elsewhere. Reopen it and try again."
                return
              }
              var existing = targetIndex >= 0 ? next.repositories[targetIndex] : null
              if (existing && JSON.stringify(existing) !== editBaseline) {
                editorError.text = "This repository was changed elsewhere. Reopen it before saving."
                return
              }
              var record = {
                id: existing && existing.id ? existing.id : "repo-" + Date.now(),
                name: name,
                label: labelField.text.trim() || name.slice(0, 4).toUpperCase(),
                path: path,
                remote: remoteField.text.trim() || "origin",
                notifications: repoNotifications.checked,
                branches: selectedBranches
              }
              if (targetIndex >= 0) next.repositories[targetIndex] = record
              else next.repositories.push(record)
              root.saveConfig(next)
              editIndex = -2
              editId = ""
              confirmRemove = false
              confirmCancel = false
              root.editorDirty = false
              root.closeConfirmation = false
            }

            function removeEdit() {
              if (editIndex < 0) {
                requestCancelEdit()
                return
              }
              if (!confirmRemove) {
                confirmRemove = true
                editorError.text = "Select “Confirm remove” to remove this repository."
                return
              }
              var next = JSON.parse(JSON.stringify(root.config))
              var targetIndex = currentEditIndex()
              if (targetIndex < 0) {
                editorError.text = "This repository was already changed or removed elsewhere."
                confirmRemove = false
                return
              }
              if (JSON.stringify(next.repositories[targetIndex]) !== editBaseline) {
                editorError.text = "This repository was changed elsewhere. Reopen it before removing."
                confirmRemove = false
                return
              }
              next.repositories.splice(targetIndex, 1)
              root.saveConfig(next)
              editIndex = -2
              editId = ""
              confirmRemove = false
              confirmCancel = false
              root.editorDirty = false
              root.closeConfirmation = false
            }

            function requestCancelEdit() {
              if (root.editorDirty) {
                confirmCancel = true
                return
              }
              discardEdit()
            }

            function discardEdit() {
              root.editorDirty = false
              root.closeConfirmation = false
              confirmCancel = false
              confirmRemove = false
              editIndex = -2
              editId = ""
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
              Button {
                required property var modelData
                required property int index
                width: form.width
                height: Style.space(58)
                text: String(modelData.name || "Repository") + "  ·  " + String(modelData.remote || "origin")
                  + "\n" + root.repositorySummary(modelData, index)
                foreground: root.fg
                accent: Color.accent
                fontFamily: root.fontFam
                leftAlign: true
                bordered: true
                focusable: true
                onClicked: form.startEdit(index)
              }
            }

            Button {
              visible: root.config.repositories.length < 24
              width: form.width
              height: Style.space(40)
              text: "+ Add repository"
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fontFam
              bordered: true
              focusable: true
              onClicked: form.startAdd()
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
              TextField { id: nameField; width: parent.width; placeholderText: "Backend"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam; onTextEdited: form.markDirty() }
              Text { text: "Short bar label"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField { id: labelField; width: parent.width; placeholderText: "API"; foreground: root.fg; accent: Color.accent; font.family: root.fontFam; onTextEdited: form.markDirty() }
              Text { text: "Local repository path"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              RowLayout {
                width: parent.width
                spacing: Style.space(6)
                TextField {
                  id: pathField
                  Layout.fillWidth: true
                  placeholderText: "~/projects/backend"
                  foreground: root.fg
                  accent: Color.accent
                  font.family: root.fontFam
                  onTextEdited: {
                    form.markDirty()
                    form.invalidateValidation()
                  }
                }
                Button {
                  text: "Browse…"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  onClicked: form.chooseRepositoryFolder()
                }
              }
              FolderDialog {
                id: repositoryFolderDialog
                title: "Select Git repository"
                currentFolder: Util.fileUrl(Quickshell.env("HOME"))
                options: FolderDialog.ReadOnly
                onAccepted: {
                  var selected = form.selectedLocalPath(selectedFolder)
                  if (selected) {
                    pathField.text = selected
                    form.markDirty()
                    form.invalidateValidation()
                  }
                  form.returnFromFolderDialog()
                }
                onRejected: form.returnFromFolderDialog()
              }
              Process {
                id: branchDiscoveryProc
                command: [
                  root.scriptDir + "/branch-watch-list-branches",
                  "--json",
                  "--path", form.expandedPath(pathField.text),
                  "--remote", remoteField.text.trim() || "origin"
                ]
                stdout: StdioCollector {
                  waitForEnd: true
                  onStreamFinished: {
                    if (!form.discoveryRequestCurrent()) return
                    form.branchDiscoveryReceived = true
                    try {
                      var data = JSON.parse(String(text || ""))
                      if (data.schemaVersion !== 1 || !Array.isArray(data.branches))
                        throw new Error("Invalid branch response")
                      form.discoveredBranches = data.branches
                      form.branchDiscoveryTruncated = data.truncated === true
                      form.branchDiscoveryError = String(data.error || "")
                      if (!form.branchDiscoveryError && data.branches.length === 0)
                        form.branchDiscoveryError = "No local or remote branches were found."
                      form.detectedDefaultBranch = String(data.defaultBranch || "")
                      form.validationState = form.branchDiscoveryError ? "error" : "valid"
                      form.validationMessage = form.branchDiscoveryError
                        ? form.branchDiscoveryError
                        : "Repository and remote validated"
                          + (form.detectedDefaultBranch
                            ? " · Default: " + form.detectedDefaultBranch : "")
                      form.branchListExpanded = !form.branchDiscoveryError && data.branches.length > 0
                    } catch (error) {
                      form.branchDiscoveryError = "No valid response from the branch discovery helper."
                      form.validationState = "error"
                      form.validationMessage = form.branchDiscoveryError
                    }
                  }
                }
                onExited: function(exitCode, exitStatus) {
                  if (!form.discoveryRequestCurrent()) return
                  form.branchDiscoveryLoading = false
                  if (exitCode !== 0 && !form.branchDiscoveryError)
                    form.branchDiscoveryError = (exitCode === 124 || exitCode === 137)
                      ? "Branch discovery timed out."
                      : "Branch discovery helper exited with error " + exitCode + "."
                  else if (!form.branchDiscoveryReceived && !form.branchDiscoveryError)
                    form.branchDiscoveryError = "Branch discovery helper returned no result."
                  if (form.branchDiscoveryError) {
                    form.validationState = "error"
                    form.validationMessage = form.branchDiscoveryError
                  }
                }
              }
              Text { text: "Git remote name or URL"; textFormat: Text.PlainText; color: root.fg; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              TextField {
                id: remoteField
                width: parent.width
                placeholderText: "origin"
                foreground: root.fg
                accent: Color.accent
                font.family: root.fontFam
                onTextEdited: {
                  form.markDirty()
                  form.invalidateValidation()
                }
              }
              Text {
                width: parent.width
                text: (form.validationState === "valid" ? "✓  "
                  : form.validationState === "error" ? "⚠  "
                  : form.validationState === "checking" ? "…  " : "○  ")
                  + form.validationMessage
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: form.validationState === "valid" ? "#78c88a"
                  : form.validationState === "error" ? "#ef7777"
                  : Util.alpha(root.fg, 0.7)
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              Text {
                text: "Branches — leave the selection empty to follow the remote default branch automatically."
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.fg
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: form.selectedBranches().length > 0
                text: "Tracked branches — edit labels or remove branches"
                textFormat: Text.PlainText
                width: parent.width
                color: Util.alpha(root.fg, 0.7)
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              Repeater {
                // Keep delegates stable while a label is typed. The draft
                // revision updates each TextField binding and warnings, but
                // must not rebuild the row and steal keyboard focus.
                model: form.parsedBranches(branchesField.text)
                RowLayout {
                  required property var modelData
                  width: form.width
                  spacing: Style.space(6)
                  Text {
                    Layout.fillWidth: true
                    text: String(parent.modelData.name || "")
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                    color: root.fg
                    font.family: root.fontFam
                    font.pixelSize: Style.font.body
                  }
                  TextField {
                    Layout.preferredWidth: Style.space(68)
                    text: form.branchLabelDraft(
                      String(parent.modelData.name || ""), String(parent.modelData.label || ""))
                    placeholderText: "Label"
                    foreground: root.fg
                    accent: Color.accent
                    font.family: root.fontFam
                    maximumLength: 12
                    onTextEdited: form.setBranchLabelDraft(
                      String(parent.modelData.name || ""), text)
                    onEditingFinished: branchesField.text = form.formatBranches(
                      form.selectedBranchesWithDraftLabels())
                  }
                  Button {
                    text: "Remove"
                    tooltipText: "Remove " + String(parent.modelData.name || "") + " from tracked branches"
                    foreground: root.fg
                    accent: Color.accent
                    fontFamily: root.fontFam
                    bordered: true
                    focusable: true
                    onClicked: form.removeBranch(String(parent.modelData.name || ""))
                  }
                }
              }
              Text {
                visible: form.duplicateBranchLabels().length > 0
                width: parent.width
                text: "Duplicate bar labels: " + form.duplicateBranchLabels().join(", ")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: "#e5c76b"
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              RowLayout {
                width: parent.width
                spacing: Style.space(6)
                Button {
                  Layout.fillWidth: true
                  text: form.branchDiscoveryLoading ? "Discovering branches…"
                    : form.branchListExpanded ? "Hide branches"
                    : form.discoveredBranches.length > 0
                      && form.activeDiscoveryKey === form.discoveryKey() ? "Show branches"
                    : "Discover branches"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  enabled: !form.branchDiscoveryLoading
                  onClicked: form.discoverBranches()
                }
                Button {
                  text: "Follow default"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  selected: branchesField.text.trim() === ""
                  onClicked: {
                    branchesField.text = ""
                    form.branchListExpanded = false
                    form.branchDiscoveryError = ""
                    form.markDirty()
                  }
                }
              }
              TextField {
                id: branchFilter
                visible: form.branchListExpanded && form.discoveredBranches.length > 8
                width: parent.width
                placeholderText: "Filter discovered branches"
                foreground: root.fg
                accent: Color.accent
                font.family: root.fontFam
              }
              Text {
                visible: form.branchListExpanded
                width: parent.width
                text: form.selectedBranches().length + " selected · "
                  + form.filteredDiscoveredBranches().length + " shown · "
                  + form.discoveredBranches.length + " discovered"
                textFormat: Text.PlainText
                color: Util.alpha(root.fg, 0.7)
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              ListView {
                id: discoveredBranchList
                visible: form.branchListExpanded
                width: parent.width
                height: visible
                  ? Math.min(count, 8) * Style.space(40) + Math.max(0, Math.min(count, 8) - 1) * spacing
                  : 0
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds
                model: form.branchListExpanded ? form.filteredDiscoveredBranches() : []
                delegate: Button {
                  required property var modelData
                  width: discoveredBranchList.width
                  height: Style.space(40)
                  text: form.branchDescription(modelData)
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  leftAlign: true
                  bordered: true
                  focusable: true
                  selected: form.branchIsSelected(String(modelData.name || ""))
                  onClicked: form.toggleBranch(String(modelData.name || ""))
                }
              }
              Text {
                visible: form.branchDiscoveryError !== ""
                width: parent.width
                text: form.branchDiscoveryError
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: "#ef7777"
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: form.branchListExpanded && form.branchDiscoveryTruncated
                width: parent.width
                text: "Showing the first 200 branches. Use the advanced field for another branch."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Util.alpha(root.fg, 0.7)
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              Text {
                text: "Advanced/manual selection — branch=label, comma separated"
                textFormat: Text.PlainText
                width: parent.width
                color: Util.alpha(root.fg, 0.7)
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: branchesField
                width: parent.width
                placeholderText: "develop=D, master=M"
                foreground: root.fg
                accent: Color.accent
                font.family: root.fontFam
                onTextEdited: {
                  form.resetBranchLabelDrafts(form.parsedBranches(text))
                  form.markDirty()
                }
              }
              Toggle { id: repoNotifications; width: parent.width; label: "Notifications for this repository"; foreground: root.fg; accent: Color.accent; fontFamily: root.fontFam; checked: true; onClicked: form.markDirty() }
              Text { id: editorError; width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap; color: "#ef7777"; font.family: root.fontFam; font.pixelSize: Style.font.caption }
              Text {
                visible: root.editorDirty
                width: parent.width
                text: "Unsaved changes"
                textFormat: Text.PlainText
                color: "#e5c76b"
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: root.closeConfirmation || form.confirmCancel
                width: parent.width
                text: root.closeConfirmation
                  ? "Discard the unsaved repository changes and close the panel?"
                  : "Discard the unsaved repository changes?"
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: "#ef7777"
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
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
              Rectangle {
                id: editorFooter
                visible: editorActions.visible
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: settingsBody.footerSpace
                color: Commons.Color.popups.background
                z: 1

                Rectangle {
                  anchors.top: parent.top
                  width: parent.width
                  height: Style.space(1)
                  color: Util.alpha(root.fg, 0.12)
                }
              }
              Row {
                id: editorActions
                visible: form.editIndex >= -1
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                spacing: Style.space(8)
                z: 2

                Button {
                  visible: root.closeConfirmation || form.confirmCancel
                  text: "Keep editing"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  onClicked: {
                    root.closeConfirmation = false
                    form.confirmCancel = false
                  }
                }
                Button {
                  visible: root.closeConfirmation || form.confirmCancel
                  text: root.closeConfirmation ? "Discard and close" : "Discard changes"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  onClicked: {
                    if (root.closeConfirmation) root.discardEditorAndClose()
                    else form.discardEdit()
                  }
                }
                Button {
                  visible: !root.closeConfirmation && !form.confirmCancel
                  text: root.editorDirty ? "Save changes" : "Save"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  enabled: form.validationState !== "error"
                  onClicked: {
                    editorError.text = ""
                    form.commitEdit()
                  }
                }
                Button {
                  visible: !root.closeConfirmation && !form.confirmCancel
                  text: "Cancel"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  onClicked: {
                    editorError.text = ""
                    form.requestCancelEdit()
                  }
                }
                Button {
                  visible: !root.closeConfirmation && !form.confirmCancel
                    && form.editIndex >= 0
                  text: form.confirmRemove ? "Confirm remove" : "Remove"
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFam
                  bordered: true
                  focusable: true
                  onClicked: {
                    editorError.text = ""
                    form.removeEdit()
                  }
                }
              }
            }
            }
          }
        }
      }
    }
  }
}
