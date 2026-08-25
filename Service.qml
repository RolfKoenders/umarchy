import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Session state: config, login/401-retry, site + period selection, stats,
// refresh timer. Owns its own private state file rather than the generic
// per-widget settings schema, matching omarchy-matomo/Service.qml — this
// plugin's config (host/username/siteId/period/icon) has nothing to do
// with the bar layout system, and the password never belongs in it at all.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  // A dedicated, guaranteed-0700 directory rather than the shared
  // .../settings/ directory other plugins also write into (security review
  // HANCORE-linux/omarchy-plugin-marketplace#2459, second round): sequencing
  // chmod off onSaved closed the ordering race, but the file still exists at
  // its default creation mode for the moment between creation and chmod,
  // and mkdir -p alone never restricts an already-existing shared directory.
  // A 0700 directory makes the file's own mode moot for cross-user exposure
  // — nothing else can even traverse in to open it by path — which is the
  // fix the review named as sufficient on its own ("or place it in a
  // guaranteed mode-0700 directory"), without needing to solve atomic
  // file creation with a non-default initial mode.
  readonly property string stateDir: home + "/.local/state/omarchy/settings/io.github.rolfkoenders.umarchy"
  readonly property string configPath: stateDir + "/umarchy.json"
  readonly property string tokenPath: stateDir + "/umarchy-token.json"

  property var config: Model.emptyConfig()
  property string token: ""
  property string _cachedPassword: ""
  property bool hasStoredPassword: false

  property var sites: []
  property var summary: ({ pageviews: 0, visitors: 0, visits: 0, bounces: 0, totaltime: 0 })
  property var series: []
  property var topPages: []
  property var topReferrers: []
  property var topCountries: []
  property int activeVisitors: 0

  property bool loading: false
  property bool loadingSites: false
  property bool checking: false
  property bool connected: false
  property bool secretRequired: false
  property string lastError: ""
  property int _pendingCalls: 0

  property bool _reauthInFlight: false
  property var _reauthQueue: []

  property bool _writingConfig: false
  property bool _writingToken: false

  readonly property bool ready: Model.hasConnectionTarget(config)
  readonly property var activeSiteObj: Model.activeSite(sites, config.siteId)
  readonly property string siteLabel: activeSiteObj ? activeSiteObj.name : ""
  readonly property var chartValues: Model.seriesValues(series)
  readonly property var chartLabels: Model.seriesLabels(series)
  readonly property string bounceRateLabel: Model.formatBounceRate(summary.bounces, summary.visits)
  readonly property string avgTimeLabel: Model.formatAvgTime(summary.totaltime, summary.visits)
  readonly property string barIcon: config.icon || "📈"
  readonly property string barLabel: (!ready || !config.showLiveCount) ? barIcon
    : barIcon + " " + Model.formatCount(activeVisitors)
  readonly property string barTooltip: !ready
    ? "Umarchy — add your Umami instance and view-only login"
    : (siteLabel + " · " + Model.formatCount(activeVisitors) + " live · "
       + Model.formatCount(summary.pageviews) + " pageviews")

  function refresh() {
    if (!root.ready) return
    root.loading = true
    root.lastError = ""
    if (root.sites.length === 0) {
      root.fetchSites(function() { root.fetchStatsBundle() })
    } else {
      root.fetchStatsBundle()
    }
  }

  function fetchSites(then) {
    root.loadingSites = true
    // /api/websites paginates (default pageSize 10); 100 comfortably covers
    // a personal/self-hosted account without needing real pagination.
    root.authorizedRequest("GET", "/api/websites?pageSize=100", null, function(result, errorMessage) {
      root.loadingSites = false
      if (errorMessage) {
        root.failLoad(errorMessage)
        return
      }
      root.sites = Model.parseSites(result)
      if (!root.config.siteId && root.sites.length) {
        root.setSiteId(root.sites[0].id, false)
      }
      then()
    })
  }

  function fetchStatsBundle() {
    if (!root.activeSiteObj) {
      root.loading = false
      root.lastError = "No sites available for this account"
      return
    }
    var siteId = root.activeSiteObj.id
    var range = Model.periodRange(root.config.period, new Date())
    var qs = "?startAt=" + range.startAt + "&endAt=" + range.endAt
    var base = "/api/websites/" + encodeURIComponent(siteId)

    root._pendingCalls = 6
    var anyError = ""

    function done(errorMessage) {
      if (errorMessage && !anyError) anyError = errorMessage
      root._pendingCalls -= 1
      if (root._pendingCalls <= 0) {
        root.loading = false
        root.lastError = anyError
      }
    }

    root.authorizedRequest("GET", base + "/active", null, function(result, err) {
      if (!err) root.activeVisitors = Model.parseActiveVisitors(result)
      done(err)
    })
    root.authorizedRequest("GET", base + "/stats" + qs, null, function(result, err) {
      if (!err) root.summary = Model.parseStats(result)
      done(err)
    })
    root.authorizedRequest("GET", base + "/pageviews" + qs + "&unit=" + range.unit, null, function(result, err) {
      if (!err) root.series = Model.parsePageviewSeries(result)
      done(err)
    })
    root.authorizedRequest("GET", base + "/metrics" + qs + "&type=path", null, function(result, err) {
      if (!err) root.topPages = Model.parseMetricRows(result)
      done(err)
    })
    root.authorizedRequest("GET", base + "/metrics" + qs + "&type=referrer", null, function(result, err) {
      if (!err) root.topReferrers = Model.parseMetricRows(result)
      done(err)
    })
    root.authorizedRequest("GET", base + "/metrics" + qs + "&type=country", null, function(result, err) {
      if (!err) root.topCountries = Model.parseMetricRows(result)
      done(err)
    })
  }

  function failLoad(message) {
    root.loading = false
    root.lastError = message
    root.connected = false
  }

  // Every authenticated call goes through here so the 401-retry policy
  // (Model.nextAuthState) is applied uniformly. callback(result,
  // errorMessage) — errorMessage is null on success.
  function authorizedRequest(method, path, body, callback, isRetry) {
    requestBridge.request(method, root.config.host, path, root.token, body,
      function(result, errorCode, errorMessage) {
        var state = Model.nextAuthState(errorCode, root.hasStoredPassword, !!isRetry)
        if (state === "ok") {
          root.connected = true
          root.secretRequired = false
          callback(result, null)
        } else if (state === "retry") {
          root.reauthenticateAndRetry(method, path, body, callback)
        } else if (state === "prompt") {
          root.secretRequired = true
          callback(null, "Enter your Umami password")
        } else {
          callback(null, Model.errorMessageFor(errorCode, errorMessage))
        }
      })
  }

  // Coalesces concurrent 401s (a whole refresh bundle can hit a stale
  // token at once) into a single login call, replaying every queued
  // request against the outcome instead of firing one login per request.
  function reauthenticateAndRetry(method, path, body, callback) {
    root._reauthQueue.push({ method: method, path: path, body: body, callback: callback })
    if (root._reauthInFlight) return
    root._reauthInFlight = true
    root.login(root._cachedPassword, function(ok) {
      root._reauthInFlight = false
      var queued = root._reauthQueue
      root._reauthQueue = []
      for (var i = 0; i < queued.length; i++) {
        var item = queued[i]
        if (ok) {
          root.authorizedRequest(item.method, item.path, item.body, item.callback, true)
        } else {
          root.secretRequired = true
          item.callback(null, "Umami rejected the saved password")
        }
      }
    })
  }

  // done(ok) — ok is false on invalid credentials or an unreachable host.
  function login(password, done) {
    root.checking = true
    requestBridge.request("POST", root.config.host, "/api/auth/login", null,
      { username: root.config.username, password: password },
      function(result, errorCode, errorMessage) {
        root.checking = false
        var loginToken = result && typeof result === "object" ? String(result.token || "") : ""
        if (errorCode || !loginToken) {
          root.connected = false
          if (done) done(false)
          return
        }
        root.token = loginToken
        root._cachedPassword = password
        root.hasStoredPassword = true
        root.connected = true
        root.secretRequired = false
        root.lastError = ""
        root.persistToken()
        if (done) done(true)
      })
  }

  function saveConnection(host, username, password) {
    var normalizedHost = Model.normalizeHost(host)
    if (!normalizedHost) {
      root.lastError = "Enter a valid https:// Umami URL"
      return
    }
    var trimmedUsername = String(username || "").trim()
    if (!trimmedUsername) {
      root.lastError = "Enter your view-only username"
      return
    }
    var accountChanged = normalizedHost !== root.config.host || trimmedUsername !== root.config.username
    root.persist({
      host: normalizedHost,
      username: trimmedUsername,
      siteId: accountChanged ? "" : root.config.siteId
    })
    if (accountChanged) {
      root.sites = []
      root.token = ""
      root._cachedPassword = ""
      root.hasStoredPassword = false
    }
    if (!password) {
      if (accountChanged) {
        root.lastError = "Enter your view-only password"
        return
      }
      root.refresh()
      return
    }
    root.login(password, function(ok) {
      if (ok) {
        credentialManager.store(normalizedHost, trimmedUsername, password)
        root.refresh()
      } else {
        root.lastError = "Incorrect username or password"
      }
    })
  }

  function setSiteId(id, thenRefresh) {
    if (id === root.config.siteId) return
    root.persist({ siteId: id })
    root.summary = { pageviews: 0, visitors: 0, visits: 0, bounces: 0, totaltime: 0 }
    root.series = []
    root.topPages = []
    root.topReferrers = []
    root.topCountries = []
    if (thenRefresh !== false) root.fetchStatsBundle()
  }

  function setPeriod(value) {
    if (Model.periodOrDefault(value) === root.config.period) return
    root.persist({ period: value })
    root.fetchStatsBundle()
  }

  function setShowLiveCount(enabled) {
    root.persist({ showLiveCount: enabled !== false })
  }

  // chmod is sequenced off FileView's own "saved" signal in configFile/
  // tokenFile below, not fired here — see the comment there for why.
  // The state directory itself is only ensured once, at startup
  // (Component.onCompleted): by the time any persist() can run, a real
  // user interaction has already happened, which is ample time for a
  // plain `mkdir -p` to have completed.
  function persist(values) {
    root.config = Model.patchConfig(root.config, values)
    root._writingConfig = true
    configFile.setText(Model.serializeConfig(root.config))
  }

  function persistToken() {
    root._writingToken = true
    tokenFile.setText(JSON.stringify({
      token: root.token, host: root.config.host, username: root.config.username
    }, null, 2) + "\n")
  }

  RequestBridge { id: requestBridge }
  CredentialManager { id: credentialManager }

  Connections {
    target: credentialManager
    function onLookupFinished(password) {
      root._cachedPassword = password
      root.hasStoredPassword = password !== ""
      // Only ever reached via configFile.onLoaded below, right after
      // startup or a config reload — chaining the token-cache read (which
      // ends in refresh()) from here, rather than firing both in parallel,
      // guarantees hasStoredPassword is already correct before the first
      // request can possibly hit a 401 and need it.
      tokenFile.reload()
    }
  }

  // mkdir, then chmod 700 the directory, then (only then) load the config —
  // the directory is guaranteed private before anything is ever written
  // into or read from it, every time the plugin starts, whether the
  // directory is brand new or already existed from an earlier version.
  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.lastError = "Could not create the settings directory"; return }
      chmodDirProc.running = true
    }
  }
  Process {
    id: chmodDirProc
    command: ["chmod", "700", root.stateDir]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "Could not secure the settings directory"
      configFile.reload()
    }
  }

  // Only _writingConfig/_writingToken's clearing is sequenced off these
  // (onExited), not their start — chmod itself is only ever started from
  // configFile/tokenFile's onSaved below, once the write it's protecting
  // has actually finished. exitCode is checked (review finding: both
  // handlers used to clear the write guard unconditionally, silently
  // treating a failed chmod the same as a successful one) — a failure is
  // surfaced as lastError rather than swallowed, matching how a failed
  // save (onSaveFailed) is already treated.
  Process {
    id: chmodConfigProc
    command: ["chmod", "600", root.configPath]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "Could not secure the settings file"
      root._writingConfig = false
    }
  }
  Process {
    id: chmodTokenProc
    command: ["chmod", "600", root.tokenPath]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "Could not secure the session token file"
      root._writingToken = false
    }
  }

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    // Security review finding (HANCORE-linux/omarchy-plugin-marketplace#2459):
    // mkdir, setText(), and chmod used to fire in the same tick with no
    // ordering guarantee, so the credential-bearing file could briefly (or
    // permanently, if chmod lost the race or failed) sit at its default
    // creation mode. Fixed by only ever starting chmod from onSaved, once
    // the write it's protecting has actually finished — confirmed against
    // Quickshell's own qmltypes that FileView has real saved/saveFailed
    // signals for exactly this.
    //
    // _writingConfig now stays true for the whole write+chmod window, not
    // just the write: onFileChanged ignores every change while it's set
    // (both the write and the chmod touch the watched file), and it's only
    // cleared once chmod's own onExited fires (see the Process below) — or
    // immediately, on onSaveFailed, since there's then nothing to chmod.
    // Clearing it any earlier (e.g. back in onLoaded, as before) left a
    // narrow window where chmod's own metadata touch could trigger a second,
    // unguarded reload.
    onFileChanged: {
      if (root._writingConfig) return
      reload()
    }
    onSaved: chmodConfigProc.running = true
    onSaveFailed: root._writingConfig = false
    onLoaded: {
      if (root._writingConfig) return
      root.config = Model.parseConfig(text())
      if (root.ready) {
        credentialManager.lookup(root.config.host, root.config.username)
      }
    }
    onLoadFailed: {
      root.config = Model.emptyConfig()
    }
  }

  // Loaded only once config is known to be ready, so this never races
  // config.host/username. Reads whatever cached token exists (there may be
  // none yet, or one for a different account — either way this always
  // finishes by calling refresh(), which is the one thing that must happen
  // exactly once after startup).
  property FileView tokenFile: FileView {
    path: root.tokenPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    // Same fix as configFile above: chmod only starts from onSaved, once
    // the write has actually finished, not fired unsequenced alongside it.
    // No onFileChanged race to worry about here (watchChanges is false),
    // so _writingToken only needs to survive until chmod's onExited.
    onSaved: chmodTokenProc.running = true
    onSaveFailed: root._writingToken = false
    onLoaded: {
      if (root._writingToken) return
      try {
        var data = JSON.parse(text() || "{}")
        if (data && data.host === root.config.host && data.username === root.config.username && data.token) {
          root.token = String(data.token)
        }
      } catch (e) {
        // no usable cached token — fine, an authorizedRequest 401 will
        // trigger a fresh login as long as the password is in the keyring
      }
      root.refresh()
    }
    onLoadFailed: root.refresh()
  }

  Timer {
    interval: 60000
    running: root.ready
    repeat: true
    onTriggered: if (root._pendingCalls === 0) root.refresh()
  }

  // configFile.reload() now happens at the end of the mkdir -> chmod 700
  // chain above (chmodDirProc.onExited), not here directly — the directory
  // must be confirmed private before any file inside it is ever read.
  Component.onCompleted: {
    ensureDirProc.running = true
  }
}
