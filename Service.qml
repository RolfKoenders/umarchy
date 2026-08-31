import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Session state: config, login/401-retry, site + period selection, stats,
// refresh timer. Owns its own private state file rather than the generic
// per-widget settings schema, matching omarchy-matomo/Service.qml — this
// plugin's config (host/username/siteId/period/icon) has nothing to do
// with the bar layout system, and the password never belongs in it at all.
Item {
  id: root

  // The state directory/files are never addressed by a predictable path
  // string from here — see StateBridge.qml and bin/umami-state for why
  // (security review HANCORE-linux/omarchy-plugin-marketplace#2459, fourth
  // round: mkdir -p and chmod-by-path both follow a symlink planted at that
  // path, and FileView-by-path has no defense against a swapped-in FIFO or
  // oversized file). Service.qml only ever deals with plain file *names*
  // ("umarchy.json", "umarchy-token.json"); the helper resolves them
  // relative to a directory it walked and verified itself.

  property var config: Model.emptyConfig()
  property string token: ""
  property string timezone: ""
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

  // Fail-closed gate for the whole state directory (security review
  // HANCORE-linux/omarchy-plugin-marketplace#2459, third and fourth
  // rounds): once true, persist()/persistToken() refuse to write and
  // loadConfig()/loadToken() refuse to use whatever they read. Set the
  // moment bin/umami-state reports anything other than success or "not
  // found yet" (its exit code 5) for any operation — a permission failure,
  // an oversized file, or a security violation like a symlink or wrong file
  // type — since none of those leave the credential-bearing state in a
  // shape that's safe to keep using. There is no path that clears it
  // again; recovering means fixing the underlying problem and restarting
  // the plugin.
  property bool stateBlocked: false

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

  // Two phases: phase 1 fetches owned sites and the member's team ids in
  // parallel; phase 2 (only if any teams were found) fans out one call per
  // team, since it depends on phase 1's team-id list. Owned sites are the
  // one thing that must succeed — losing that would be a regression, not a
  // degradation. Team discovery is best-effort throughout (an old
  // self-hosted Umami with no Teams API, or any single team's fetch
  // failing, just means that part of the result stays empty) — same
  // "silently degrade, don't fail the whole thing" precedent as
  // timezoneProc below.
  function fetchSites(then) {
    root.loadingSites = true

    var ownedSites = []
    var teamIds = []
    var hardError = ""
    var phaseOnePending = 2

    function phaseOneDone() {
      phaseOnePending -= 1
      if (phaseOnePending > 0) return
      if (hardError) { finish([]); return }
      startPhaseTwo()
    }

    // /api/websites paginates (default pageSize 10); 100 comfortably covers
    // a personal/self-hosted account without needing real pagination.
    root.authorizedRequest("GET", "/api/websites?pageSize=100", null, function(result, errorMessage) {
      if (errorMessage) { hardError = errorMessage } else { ownedSites = Model.parseSites(result) }
      phaseOneDone()
    })

    root.authorizedRequest("GET", "/api/me/teams?pageSize=100", null, function(result, errorMessage) {
      if (!errorMessage) teamIds = Model.parseTeamIds(result)
      phaseOneDone()
    })

    function startPhaseTwo() {
      if (teamIds.length === 0) { finish([]); return }
      var teamSites = []
      var phaseTwoPending = teamIds.length
      for (var i = 0; i < teamIds.length; i++) {
        var path = "/api/teams/" + encodeURIComponent(teamIds[i]) + "/websites?pageSize=100"
        root.authorizedRequest("GET", path, null, function(result, errorMessage) {
          if (!errorMessage) teamSites = teamSites.concat(Model.parseSites(result))
          phaseTwoPending -= 1
          if (phaseTwoPending <= 0) finish(teamSites)
        })
      }
    }

    function finish(teamSites) {
      root.loadingSites = false
      if (hardError) {
        root.failLoad(hardError)
        return
      }
      // root.sites is never cleared before this point — whatever was there
      // from a prior successful fetch stays on screen until this
      // assignment, which is what makes rescanSites() below flicker-free.
      root.sites = Model.mergeSites(ownedSites, teamSites)
      if (!root.config.siteId && root.sites.length) {
        root.setSiteId(root.sites[0].id, false)
      }
      then()
    }
  }

  // The explicit-refresh path: unlike refresh() (used by the passive timer,
  // panel-open, and the external IPC command — see Panel.qml), this always
  // re-runs full site/team discovery, not just the stats bundle for
  // whatever sites are already known — otherwise joining a new team, or
  // gaining a new owned site, while the widget is already running would
  // require a restart to show up. Guarded once, here, rather than at each
  // Panel.qml call site: a stray double-trigger from middle-click or the r
  // key (neither of which checks stats.loading the way the Refresh
  // button's `enabled` binding does) becomes a no-op instead of two
  // overlapping ~22-subprocess fetches.
  function rescanSites() {
    if (!root.ready || root.loading) return
    root.loading = true
    root.lastError = ""
    root.fetchSites(function() { root.fetchStatsBundle() })
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
    var pageviewsQs = qs + "&unit=" + range.unit
    // Umami buckets "day" units at UTC midnight unless told otherwise, which
    // almost never matches the visitor's own calendar day. Passing the
    // local IANA zone (looked up once via timedatectl, see timezoneProc)
    // makes the bucket boundaries match the date labels Model.js prints for
    // them. If the lookup hasn't resolved yet (or failed), the request
    // simply omits it — Umami's own UTC default, no worse than before.
    if (root.timezone) pageviewsQs += "&timezone=" + encodeURIComponent(root.timezone)
    root.authorizedRequest("GET", base + "/pageviews" + pageviewsQs, null, function(result, err) {
      if (!err) root.series = Model.parsePageviewSeries(result, range.unit)
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

  // Every write goes through bin/umami-state, which re-walks and
  // re-verifies the state directory on every single call rather than
  // trusting that a path checked out earlier still means the same thing
  // now — there is no long-lived "directory handle" here to reuse or race.
  function persist(values) {
    if (root.stateBlocked) return
    root.config = Model.patchConfig(root.config, values)
    stateBridge.write("umarchy.json", Model.serializeConfig(root.config), function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = "Could not securely save the settings file"
        root.stateBlocked = true
      }
    })
  }

  function persistToken() {
    if (root.stateBlocked) return
    var payload = JSON.stringify({
      token: root.token, host: root.config.host, username: root.config.username
    }, null, 2) + "\n"
    stateBridge.write("umarchy-token.json", payload, function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = "Could not securely save the session token file"
        root.stateBlocked = true
      }
    })
  }

  // exitCode 0: parsed normally. 5: no file yet, a normal first run —
  // config resets to empty, nothing else it touches on disk is trusted
  // less because of that. Anything else (permission failure, oversized
  // file, symlink/wrong-type/wrong-owner) is fail-closed: stop here rather
  // than go on using content that failed a safety check.
  function loadConfig() {
    stateBridge.read("umarchy.json", function(exitCode, stdout) {
      if (exitCode === 0) {
        root.config = Model.parseConfig(stdout)
      } else if (exitCode === 5) {
        root.config = Model.emptyConfig()
      } else {
        root.lastError = "Could not read the settings file"
        root.stateBlocked = true
        return
      }
      if (root.ready) {
        credentialManager.lookup(root.config.host, root.config.username)
      }
    })
  }

  // Only ever reached via credentialManager.onLookupFinished below, right
  // after startup (or a fresh saveConnection()) — this always finishes by
  // calling refresh(), which is the one thing that must happen exactly
  // once after startup.
  function loadToken() {
    stateBridge.read("umarchy-token.json", function(exitCode, stdout) {
      if (exitCode === 0) {
        try {
          var data = JSON.parse(stdout)
          if (data && data.host === root.config.host && data.username === root.config.username && data.token) {
            root.token = String(data.token)
          }
        } catch (e) {
          // corrupt JSON, not a security violation -- an authorizedRequest
          // 401 will trigger a fresh login as long as the password is in
          // the keyring
        }
      } else if (exitCode !== 5) {
        root.lastError = "Could not read the session token file"
        root.stateBlocked = true
        return
      }
      root.refresh()
    })
  }

  RequestBridge { id: requestBridge }
  CredentialManager { id: credentialManager }
  StateBridge { id: stateBridge }

  Connections {
    target: credentialManager
    function onLookupFinished(password) {
      root._cachedPassword = password
      root.hasStoredPassword = password !== ""
      // Chaining the token-cache read (which ends in refresh()) from here,
      // rather than firing both in parallel, guarantees hasStoredPassword
      // is already correct before the first request can possibly hit a
      // 401 and need it.
      root.loadToken()
    }
  }

  // Best-effort local timezone lookup, independent of the state-dir chain
  // above (nothing it does depends on the config file). A failed or missing
  // timedatectl just leaves root.timezone "" and the pageviews request omits
  // the param, matching this plugin's previous (UTC-bucketed) behavior — not
  // a regression, only a missed improvement. The value is sanity-checked
  // before ever being used in a request, matching how the host is validated
  // before use elsewhere in this file.
  Process {
    id: timezoneProc
    command: ["timedatectl", "show", "--property=Timezone", "--value"]
    running: false
    stdout: StdioCollector { id: timezoneOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var value = timezoneOut.text.replace(/^\s+|\s+$/g, "")
      if (/^[A-Za-z0-9_+\-\/]{1,64}$/.test(value)) root.timezone = value
    }
  }

  Timer {
    interval: 60000
    running: root.ready
    repeat: true
    onTriggered: if (root._pendingCalls === 0) root.refresh()
  }

  Component.onCompleted: {
    stateBridge.ensureDir(function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = "Could not secure the settings directory"
        root.stateBlocked = true
        return
      }
      root.loadConfig()
    })
    timezoneProc.running = true
  }
}
