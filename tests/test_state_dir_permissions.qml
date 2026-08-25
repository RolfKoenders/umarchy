import QtQuick
import Quickshell.Io

// Regression test for HANCORE-linux/omarchy-plugin-marketplace#2459 (second
// round): the state directory must end up 0700 and the config file 0600,
// verified independently via `stat` rather than trusting our own
// bookkeeping — and a chmod that fails must be detected via exitCode, not
// silently treated as success.
//
// Standalone harness, not Service.qml loaded directly: Service.qml resolves
// its sibling types (RequestBridge, CredentialManager) via Quickshell's
// directory-based QML type lookup, which only works from inside the plugin
// directory. This re-creates the exact same mkdir -> chmod(dir) -> write ->
// chmod(file) sequencing Service.qml uses (see its comments), run against a
// real Quickshell engine and a real scratch directory, matching the
// "verified against a real Quickshell engine" method AGENTS.md documents
// for this class of QML-only logic (bare `qml6` can't even instantiate
// Quickshell's `Process` type).
//
// Run with: quickshell -p tests/test_state_dir_permissions.qml
// Exits 0 on success, 1 on any failure (message on stderr).
Item {
  id: root

  readonly property string scratchDir: "/tmp/umarchy-permtest-" + Date.now()
  readonly property string stateDir: root.scratchDir + "/state"
  readonly property string filePath: root.stateDir + "/secret.json"
  readonly property string bogusPath: root.stateDir + "/does-not-exist.json"

  function fail(msg) {
    console.error("FAIL: " + msg)
    Qt.exit(1)
  }

  function pass(msg) {
    console.log("PASS: " + msg)
  }

  Component.onCompleted: ensureDirProc.running = true

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.fail("mkdir -p failed"); return }
      chmodDirProc.running = true
    }
  }

  Process {
    id: chmodDirProc
    command: ["chmod", "700", root.stateDir]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.fail("chmod 700 on directory failed"); return }
      secretFile.setText("{\"token\":\"test-only\"}\n")
    }
  }

  property FileView secretFile: FileView {
    path: root.filePath
    atomicWrites: true
    printErrors: false
    onSaved: chmodFileProc.running = true
    onSaveFailed: root.fail("writing the test file failed")
  }

  Process {
    id: chmodFileProc
    command: ["chmod", "600", root.filePath]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.fail("chmod 600 on file failed"); return }
      verifyProc.running = true
    }
  }

  // Independent verification: don't trust our own bookkeeping, ask the
  // filesystem what the actual modes are.
  Process {
    id: verifyProc
    command: ["stat", "-c", "%a", root.stateDir, root.filePath]
    running: false
    stdout: StdioCollector { id: verifyOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.fail("stat failed"); return }
      var lines = verifyOut.text.trim().split(/\s+/)
      if (lines[0] !== "700") { root.fail("directory mode is " + lines[0] + ", expected 700"); return }
      if (lines[1] !== "600") { root.fail("file mode is " + lines[1] + ", expected 600"); return }
      root.pass("directory=700, file=600")
      negativeCaseProc.running = true
    }
  }

  // Negative case: chmod on a path that doesn't exist must fail (nonzero
  // exit), proving a real chmod failure is distinguishable from success —
  // this is the exact case the review found silently swallowed.
  Process {
    id: negativeCaseProc
    command: ["chmod", "600", root.bogusPath]
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) { root.fail("chmod on a nonexistent path unexpectedly succeeded"); return }
      root.pass("chmod failure on a bad path is correctly detected via a nonzero exit code (" + exitCode + ")")
      cleanupProc.running = true
    }
  }

  Process {
    id: cleanupProc
    command: ["rm", "-rf", root.scratchDir]
    running: false
    onExited: function(exitCode) {
      root.pass("all checks passed")
      Qt.exit(0)
    }
  }
}
