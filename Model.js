.pragma library

// Pure JS: config parsing, period math, response shaping, formatting, and
// the auth-retry policy. Kept free of QML/Quickshell so it can be unit
// tested directly (tests/test_model.js) rather than only verified live.

var PERIODS = [
  { value: "today", label: "Today", unit: "hour" },
  { value: "7d", label: "7d", unit: "day" },
  { value: "30d", label: "30d", unit: "day" }
]

// Response-shape caps: a response under any byte cap enforced by
// bin/umami-api can still be thousands of tiny records, or one record with
// a huge field — either becomes real UI cost once bound to a Repeater. Cap
// count and per-field length here, before any of it is bound to QML.
var MAX_LIST_ROWS = 20
var MAX_SERIES_POINTS = 400
var MAX_FIELD_LENGTH = 200

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function truncateField(value) {
  var text = trim(value)
  if (text.length <= MAX_FIELD_LENGTH) return text
  return text.substring(0, MAX_FIELD_LENGTH - 1) + "…"
}

function emptyConfig() {
  return { host: "", username: "", siteId: "", period: "today", showLiveCount: false, icon: "󰄪" }
}

// Only http(s) with a real host, no embedded userinfo. Mirrors the same
// validation bin/umami-api applies server-side (defense in depth) — this
// is the copy that actually gates what gets saved and what the "open in
// browser" action is allowed to open.
function normalizeHost(value) {
  var text = trim(value)
  if (!text) return ""
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(text)) text = "https://" + text
  var schemeMatch = text.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/(.*)$/)
  if (!schemeMatch) return ""
  var scheme = schemeMatch[1].toLowerCase()
  if (scheme !== "http" && scheme !== "https") return ""
  var rest = schemeMatch[2]
  if (rest.indexOf("@") >= 0) return "" // reject embedded userinfo (user:pass@host)
  var host = rest.split(/[\/?#]/)[0]
  if (!host) return ""
  return scheme + "://" + host
}

function isValidHost(value) {
  return normalizeHost(value) !== ""
}

function parseConfig(raw) {
  var cfg = emptyConfig()
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return cfg
    return {
      host: normalizeHost(data.host),
      username: trim(data.username),
      siteId: trim(data.siteId),
      period: periodOrDefault(data.period),
      showLiveCount: data.showLiveCount === true,
      icon: trim(data.icon) || "󰄪"
    }
  } catch (e) {
    return cfg
  }
}

function serializeConfig(cfg) {
  var data = cfg && typeof cfg === "object" ? cfg : emptyConfig()
  return JSON.stringify({
    host: normalizeHost(data.host),
    username: trim(data.username),
    siteId: trim(data.siteId),
    period: periodOrDefault(data.period),
    showLiveCount: data.showLiveCount !== false,
    icon: trim(data.icon) || "󰄪"
  }, null, 2) + "\n"
}

function patchConfig(cfg, values) {
  var next = parseConfig(serializeConfig(cfg))
  if (!values || typeof values !== "object") return next
  if (values.host !== undefined) next.host = normalizeHost(values.host)
  if (values.username !== undefined) next.username = trim(values.username)
  if (values.siteId !== undefined) next.siteId = trim(values.siteId)
  if (values.period !== undefined) next.period = periodOrDefault(values.period)
  if (values.showLiveCount !== undefined) next.showLiveCount = values.showLiveCount !== false
  if (values.icon !== undefined) next.icon = trim(values.icon) || "󰄪"
  return next
}

function hasConnectionTarget(cfg) {
  return !!(cfg && normalizeHost(cfg.host) && trim(cfg.username))
}

function periodInfo(value) {
  var period = String(value || "")
  for (var i = 0; i < PERIODS.length; i++) {
    if (PERIODS[i].value === period) return PERIODS[i]
  }
  return PERIODS[0]
}

function periodOrDefault(value) {
  return periodInfo(value).value
}

// now: a Date (injected so this is testable without mocking the clock).
// Object.prototype.toString rather than `instanceof Date` deliberately —
// a Date constructed in a different JS realm (e.g. Node's vm module, used
// by tests/test_model.js) fails instanceof against this realm's Date class
// even though it's a perfectly valid Date.
function periodRange(value, now) {
  var info = periodInfo(value)
  var clock = Object.prototype.toString.call(now) === "[object Date]" ? now : new Date()
  var endAt = clock.getTime()
  var startOfToday = new Date(clock.getFullYear(), clock.getMonth(), clock.getDate()).getTime()
  var days = info.value === "today" ? 0 : (info.value === "7d" ? 6 : 29)
  var startAt = startOfToday - days * 86400000
  return { startAt: startAt, endAt: endAt, unit: info.unit }
}

function parseSites(raw) {
  var parsed = asJson(raw)
  // GET /api/websites returns a paginated envelope ({data, count, page,
  // pageSize}), not a bare array — confirmed against docs.umami.is and the
  // real API. Accept a bare array too, defensively, in case that ever
  // changes or another endpoint reuses this parser.
  var data = Array.isArray(parsed) ? parsed
    : (parsed && Array.isArray(parsed.data)) ? parsed.data : []
  var out = []
  for (var i = 0; i < Math.min(data.length, MAX_LIST_ROWS * 5); i++) {
    var row = data[i]
    if (!row || row.id === undefined || row.id === null) continue
    out.push({
      id: truncateField(row.id),
      name: truncateField(row.name || row.domain || row.id),
      domain: truncateField(row.domain || "")
    })
  }
  return out
}

function activeSite(sites, siteId) {
  var rows = Array.isArray(sites) ? sites : []
  var wanted = trim(siteId)
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].id === wanted) return rows[i]
  }
  return rows.length ? rows[0] : null
}

function parseStats(raw) {
  var data = asJson(raw)
  var empty = { pageviews: 0, visitors: 0, visits: 0, bounces: 0, totaltime: 0 }
  if (!data || typeof data !== "object") return empty
  return {
    pageviews: metricValue(data.pageviews),
    visitors: metricValue(data.visitors),
    visits: metricValue(data.visits),
    bounces: metricValue(data.bounces),
    totaltime: metricValue(data.totaltime)
  }
}

function metricValue(field) {
  if (!field || typeof field !== "object") return numberValue(field)
  return numberValue(field.value)
}

// unit: the period's bucket granularity ("day" or "hour", see PERIODS)
// determines the label format directly — it must NOT be guessed from
// whether a timestamp happens to land on local midnight. Umami buckets
// "day" units at UTC midnight, and converting that instant to any
// non-UTC local time almost never lands back on local midnight (e.g.
// UTC+2 puts every single day-bucket at 2am local), so a
// guess-from-local-midnight heuristic silently mislabels every point in
// the series as an hour instead of a date.
function parsePageviewSeries(raw, unit) {
  var data = asJson(raw)
  if (!data || typeof data !== "object" || !Array.isArray(data.pageviews)) return []
  var rows = data.pageviews.slice(0, MAX_SERIES_POINTS)
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    out.push({ label: seriesLabel(row.x, unit), value: numberValue(row.y) })
  }
  return out
}

function seriesLabel(x, unit) {
  var n = Number(x)
  var date = isFinite(n) ? new Date(n) : new Date(String(x || ""))
  if (isNaN(date.getTime())) return ""
  if (unit === "day") return shortDateLabel(date)
  var hh = date.getHours()
  var h12 = ((hh % 12) + 12) % 12
  if (h12 === 0) h12 = 12
  return h12 + (hh < 12 ? "a" : "p")
}

function shortDateLabel(date) {
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return months[date.getMonth()] + " " + date.getDate()
}

function seriesValues(series) {
  var rows = Array.isArray(series) ? series : []
  var out = []
  for (var i = 0; i < rows.length; i++) out.push(numberValue(rows[i] && rows[i].value))
  return out
}

function seriesLabels(series) {
  var rows = Array.isArray(series) ? series : []
  var out = []
  for (var i = 0; i < rows.length; i++) out.push(rows[i] && rows[i].label ? String(rows[i].label) : "")
  return out
}

// Umami's /metrics endpoint returns [{x, y}, ...] rows, x being the
// path/referrer/country value and y the visitor count.
function parseMetricRows(raw) {
  var data = asJson(raw)
  if (!Array.isArray(data)) return []
  var rows = data.slice(0, MAX_LIST_ROWS)
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    var name = row.x === undefined || row.x === null || row.x === "" ? "(direct)" : row.x
    out.push({ name: truncateField(name), count: numberValue(row.y) })
  }
  return out
}

function parseActiveVisitors(raw) {
  var data = asJson(raw)
  if (!data || typeof data !== "object") return 0
  if (Array.isArray(data.visitors)) return numberValue(data.visitors[0])
  return numberValue(data.visitors)
}

function formatCount(value) {
  var n = numberValue(value)
  if (n >= 1000000) return (n / 1000000).toFixed(n >= 10000000 ? 0 : 1).replace(/\.0$/, "") + "M"
  if (n >= 10000) return Math.round(n / 1000) + "k"
  if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k"
  return String(Math.round(n))
}

function formatBounceRate(bounces, visits) {
  var v = numberValue(visits)
  if (v <= 0) return "--"
  var rate = Math.max(0, Math.min(100, (numberValue(bounces) / v) * 100))
  return Math.round(rate) + "%"
}

function formatAvgTime(totalSeconds, visits) {
  var v = numberValue(visits)
  if (v <= 0) return "--"
  var avg = Math.max(0, numberValue(totalSeconds) / v)
  var minutes = Math.floor(avg / 60)
  var seconds = Math.round(avg % 60)
  return minutes + "m " + (seconds < 10 ? "0" : "") + seconds + "s"
}

function asJson(raw) {
  if (raw && typeof raw === "object") return raw
  try {
    return JSON.parse(String(raw === undefined || raw === null ? "" : raw))
  } catch (e) {
    return null
  }
}

function numberValue(value) {
  var n = parseFloat(String(value === undefined || value === null ? "0" : value))
  return isNaN(n) ? 0 : n
}

// Pure retry policy for a request that came back with (errorCode,
// errorMessage) from RequestBridge, given whether a password is currently
// known to be stored in the keyring. Returns one of:
//   "ok"      — no error, use the result
//   "retry"   — a stored password exists; try logging in again once, then
//               retry the original call
//   "prompt"  — no stored password (or the retry itself already failed);
//               surface authentication_required and open settings
//   "error"   — any other failure; surface errorMessage as-is
//
// alreadyRetried guards against looping: a 401 immediately after a retry
// must prompt, not retry forever.
function nextAuthState(errorCode, hasStoredPassword, alreadyRetried) {
  if (!errorCode) return "ok"
  if (errorCode === "http_status:401") {
    if (alreadyRetried) return "prompt"
    return hasStoredPassword ? "retry" : "prompt"
  }
  return "error"
}

function errorMessageFor(errorCode, errorMessage) {
  if (errorCode === "http_status:401") return "Umami rejected the saved password"
  if (errorCode === "too_large") return "Umami response was too large"
  if (errorCode && errorCode.indexOf("http_status:") === 0) {
    return "Request failed (" + errorCode.substring("http_status:".length) + ")"
  }
  return String(errorMessage || "Couldn't reach Umami")
}
