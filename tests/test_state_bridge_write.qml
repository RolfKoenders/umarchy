import QtQuick
import Quickshell
import Quickshell.Io

// Regression test for a real bug found live while building StateBridge.qml
// (security review HANCORE-linux/omarchy-plugin-marketplace#2459, fourth
// round): bin/umami-state's write command reads a fixed-size-capped chunk
// of stdin (it can't use readline() — the JSON payload itself contains
// real newlines), and that read only returns once EITHER the cap is hit OR
// stdin reaches EOF. The first version of StateBridge.qml wrote the
// payload and left stdin open, so the helper sat blocked forever waiting
// for more input that was never coming — confirmed live: the write
// silently never completed, and `ps` showed the helper process still
// running minutes later. Toggling stdinEnabled back to false after
// writing is what actually closes this process's end of the pipe and
// delivers the EOF.
//
// Standalone harness (not StateBridge.qml loaded directly): StateBridge.qml
// has no way to point its spawned helper at a scratch $HOME, and running it
// against the real one from an automated test would overwrite this
// machine's real umarchy.json/umarchy-token.json. This replicates the
// exact same write()-then-toggle-stdinEnabled mechanism against a real
// bin/umami-state process with HOME overridden to an isolated scratch
// directory, matching the "standalone harness, real Quickshell engine"
// approach this project already uses for QML-only logic that can't be
// safely exercised through the real component (see git history for
// tests/test_state_dir_permissions.qml, which took the same approach for a
// different reason).
//
// Run with: quickshell -p tests/test_state_bridge_write.qml
// Exits 0 on success, 1 on failure, 2 on timeout (message on stderr).
Item {
  id: root

  readonly property string scratchHome: "/tmp/umarchy-statebridge-test-" + Date.now()
  readonly property string payload: JSON.stringify({ host: "https://example.com", note: "line1\nline2" }, null, 2) + "\n"

  function fail(msg) {
    console.error("FAIL: " + msg)
    Qt.exit(1)
  }

  function pass(msg) {
    console.log("PASS: " + msg)
  }

  Timer {
    interval: 8000
    running: true
    onTriggered: {
      console.error("FAIL: timed out -- the write helper is likely blocked waiting for EOF again")
      Qt.exit(2)
    }
  }

  Component.onCompleted: mkdirProc.running = true

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.scratchHome]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.fail("could not create the scratch HOME"); return }
      writeProc.running = true
    }
  }

  Process {
    id: writeProc
    command: ["python3", "bin/umami-state", "write", "umarchy.json"]
    environment: ({ "HOME": root.scratchHome, "PATH": Quickshell.env("PATH") })
    clearEnvironment: true
    stdinEnabled: true
    running: false
    property int capturedExitCode: -1
    property string errBuf: ""
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(value) { writeProc.errBuf += value }
    }
    onStarted: {
      writeProc.write(root.payload)
      // The fix under test: without this, bin/umami-state's stdin.read()
      // never sees EOF and this process never exits -- the Timer above is
      // what would eventually catch that as a timeout instead of a hang.
      writeProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      writeProc.capturedExitCode = exitCode
      if (exitCode !== 0) console.error("writeProc stderr: " + writeProc.errBuf)
    }
    onRunningChanged: {
      if (running) return
      if (writeProc.capturedExitCode !== 0) { root.fail("write exited " + writeProc.capturedExitCode); return }
      root.pass("write() completed after toggling stdinEnabled off (no hang)")
      readProc.running = true
    }
  }

  Process {
    id: readProc
    command: ["python3", "bin/umami-state", "read", "umarchy.json"]
    environment: ({ "HOME": root.scratchHome, "PATH": Quickshell.env("PATH") })
    clearEnvironment: true
    running: false
    property string buf: ""
    property int capturedExitCode: -1
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(value) { readProc.buf += value }
    }
    onExited: function(exitCode) {
      readProc.capturedExitCode = exitCode
    }
    onRunningChanged: {
      if (running) return
      if (readProc.capturedExitCode !== 0) { root.fail("read exited " + readProc.capturedExitCode); return }
      if (readProc.buf !== root.payload) { root.fail("round-tripped content did not match what was written"); return }
      root.pass("read() returned exactly what write() sent, multi-line content included")
      cleanupProc.running = true
    }
  }

  Process {
    id: cleanupProc
    command: ["rm", "-rf", root.scratchHome]
    running: false
    onExited: function(exitCode) {
      root.pass("all checks passed")
      Qt.exit(0)
    }
  }
}
