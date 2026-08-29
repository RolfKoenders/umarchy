import QtQuick
import Quickshell.Io

// Local on-disk state (config + cached session token) is created, read, and
// written entirely through bin/umami-state, never through Quickshell's own
// FileView-by-path or Process(mkdir/chmod)-by-path — both resolve a
// predictable path string directly, which follows any symlink planted at
// that path (security review HANCORE-linux/omarchy-plugin-marketplace#2459,
// fourth round). The helper instead walks the path with a no-follow,
// descriptor-relative open at every component; see its own docstring.
//
// Otherwise this is the same one-process-per-call, capped-accumulation
// shape as RequestBridge.qml. The cap here guards against the helper
// itself misbehaving rather than a remote attacker (there's no network
// involved), but that's exactly why the same defense-in-depth pattern is
// worth applying consistently — it costs nothing extra.
QtObject {
  id: root

  readonly property int maxStdoutBytes: 1024 * 1024
  readonly property int maxStderrBytes: 65536

  property Component _processComponent: Component {
    Process {
      id: proc
      property var callback: null
      property string writePayload: ""
      property bool shouldWrite: false
      property string stdoutBuf: ""
      property string stderrBuf: ""
      property bool overflowed: false
      // Process has no persistent exitCode property (confirmed against
      // Quickshell's own quickshell-io.qmltypes) — only the exited(exitCode,
      // exitStatus) signal carries it, and that can fire before stdout has
      // finished being delivered through the SplitParser below. Capturing
      // it here and consuming it from onRunningChanged (once Quickshell has
      // fully drained both pipes) avoids racing the two.
      property int capturedExitCode: -1

      stdinEnabled: proc.shouldWrite

      // running becomes true only once the OS process has actually started
      // (it's async), so writing stdin right after setting running = true
      // is a silent no-op — onStarted fires once it's actually ready.
      //
      // bin/umami-state's write command reads a fixed-size-capped chunk of
      // stdin (not a single line, since the JSON payload itself contains
      // real newlines) — that read only returns once EITHER the cap is hit
      // OR stdin reaches EOF. Toggling stdinEnabled back to false closes
      // this process's end of the pipe, which is what actually delivers
      // that EOF; skipping this step leaves the helper blocked in that
      // read forever; confirmed live (a write silently never completed,
      // and the helper process was still sitting there minutes later).
      onStarted: {
        if (proc.shouldWrite) {
          proc.write(proc.writePayload)
          proc.stdinEnabled = false
        }
      }

      stdout: SplitParser {
        // Empty splitMarker delivers whatever a single OS read returns,
        // instead of the default "\n" behavior of buffering an entire line
        // internally before onRead ever fires once.
        splitMarker: ""
        onRead: function(value) {
          if (proc.overflowed) return
          var next = proc.stdoutBuf + value
          if (next.length > root.maxStdoutBytes) {
            proc.overflowed = true
            proc.stdoutBuf = next.substring(0, root.maxStdoutBytes)
            if (proc.running) proc.signal(15) // SIGTERM
            return
          }
          proc.stdoutBuf = next
        }
      }
      stderr: SplitParser {
        splitMarker: ""
        onRead: function(value) {
          if (proc.overflowed) return
          var next = proc.stderrBuf + value
          if (next.length > root.maxStderrBytes) {
            proc.overflowed = true
            proc.stderrBuf = next.substring(0, root.maxStderrBytes)
            if (proc.running) proc.signal(15) // SIGTERM
            return
          }
          proc.stderrBuf = next
        }
      }

      onExited: function(exitCode, exitStatus) {
        proc.capturedExitCode = exitCode
      }

      onRunningChanged: {
        if (running) return
        var cb = proc.callback
        var stdoutBuf = proc.stdoutBuf
        var stderrBuf = proc.stderrBuf
        var exitCode = proc.overflowed ? 2 : proc.capturedExitCode
        proc.destroy()
        if (!cb) return
        cb(exitCode, stdoutBuf, stderrBuf.trim())
      }
    }
  }

  function _scriptPath() {
    var scriptPath = String(Qt.resolvedUrl("bin/umami-state"))
    if (scriptPath.startsWith("file://")) scriptPath = scriptPath.substring(7)
    return scriptPath
  }

  function _run(args, content, callback) {
    try {
      var proc = root._processComponent.createObject(root, {
        callback: callback,
        command: ["python3", root._scriptPath()].concat(args),
        shouldWrite: content !== null,
        writePayload: content || ""
      })
      proc.running = true
    } catch (e) {
      callback(4, "", "Could not start state helper: " + e)
    }
  }

  // callback(exitCode, stdout, stderr) — exitCode follows bin/umami-state's
  // own contract: 0 success, 2 too large, 3 security violation, 4 other
  // failure, and (read only) 5 meaning the file doesn't exist yet.
  function ensureDir(callback) {
    root._run(["ensure-dir"], null, callback)
  }

  function read(name, callback) {
    root._run(["read", name], null, callback)
  }

  function write(name, content, callback) {
    root._run(["write", name], content, callback)
  }
}
