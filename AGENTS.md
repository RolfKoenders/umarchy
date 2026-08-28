# Umarchy

## Project overview

This repository is an Omarchy Quickshell bar-widget plugin showing stats
from a self-hosted Umami analytics instance: live visitors, pageviews,
bounce rate, average visit time, a pageviews-over-time chart, and top
pages/referrers/countries, switchable between every site the account can
see. Umami's API is called from a short-lived Python helper process
(`bin/umami-api`), never from QML directly.

Canonical public repository: `https://github.com/RolfKoenders/umarchy`.

## Local development

```bash
plugin_target="$HOME/.config/omarchy/plugins/io.github.rolfkoenders.umarchy"
mkdir -p "$plugin_target"
cp -a -- "$PWD/." "$plugin_target/"
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.rolfkoenders.umarchy --section right
omarchy restart shell
```

After editing a file, re-copy it into `$plugin_target` and
`omarchy restart shell` again — this plugin is not run from a symlinked
checkout.

## Architecture

- `Panel.qml` — bar icon, site tabs, hero/stats/chart/top-lists, settings.
- `Service.qml` — config, login and 401-retry state machine, refresh timer.
- `RequestBridge.qml` — spawns one `bin/umami-api` process per API call.
- `CredentialManager.qml` — `secret-tool` wrapper for the login password.
- `Model.js` — pure config/period/response-shaping/formatting logic.
- `bin/umami-api` — the only thing that ever makes an HTTP request.

State lives in two files, both chmod 600, in a dedicated directory
(`~/.local/state/omarchy/settings/io.github.rolfkoenders.umarchy/`, chmod
700 — not the shared `settings/` directory other plugins also write into),
written only by `Service.qml`'s own `persist()`/`persistToken()`:
`umarchy.json` (host/username/siteId/period/icon — never the password) and
`umarchy-token.json` (the cached session token, keyed to host+username so a
stale one for a different account is never reused).

## Security model

This follows the pattern from Keeply's marketplace security review
(`HANCORE-linux/omarchy-plugin-marketplace#1750`), which went through
several rounds specifically over QML's `XMLHttpRequest` and Quickshell's
`StdioCollector` both accumulating unbounded data into the long-lived shell
process before any check can run.

- Every Umami API call, including login, happens in `bin/umami-api`: one
  HTTP call per short-lived Python process, `read_capped()` enforcing a
  byte cap and a wall-clock deadline *during the socket read itself* (not
  after), `_NoRedirectHandler` refusing to follow any redirect. The
  wall-clock deadline only works because `read_capped()` reads one byte at
  a time — a larger chunk size lets a slow-but-steady drip keep a single
  `resp.read(n)` call blocked for the whole response regardless of the
  deadline, confirmed empirically while building this (see the comment
  above `read_capped()`).
- `RequestBridge.qml` reads the helper's stdout/stderr via
  `SplitParser { splitMarker: "" }` with manual accumulate-and-cap logic,
  not Quickshell's `StdioCollector`, which accumulates without any bound.
- `CredentialManager.qml` uses the same capped-SplitParser pattern for
  `secret-tool lookup` output.
- The password is never in the config file, never on any process's argv,
  and only ever enters via stdin (from the settings password field to the
  helper's stdin) or `secret-tool store`'s stdin.
- The instance host is validated as a plain `http(s)://host` in both
  `Model.normalizeHost()` (QML side, gates what's saved and what the
  "open in browser" action can open) and `bin/umami-api`'s own
  `validate_host()` (defense in depth, in case the two ever drift).

## Gotchas found the hard way

- **Don't chmod on every `FileView.onLoaded`.** Only chmod right after
  `persist()`/`persistToken()` actually write, matching
  `omarchy-matomo/Service.qml`'s `chmodProc` usage. Chmodding on every load
  (even the load `persist()` itself triggers) touches the file's metadata,
  which the watcher can react to, causing `configFile` to reload right
  after every save and reassert every `text: stats.config.x` binding on the
  settings fields back to the last-saved value on every keystroke. Confirmed
  live: this broke typing in the host/username fields (password was
  unaffected — it has no such binding).
- **Sequencing chmod off `onSaved` doesn't close the exposure window by
  itself.** The first fix (chmod only starting from `FileView.onSaved`,
  never racing the write) was still not enough per marketplace review
  round 2 (`HANCORE-linux/omarchy-plugin-marketplace#2459`): the file still
  exists at its default creation mode for the moment between creation and
  chmod, and `mkdir -p` never restricts an already-existing directory's
  permissions. Fixed by giving the plugin its own dedicated 0700 directory
  (`chmod 700` sequenced right after `mkdir -p`, before the config is ever
  loaded) — that makes the file's own mode moot for cross-user exposure,
  which the review named as a sufficient fix on its own. Also fix, from the
  same round: check `exitCode` in every chmod `Process`'s `onExited` and
  surface a failure via `lastError` — clearing the write guard
  unconditionally silently treats a failed chmod the same as a successful
  one. See `tests/test_state_dir_permissions.qml`.
- **Checking `exitCode` and surfacing `lastError` isn't fail-closed by
  itself — round 2's fix still fell through to using the state anyway.**
  Marketplace review round 3 (`HANCORE-linux/omarchy-plugin-marketplace#2459`):
  `chmodDirProc.onExited` recorded an error on a failed `chmod 700` but then
  unconditionally called `configFile.reload()` regardless, so the plugin
  went on reading and writing credential-bearing state inside a directory
  whose private mode was never established. Likewise `chmodConfigProc`/
  `chmodTokenProc.onExited` only cleared the write guard on failure, which
  let every future `persist()`/`persistToken()` carry on as if the last
  write had ended up private. Fixed with a single `root.stateBlocked` flag,
  set by any of the three chmod handlers on a nonzero exit: the dir handler
  returns before ever reaching `configFile.reload()`, and `persist()`/
  `persistToken()` both refuse to run once it's set. There's no path that
  clears it again — recovering means fixing the permission problem and
  restarting the plugin. See `tests/test_state_dir_permissions.qml`'s
  vanish-dir/vanish-file cases, which simulate a chmod that fails after its
  target existed a moment earlier.
- **Quickshell's `Process` has no `exitCode` property**, only an
  `exited(exitCode, exitStatus)` signal (confirmed against
  `quickshell-io.qmltypes`). Reading a bare `exitCode` inside
  `onRunningChanged` throws `ReferenceError`.
- **`MouseArea.onEntered` carries no `mouse` parameter** — only
  `onPositionChanged`/`onClicked`/`onPressed` do. Use the area's own
  `mouseX`/`mouseY` instead. (This one was already present in
  `omarchy-matomo/Sparkline.qml`, not introduced here — worth a look if
  that repo has the same bug.)
- **`GET /api/websites` is a paginated envelope**
  (`{data, count, page, pageSize}`), not a bare array — confirmed against
  docs.umami.is and the live API. `Model.parseSites()` unwraps `.data`;
  request `?pageSize=100` so an account with more than the default 10 sites
  doesn't get silently truncated.
- **Don't decide a chart label's format from whether a timestamp lands on
  local midnight.** The sparkline's day-bucket axis labels all showed the
  same hour (e.g. "2a, 2a, 2a") because Umami buckets `unit=day` series at
  UTC midnight, and `new Date(x).getHours() === 0` is only true there for a
  UTC+0 visitor — everyone else's "day bucket" lands on some other local
  hour, every time, by the same fixed offset. Fixed by deciding the format
  from the period's own `unit` (`"day"` vs `"hour"`, see `PERIODS`), never by
  inspecting the parsed timestamp. Also added a best-effort `timezone=`
  query param (via a `timedatectl` helper `Process`, `Intl` is not available
  in this QML JS engine — confirmed empirically) so Umami's own day
  boundaries line up with the visitor's actual calendar day, not just the
  label text describing them. See the regression tests in `test_model.js`
  that pin this to `Europe/Amsterdam` (UTC+2) specifically, since the bug is
  invisible on a UTC-timezone CI runner.
- Avoid ES2015+ syntax not confirmed present in every QML JS engine version
  in play (e.g. array spread `[...x]`) — use `.concat()` instead. No arrow
  functions, template literals, or `const`/`let` anywhere in this repo,
  matching the rest of the ecosystem's QML files.

## Verification

```bash
python3 tests/test_umami_api.py                    # unit + real-local-HTTP-server integration tests
node tests/test_model.js                           # Model.js unit tests
quickshell -p tests/test_state_dir_permissions.qml # state dir/file permission sequencing, real Quickshell engine
omarchy plugin validate .
```

`RequestBridge.qml`'s process/stdio wiring and `CredentialManager.qml`'s
`secret-tool` wrapper aren't unit tested — verify those against a real
Quickshell engine and the actual installed plugin instead, the same
limitation Keeply's own review left in place. The directory/file permission
sequencing in `Service.qml` *is* covered, by
`tests/test_state_dir_permissions.qml` — a standalone harness (not
`Service.qml` loaded directly, since its sibling types resolve via
Quickshell's directory-based QML lookup, which only works from inside the
plugin directory) that re-creates the same `mkdir` → `chmod` → write →
`chmod` sequence against a real scratch directory and verifies the result
independently via `stat`, run with `quickshell -p` (bare `qml6` can't even
instantiate Quickshell's `Process` type).

## Releases

Bump `manifest.json`'s `version` (semver: patch for fixes, minor for
features) as part of any user-facing change. `.github/workflows/release.yml`
watches pushes to `main` and publishes a tagged GitHub release with
auto-generated notes the moment it sees a version that isn't tagged yet —
nothing else to do once the bump lands. Docs/CI-only changes shouldn't bump
the version; the workflow no-ops cleanly when nothing changed.
