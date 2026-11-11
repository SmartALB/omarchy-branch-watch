"""Runtime-load the QML on Wayland; skip only on headless test hosts."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

if not os.environ.get("WAYLAND_DISPLAY"):
    print("QML smoke: SKIP (no Wayland display)")
    raise SystemExit(0)

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="branch-watch-qml-") as temp:
    box = Path(temp)
    for module in ("Commons", "Ui", "services"):
        (box / module).symlink_to(Path("/usr/share/omarchy/shell") / module,
                                 target_is_directory=True)
    config_dir = box / "config" / "omarchy"
    state_dir = box / "state"
    runtime = box / "runtime"
    home = box / "home"
    for directory in (config_dir, state_dir, runtime, home):
        directory.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    (config_dir / "branch-watch.json").write_text(json.dumps({
        "schemaVersion": 1, "intervalMinutes": 10, "notifications": False,
        "repositories": [{
            "id": "missing", "name": "Missing Repo", "label": "MISS",
            "path": str(box / "absent"), "remote": "origin",
            "branches": [{"name": "master", "label": "M"}],
        }],
    }))
    (box / "shell.qml").write_text('''
import QtQuick
import Quickshell
import "''' + ROOT.as_uri() + '''" as Plugin
ShellRoot {
  QtObject {
    id: horizontalBar
    property bool vertical: false
    property int barSize: 32
    property color barForeground: "white"
    property color urgent: "orange"
    property bool foregroundAnimationEnabled: true
    property string fontFamily: "sans"
    property string position: "top"
    property string activePopout: ""
    function hideTooltip(target) {}
  }
  QtObject {
    id: verticalBar
    property bool vertical: true
    property int barSize: 32
    property color barForeground: "white"
    property color urgent: "orange"
    property bool foregroundAnimationEnabled: true
    property string fontFamily: "sans"
    property string position: "left"
    property string activePopout: ""
    function hideTooltip(target) {}
  }
  Plugin.Panel { id: horizontal; bar: horizontalBar; manageIpc: false }
  Plugin.Panel { id: vertical; bar: verticalBar; manageIpc: false }
  Timer {
    interval: 100; running: true; repeat: true
    property int settled: 0
    onTriggered: {
      if (horizontal.rows.length !== 1 || vertical.rows.length !== 1) return
      if (horizontal.rows[0].branch !== "master" || horizontal.rows[0].state !== "error") {
        console.log("BRANCH_WATCH_QML_FAIL dynamic row"); Qt.quit(); return
      }
      if (horizontal.implicitWidth <= horizontalBar.barSize || horizontal.implicitHeight !== horizontalBar.barSize
          || vertical.implicitWidth !== verticalBar.barSize || vertical.implicitHeight <= verticalBar.barSize) {
        settled++
        if (settled < 10) return
      }
      if (horizontal.implicitWidth <= horizontalBar.barSize || horizontal.implicitHeight !== horizontalBar.barSize) {
        console.log("BRANCH_WATCH_QML_FAIL horizontal geometry " + horizontal.implicitWidth + "x" + horizontal.implicitHeight); Qt.quit(); return
      }
      if (vertical.implicitWidth !== verticalBar.barSize || vertical.implicitHeight <= verticalBar.barSize) {
        console.log("BRANCH_WATCH_QML_FAIL vertical geometry " + vertical.implicitWidth + "x" + vertical.implicitHeight
          + " vertical=" + vertical.vertical + " groups=" + vertical.groups().length
          + " branches=" + vertical.groups()[0].branches.length); Qt.quit(); return
      }
      if (horizontal.tooltip(horizontal.rows[0]).indexOf("Missing Repo · master") !== 0) {
        console.log("BRANCH_WATCH_QML_FAIL tooltip"); Qt.quit(); return
      }
      var normalized = horizontal.normalizeConfig({repositories: [null, "bad", {name: "Valid", branches: "master"}]})
      if (normalized.repositories.length !== 1 || normalized.repositories[0].branches.length !== 0) {
        console.log("BRANCH_WATCH_QML_FAIL config normalization"); Qt.quit(); return
      }
      horizontal.probeError = "Branch Watch timed out"
      var stale = horizontal.tooltip(horizontal.rows[0])
      if (stale.indexOf("Last known status:") === -1 || stale.indexOf("Data may be stale") === -1) {
        console.log("BRANCH_WATCH_QML_FAIL stale tooltip"); Qt.quit(); return
      }
      console.log("BRANCH_WATCH_QML_OK horizontal=" + horizontal.implicitWidth + "x" + horizontal.implicitHeight
        + " vertical=" + vertical.implicitWidth + "x" + vertical.implicitHeight)
      Qt.quit()
    }
  }
  Timer { interval: 8000; running: true; onTriggered: { console.log("BRANCH_WATCH_QML_FAIL timeout"); Qt.quit() } }
}
''')
    env = os.environ.copy()
    env.update({
        "PATH": "/usr/bin:/bin", "HOME": str(home), "LC_ALL": "C.UTF-8",
        "XDG_CONFIG_HOME": str(box / "config"), "XDG_STATE_HOME": str(state_dir),
        "XDG_CACHE_HOME": str(box / "cache"), "XDG_RUNTIME_DIR": os.environ["XDG_RUNTIME_DIR"],
        "GIT_ALLOW_PROTOCOL": "file", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null", "BRANCH_WATCH_NOTIFY_SEND": "/usr/bin/true",
    })
    process = subprocess.run(
        ["quickshell", "--no-color", "--path", str(box / "shell.qml")],
        env=env, text=True, capture_output=True, timeout=12,
    )
    output = process.stdout + process.stderr
    print(output)
    bad = ("BRANCH_WATCH_QML_OK" not in output or "BRANCH_WATCH_QML_FAIL" in output
           or "TypeError" in output or "ReferenceError" in output
           or "Failed to load configuration" in output)
    if bad:
        raise SystemExit("QML smoke test failed")
