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
- `StateBridge.qml` — spawns one `bin/umami-state` process per state
  read/write/ensure-dir call.
- `CredentialManager.qml` — `secret-tool` wrapper for the login password.
- `Model.js` — pure config/period/response-shaping/formatting logic.
- `bin/umami-api` — the only thing that ever makes an HTTP request.
- `bin/umami-state` — the only thing that ever touches the state
  directory/files on disk.

State lives in two files, both chmod 600, in a dedicated directory
(`~/.local/state/omarchy/settings/io.github.rolfkoenders.umarchy/`, chmod
700 — not the shared `settings/` directory other plugins also write into):
`umarchy.json` (host/username/siteId/period/icon — never the password) and
`umarchy-token.json` (the cached session token, keyed to host+username so a
stale one for a different account is never reused). Neither `Service.qml`
nor any other QML file ever addresses these by a predictable path string —
`bin/umami-state` (via `StateBridge.qml`) is the only thing that creates,
reads, or writes them, and it does so through a descriptor-based walk that
refuses to follow a symlink anywhere in the path (see Security model).

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
- The state directory and its two files are never addressed by a
  predictable path string. `mkdir -p`/`chmod`-by-path both silently follow
  a symlink planted at the target path, and a `FileView` opened by path has
  no defense against a swapped-in FIFO or oversized file. `bin/umami-state`
  instead walks from `$HOME` to the plugin's directory one path component
  at a time, opening each with `O_NOFOLLOW | O_DIRECTORY` relative to the
  previous component's own held file descriptor (`os.open(..., dir_fd=...)`)
  — a symlink planted at any point, even in the exact instant between two
  of its own syscalls, fails the next open rather than being silently
  followed. The two files are opened the same way (`O_NOFOLLOW`), then
  checked with `fstat()` for being a regular file owned by the current
  user and under a byte cap, before anything is read from or written to
  them. See its own docstring and
  `HANCORE-linux/omarchy-plugin-marketplace#2459` (fourth round) for the
  finding that produced this shape.

## Gotchas found the hard way

The first three of these describe an `mkdir -p` + `chmod`-by-path +
`FileView`-by-path approach that no longer exists in this codebase — kept
as history for why the current `bin/umami-state` design (see Architecture
and Security model) looks the way it does, through three rounds of the
same reviewer finding the same underlying problem one layer deeper each
time.

- **Don't chmod on every `FileView.onLoaded`.** (Round 1.) Chmodding on
  every load, back when config loading went through a `FileView`, touched
  the file's metadata, which its own change-watcher reacted to, causing a
  reload right after every save that reasserted every settings-field
  binding back to the last-saved value on every keystroke. Confirmed live:
  this broke typing in the host/username fields.
- **Sequencing chmod off `onSaved` doesn't close the exposure window by
  itself.** (Round 2.) The file still existed at its default creation mode
  for the moment between creation and chmod, and `mkdir -p` never
  restricted an already-existing directory's permissions. Also: clearing a
  write-in-progress guard unconditionally in a chmod process's `onExited`
  silently treated a failed chmod the same as a successful one.
- **Checking `exitCode` and surfacing `lastError` isn't fail-closed by
  itself.** (Round 3.) The dir-chmod handler recorded an error on failure
  but still went on to load the config anyway; the file-chmod handlers only
  cleared their write guard, letting every future write carry on as if the
  last one had ended up private.
- **None of rounds 1–3 close the actual hole: a predictable path can have a
  symlink planted at it before the plugin ever runs.** (Round 4.) `mkdir -p`
  treats a symlink-to-a-directory as "already exists"; `chmod`-by-path and
  `FileView`-by-path both resolve through a symlink transparently — so
  rounds 1–3's fixes could all "succeed" against a directory or file an
  attacker chose, not the one the plugin actually created, and none of them
  defended against a pre-existing FIFO (blocks a read/write open forever)
  or an oversized swapped-in file either. There's no way to get these
  guarantees from QML's own file APIs, so the whole state
  directory/file layer moved into `bin/umami-state`, which never resolves a
  predictable path in one call — see Security model and
  `tests/test_umami_state.py`, which plants each of these attacks for real
  in a scratch `$HOME` (symlinked directory, symlinked file, FIFO,
  oversized file) and confirms every one is refused.
- **`GET /api/websites?includeTeams=true` does not fix "team sites don't
  show up" for a View Only member.** (Issue #1.) That route's team-inclusion
  path is gated to `role in [teamOwner, teamManager]` server-side
  (`getAllUserWebsitesIncludingTeamAccess` in Umami's own source) — View
  Only is neither, so it still comes back empty for exactly the
  README-recommended setup. The only path that covers every team role is
  `GET /api/me/teams` (no role filter at all) followed by
  `GET /api/teams/{id}/websites` (readable by any team member, any role) —
  see `Service.qml`'s `fetchSites`.
- **A `Process` with `stdinEnabled: true` doesn't send EOF just because
  you're done calling `write()`.** `bin/umami-state`'s write command reads
  a fixed-size-capped chunk of stdin (it can't use `readline()` — the JSON
  payload itself contains real newlines), and that read only returns once
  either the cap is hit or stdin reaches EOF. The first version of
  `StateBridge.qml` wrote the payload and left `stdinEnabled` on, so the
  helper sat blocked forever waiting for more input that was never coming
  — confirmed live: `persist()` silently never wrote anything, and `ps`
  still showed the helper process running minutes later. Toggling
  `stdinEnabled` back to `false` right after `write()` is what actually
  closes this process's end of the pipe and delivers the EOF. See
  `tests/test_state_bridge_write.qml`, which fails with a timeout (not a
  false pass) if this regresses.
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
python3 tests/test_umami_api.py                   # unit + real-local-HTTP-server integration tests
python3 tests/test_umami_state.py                 # unit + real symlink/FIFO/oversize attack integration tests
node tests/test_model.js                          # Model.js unit tests
quickshell -p tests/test_state_bridge_write.qml   # state write/EOF handoff, real Quickshell engine
omarchy plugin validate .
```

`RequestBridge.qml`'s and `StateBridge.qml`'s process/stdio wiring, and
`CredentialManager.qml`'s `secret-tool` wrapper, aren't unit tested —
verify those against a real Quickshell engine and the actual installed
plugin instead, the same limitation Keeply's own review left in place.
`bin/umami-state`'s actual security logic (the no-follow directory walk,
the symlink/FIFO/owner/size checks on the two files) *is* thoroughly
covered by `tests/test_umami_state.py`, which plants each attack for real
in a scratch `$HOME` rather than mocking anything. `StateBridge.qml`'s
write-then-EOF handoff specifically also has its own real-Quickshell-engine
test, `tests/test_state_bridge_write.qml` — a standalone harness (not
`StateBridge.qml` loaded directly, since running it against the real
`$HOME` from an automated test would overwrite this machine's actual
config) that replicates the exact same mechanism against a scratch `$HOME`
with a real `bin/umami-state` process, run with `quickshell -p` (bare
`qml6` can't even instantiate Quickshell's `Process` type).

## Releases

Bump `manifest.json`'s `version` (semver: patch for fixes, minor for
features) as part of any user-facing change. `.github/workflows/release.yml`
watches pushes to `main` and publishes a tagged GitHub release with
auto-generated notes the moment it sees a version that isn't tagged yet —
nothing else to do once the bump lands. Docs/CI-only changes shouldn't bump
the version; the workflow no-ops cleanly when nothing changed.
