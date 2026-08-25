import QtQuick
import Quickshell.Io

// Wraps secret-tool for the Umami login password. Keyed by (application,
// host, username) rather than a single fixed schema, since the user can
// point this plugin at a different Umami instance or account later.
//
// Built with the capped-SplitParser pattern from the start (see
// HANCORE-linux/omarchy-plugin-marketplace#1750): the default newline
// splitMarker buffers an entire line internally before onRead ever fires
// once, which would let an oversized keyring value fully materialize before
// any length check runs. An empty splitMarker delivers whatever a single OS
// read returns instead, so the cap below is actually enforced incrementally.
QtObject {
  id: root

  readonly property string schema: "io.github.rolfkoenders.umarchy"
  // A real password is short; this rejects an absurdly large keyring value
  // outright rather than accepting it, independent of whatever wrote it.
  readonly property int maxSecretLength: 4096

  signal lookupFinished(string password)
  signal storeFinished(bool ok)
  signal clearFinished(bool ok)

  function attributesFor(host, username) {
    return ["application", root.schema, "host", String(host || ""), "username", String(username || "")]
  }

  function lookup(host, username) {
    lookupProcess.buf = ""
    lookupProcess.overflowed = false
    lookupProcess.command = ["secret-tool", "lookup"].concat(root.attributesFor(host, username))
    lookupProcess.running = true
  }

  function store(host, username, password) {
    storeProcess.pendingSecret = String(password || "")
    storeProcess.command = ["secret-tool", "store", "--label=Umarchy Umami login"]
      .concat(root.attributesFor(host, username))
    storeProcess.running = true
  }

  function clear(host, username) {
    clearProcess.command = ["secret-tool", "clear"].concat(root.attributesFor(host, username))
    clearProcess.running = true
  }

  property Process lookupProcess: Process {
    id: lookupProcess
    property string buf: ""
    property bool overflowed: false

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(value) {
        if (lookupProcess.overflowed) return
        var next = lookupProcess.buf + value
        if (next.length > root.maxSecretLength) {
          lookupProcess.overflowed = true
          if (lookupProcess.running) lookupProcess.signal(15) // SIGTERM
          return
        }
        lookupProcess.buf = next
      }
    }
    onRunningChanged: {
      if (running) return
      var value = lookupProcess.overflowed ? "" : lookupProcess.buf.replace(/\r?\n$/, "")
      root.lookupFinished(value)
    }
  }

  property Process storeProcess: Process {
    id: storeProcess
    property string pendingSecret: ""
    stdinEnabled: true
    onStarted: {
      storeProcess.write(storeProcess.pendingSecret)
      storeProcess.pendingSecret = ""
      storeProcess.stdinEnabled = false
    }
    // Process has no persistent exitCode property (confirmed against
    // Quickshell's own quickshell-io.qmltypes) — only this exited(exitCode,
    // exitStatus) signal carries it.
    onExited: function(exitCode, exitStatus) {
      root.storeFinished(exitCode === 0)
    }
  }

  property Process clearProcess: Process {
    id: clearProcess
    onExited: function(exitCode, exitStatus) {
      root.clearFinished(exitCode === 0)
    }
  }
}
