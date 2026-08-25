import QtQuick
import Quickshell.Io

// One Umami API call per short-lived bin/umami-api process. Adapted
// directly from Keeply's ApiBridge.qml (HANCORE-linux/omarchy-plugin-
// marketplace#1750), which went through several security-review rounds to
// land on this shape: QML's own XMLHttpRequest can't bound a response
// itself (Qt materializes every received byte into responseText as it
// streams in, before any JS callback can inspect or abort it), so the
// actual network read happens in bin/umami-api, which enforces its own
// byte + wall-clock cap during the socket read. This bridge only ever
// receives already-bounded output — and re-caps it again anyway on the way
// in, as defense in depth against the helper process itself misbehaving.
QtObject {
  id: root

  // Matches the cap bin/umami-api enforces on its own socket read. This
  // isn't the real bound (that already happened before any of this data
  // existed on the helper's stdout) — it guards against the helper itself
  // producing something unexpected.
  readonly property int maxStdoutBytes: 5 * 1024 * 1024
  readonly property int maxStderrBytes: 65536

  property Component _processComponent: Component {
    Process {
      id: proc
      property var callback: null
      property string requestPayload: ""
      property string stdoutBuf: ""
      property string stderrBuf: ""
      property bool overflowed: false

      stdinEnabled: true

      // running becomes true only once the OS process has actually
      // started (it's async — setting the running property doesn't take
      // effect synchronously), so writing stdin right after setting
      // running = true is a silent no-op and the helper hangs forever on
      // an empty stdin read. onStarted fires once it's actually ready.
      onStarted: proc.write(proc.requestPayload)

      stdout: SplitParser {
        // Empty splitMarker delivers whatever a single OS read returns,
        // instead of the default "\n" behavior of buffering an entire
        // line internally before onRead ever fires once. The cap below
        // already bounds across multiple reads regardless; this only
        // changes how early each chunk is checked.
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

      onRunningChanged: {
        if (running) return
        var cb = proc.callback
        var stdoutBuf = proc.stdoutBuf
        var stderrBuf = proc.stderrBuf
        var overflowed = proc.overflowed
        proc.destroy()
        if (!cb) return

        if (overflowed) {
          cb(null, "too_large", "Response too large")
        } else if (stdoutBuf.trim().length > 0) {
          try {
            cb(JSON.parse(stdoutBuf.trim()), null, null)
          } catch (e) {
            cb(null, "invalid_response", "Invalid response from server")
          }
        } else if (stderrBuf.trim().length > 0) {
          var err = stderrBuf.trim()
          if (err.indexOf("http_status:") === 0) {
            var statusCode = err.substring("http_status:".length)
            cb(null, "http_status:" + statusCode, "Request failed (" + statusCode + ")")
          } else {
            cb(null, "other", err)
          }
        } else {
          cb(null, "other", "API helper exited unexpectedly")
        }
      }
    }
  }

  // callback(parsedBody, errorCode, errorMessage) — errorCode is one of
  // null (success), "too_large", "invalid_response", "http_status:<n>", or
  // "other". Service.qml's retry-on-401 logic keys off errorCode ===
  // "http_status:401" specifically.
  function request(method, host, path, token, body, callback) {
    try {
      var scriptPath = String(Qt.resolvedUrl("bin/umami-api"))
      if (scriptPath.startsWith("file://")) scriptPath = scriptPath.substring(7)

      var payload = JSON.stringify({
        method: method, host: host, path: path,
        token: token || null, body: body || null
      }) + "\n"

      var proc = root._processComponent.createObject(root, {
        callback: callback,
        command: ["python3", scriptPath],
        requestPayload: payload
      })
      proc.running = true
    } catch (e) {
      callback(null, "other", "Could not start API helper: " + e)
    }
  }
}
