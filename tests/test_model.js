#!/usr/bin/env node
// Tests for Model.js's config/period/response-shaping/auth-retry logic, run
// against the real file (not a duplicated copy) via Node's vm module, since
// Model.js has no QML dependency beyond the .pragma library directive.
// Harness style matches Keeply-link/keeply-omarchy/tests/test_model.js.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE_PATH = path.join(__dirname, "..", "Model.js");

function loadModel() {
  const source = fs
    .readFileSync(SOURCE_PATH, "utf8")
    .replace(/^\.pragma library\s*/m, ""); // not valid outside QML

  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: "Model.js" });
  return sandbox;
}

let failures = 0;

function check(name, condition) {
  if (condition) {
    console.log("PASS " + name);
  } else {
    console.log("FAIL " + name);
    failures++;
  }
}

function run_normalize_host_adds_https_by_default() {
  const Model = loadModel();
  check("bare host gets https:// prepended", Model.normalizeHost("analytics.keeply.tools") === "https://analytics.keeply.tools");
}

function run_normalize_host_strips_path_and_trailing_slash() {
  const Model = loadModel();
  check("path is stripped", Model.normalizeHost("https://example.com/some/path?x=1") === "https://example.com");
  check("trailing slash is stripped", Model.normalizeHost("https://example.com/") === "https://example.com");
}

function run_normalize_host_keeps_explicit_http_and_port() {
  const Model = loadModel();
  check("http scheme and port preserved", Model.normalizeHost("http://localhost:3000") === "http://localhost:3000");
}

function run_normalize_host_rejects_bad_scheme() {
  const Model = loadModel();
  check("ftp scheme rejected", Model.normalizeHost("ftp://example.com") === "");
}

function run_normalize_host_rejects_userinfo() {
  const Model = loadModel();
  check("embedded userinfo rejected", Model.normalizeHost("https://user:pass@example.com") === "");
}

function run_normalize_host_rejects_empty() {
  const Model = loadModel();
  check("empty input rejected", Model.normalizeHost("") === "");
  check("whitespace-only input rejected", Model.normalizeHost("   ") === "");
}

function run_is_valid_host() {
  const Model = loadModel();
  check("valid host recognized", Model.isValidHost("https://example.com") === true);
  check("invalid host recognized", Model.isValidHost("ftp://example.com") === false);
}

function run_config_round_trip() {
  const Model = loadModel();
  const cfg = Model.parseConfig(Model.serializeConfig({
    host: "analytics.keeply.tools", username: "viewer", siteId: "abc123",
    period: "7d", showLiveCount: false, icon: "📈"
  }));
  check("host normalized and round-tripped", cfg.host === "https://analytics.keeply.tools");
  check("username round-tripped", cfg.username === "viewer");
  check("siteId round-tripped", cfg.siteId === "abc123");
  check("period round-tripped", cfg.period === "7d");
  check("showLiveCount round-tripped", cfg.showLiveCount === false);
}

function run_parse_config_handles_garbage() {
  const Model = loadModel();
  const cfg = Model.parseConfig("not json at all");
  check("garbage input falls back to empty config", cfg.host === "" && cfg.username === "");
}

function run_patch_config_only_touches_given_fields() {
  const Model = loadModel();
  const base = Model.parseConfig(Model.serializeConfig({ host: "https://a.example", username: "u", siteId: "1", period: "today", showLiveCount: true }));
  const patched = Model.patchConfig(base, { period: "30d" });
  check("patched field changes", patched.period === "30d");
  check("untouched field is preserved", patched.host === "https://a.example" && patched.username === "u" && patched.siteId === "1");
}

function run_has_connection_target() {
  const Model = loadModel();
  check("host+username present is a connection target", Model.hasConnectionTarget({ host: "https://a.example", username: "u" }) === true);
  check("missing username is not", Model.hasConnectionTarget({ host: "https://a.example", username: "" }) === false);
  check("missing host is not", Model.hasConnectionTarget({ host: "", username: "u" }) === false);
}

function run_period_defaults_to_today() {
  const Model = loadModel();
  check("unknown period falls back to today", Model.periodOrDefault("bogus") === "today");
  check("today is accepted", Model.periodOrDefault("today") === "today");
  check("7d is accepted", Model.periodOrDefault("7d") === "7d");
  check("30d is accepted", Model.periodOrDefault("30d") === "30d");
}

function run_period_range_today() {
  const Model = loadModel();
  const now = new Date(2026, 0, 15, 14, 30, 0); // Jan 15 2026, 14:30 local
  const range = Model.periodRange("today", now);
  const startOfDay = new Date(2026, 0, 15, 0, 0, 0).getTime();
  check("today starts at local midnight", range.startAt === startOfDay);
  check("today ends at now", range.endAt === now.getTime());
  check("today uses hourly unit", range.unit === "hour");
}

function run_period_range_7d_and_30d() {
  const Model = loadModel();
  const now = new Date(2026, 0, 15, 14, 30, 0);
  const range7 = Model.periodRange("7d", now);
  const range30 = Model.periodRange("30d", now);
  const expected7Start = new Date(2026, 0, 9, 0, 0, 0).getTime(); // 6 days back
  const expected30Start = new Date(2025, 11, 17, 0, 0, 0).getTime(); // 29 days back
  check("7d spans 6 days back from today", range7.startAt === expected7Start);
  check("30d spans 29 days back from today", range30.startAt === expected30Start);
  check("7d/30d use daily unit", range7.unit === "day" && range30.unit === "day");
}

function run_parse_sites_caps_and_skips_bad_rows() {
  const Model = loadModel();
  const raw = [{ id: "1", name: "Site One" }, { name: "no id, skipped" }, { id: 2, domain: "two.example" }];
  const sites = Model.parseSites(raw);
  check("valid rows kept, invalid skipped", sites.length === 2);
  check("name falls back to domain when missing", sites[1].name === "two.example");
}

function run_parse_sites_unwraps_paginated_envelope() {
  const Model = loadModel();
  // GET /api/websites' real shape (confirmed against docs.umami.is and the
  // live API) is {data: [...], count, page, pageSize} — not a bare array.
  // Regression test for the bug that showed "No sites available for this
  // account" against a real, non-empty Umami account.
  const raw = { data: [{ id: "1", name: "Site One" }], count: 1, page: 1, pageSize: 10 };
  const sites = Model.parseSites(raw);
  check("paginated envelope is unwrapped", sites.length === 1 && sites[0].name === "Site One");
}

function run_parse_sites_handles_garbage() {
  const Model = loadModel();
  check("null input yields empty list", Model.parseSites(null).length === 0);
  check("object with no data field yields empty list", Model.parseSites({ count: 0 }).length === 0);
}

function run_parse_sites_caps_row_count() {
  const Model = loadModel();
  const raw = [];
  for (let i = 0; i < 500; i++) raw.push({ id: String(i), name: "site " + i });
  const sites = Model.parseSites(raw);
  check("site list is capped, not unbounded", sites.length < 500);
}

function run_active_site_finds_by_id_or_falls_back() {
  const Model = loadModel();
  const sites = [{ id: "1", name: "One" }, { id: "2", name: "Two" }];
  check("finds matching id", Model.activeSite(sites, "2").name === "Two");
  check("falls back to first when id unknown", Model.activeSite(sites, "nope").name === "One");
  check("null on empty list", Model.activeSite([], "1") === null);
}

function run_parse_stats_extracts_value_fields() {
  const Model = loadModel();
  const stats = Model.parseStats({
    pageviews: { value: 120 }, visitors: { value: 40 }, visits: { value: 55 },
    bounces: { value: 10 }, totaltime: { value: 3300 }
  });
  check("pageviews extracted", stats.pageviews === 120);
  check("visitors extracted", stats.visitors === 40);
  check("bounces extracted", stats.bounces === 10);
}

function run_parse_stats_handles_missing_data() {
  const Model = loadModel();
  const stats = Model.parseStats(null);
  check("missing data yields zeros, not a crash", stats.pageviews === 0 && stats.visits === 0);
}

function run_parse_pageview_series_caps_points() {
  const Model = loadModel();
  const rows = [];
  for (let i = 0; i < 1000; i++) rows.push({ x: 1700000000000 + i * 3600000, y: i });
  const series = Model.parsePageviewSeries({ pageviews: rows });
  check("series is capped, not unbounded", series.length < 1000 && series.length > 0);
}

function run_parse_metric_rows_caps_count_and_field_length() {
  const Model = loadModel();
  const rows = [];
  for (let i = 0; i < 100; i++) rows.push({ x: "/page-" + i, y: i });
  const parsed = Model.parseMetricRows(rows);
  check("metric rows capped at MAX_LIST_ROWS (20)", parsed.length === 20);

  const longName = "/" + "x".repeat(1000);
  const truncated = Model.parseMetricRows([{ x: longName, y: 5 }]);
  check("long field name is truncated, not passed through whole", truncated[0].name.length < longName.length);
}

function run_parse_metric_rows_direct_fallback() {
  const Model = loadModel();
  const parsed = Model.parseMetricRows([{ x: "", y: 3 }, { x: null, y: 2 }]);
  check("empty referrer becomes (direct)", parsed[0].name === "(direct)");
  check("null referrer becomes (direct)", parsed[1].name === "(direct)");
}

function run_parse_active_visitors_both_shapes() {
  const Model = loadModel();
  check("array-of-one shape", Model.parseActiveVisitors({ visitors: [7] }) === 7);
  check("plain-number shape", Model.parseActiveVisitors({ visitors: 9 }) === 9);
  check("missing data yields 0", Model.parseActiveVisitors(null) === 0);
}

function run_format_count_thresholds() {
  const Model = loadModel();
  check("small numbers pass through", Model.formatCount(42) === "42");
  check("thousands get a k suffix", Model.formatCount(2500) === "2.5k");
  check("ten-thousands round to whole k", Model.formatCount(15000) === "15k");
  check("millions get an M suffix", Model.formatCount(2500000) === "2.5M");
}

function run_format_bounce_rate() {
  const Model = loadModel();
  check("normal rate computed", Model.formatBounceRate(30, 100) === "30%");
  check("zero visits yields placeholder, not NaN/Infinity", Model.formatBounceRate(0, 0) === "--");
}

function run_format_avg_time() {
  const Model = loadModel();
  check("normal average formatted as m/s", Model.formatAvgTime(150, 1) === "2m 30s");
  check("zero visits yields placeholder, not NaN", Model.formatAvgTime(0, 0) === "--");
}

function run_next_auth_state_ok_when_no_error() {
  const Model = loadModel();
  check("no error is ok", Model.nextAuthState(null, true, false) === "ok");
}

function run_next_auth_state_retries_once_with_stored_password() {
  const Model = loadModel();
  check("401 with stored password retries", Model.nextAuthState("http_status:401", true, false) === "retry");
  check("a second 401 after already retrying prompts instead of looping", Model.nextAuthState("http_status:401", true, true) === "prompt");
}

function run_next_auth_state_prompts_without_stored_password() {
  const Model = loadModel();
  check("401 with no stored password prompts directly", Model.nextAuthState("http_status:401", false, false) === "prompt");
}

function run_next_auth_state_other_errors_pass_through() {
  const Model = loadModel();
  check("a non-401 error is just an error", Model.nextAuthState("http_status:500", true, false) === "error");
  check("too_large is just an error", Model.nextAuthState("too_large", true, false) === "error");
}

function run_error_message_for_known_codes() {
  const Model = loadModel();
  check("401 gets a specific message", Model.errorMessageFor("http_status:401", "").indexOf("password") >= 0);
  check("too_large gets a specific message", Model.errorMessageFor("too_large", "").toLowerCase().indexOf("large") >= 0);
  check("other http_status includes the code", Model.errorMessageFor("http_status:500", "").indexOf("500") >= 0);
  check("unknown code falls back to the raw message", Model.errorMessageFor("other", "network exploded") === "network exploded");
}

const runners = [
  run_normalize_host_adds_https_by_default,
  run_normalize_host_strips_path_and_trailing_slash,
  run_normalize_host_keeps_explicit_http_and_port,
  run_normalize_host_rejects_bad_scheme,
  run_normalize_host_rejects_userinfo,
  run_normalize_host_rejects_empty,
  run_is_valid_host,
  run_config_round_trip,
  run_parse_config_handles_garbage,
  run_patch_config_only_touches_given_fields,
  run_has_connection_target,
  run_period_defaults_to_today,
  run_period_range_today,
  run_period_range_7d_and_30d,
  run_parse_sites_caps_and_skips_bad_rows,
  run_parse_sites_unwraps_paginated_envelope,
  run_parse_sites_handles_garbage,
  run_parse_sites_caps_row_count,
  run_active_site_finds_by_id_or_falls_back,
  run_parse_stats_extracts_value_fields,
  run_parse_stats_handles_missing_data,
  run_parse_pageview_series_caps_points,
  run_parse_metric_rows_caps_count_and_field_length,
  run_parse_metric_rows_direct_fallback,
  run_parse_active_visitors_both_shapes,
  run_format_count_thresholds,
  run_format_bounce_rate,
  run_format_avg_time,
  run_next_auth_state_ok_when_no_error,
  run_next_auth_state_retries_once_with_stored_password,
  run_next_auth_state_prompts_without_stored_password,
  run_next_auth_state_other_errors_pass_through,
  run_error_message_for_known_codes,
];

for (const runner of runners) runner();

if (failures > 0) {
  console.log(failures + " test(s) failed");
  process.exit(1);
} else {
  console.log("All tests passed");
}
