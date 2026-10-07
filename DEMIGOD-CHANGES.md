# DEMIGOD-CHANGES.md

Demigod fork change log — required by Apache License 2.0 §4(b).
Upstream: `herdrdev/herdr` (Apache-2.0). Fork: `Uuriko/herdr`.

This file records every modification made to the upstream tree for the
Demigod/Project Room fork. The fork's goal: a **hermetic headless session
server** — real PTYs, the newline-delimited JSON socket API, session
persistence, the event hub, and the self-report path — with no remote
catalog, no phone-home, no self-update, no TUI, no plugins, no SSH
federation, and a hardened socket surface.

Branch: `demigod/strip-v1`. Base: upstream `a124eed7` (2026-10-06).

**Untouched on purpose:** `src/pty/`, `vendor/portable-pty`, `crates/ghostty-vt`
(PTY/VT core), `src/persist/`, `src/api/schema/`, `src/api/event_hub.rs`,
`src/api/subscriptions.rs`, `src/api/wait.rs`, `src/server/headless.rs`
(method dispatch internals). Keeping the diff narrow keeps upstream rebases
mechanical.

---

## 2026-10-06 — strip v1 (lane B1, `demigod/strip-v1`)

### Socket API method removals (`src/api/server.rs`)

New chokepoint `demigod_removed_method_name()` checked at the top of
`handle_request()`, before any dispatch. Removed methods fail closed with
`{"error": {"code": "method_removed", ...}}`. The removal holds no matter
which internal handler still exists behind it.

| Method | Why (risk-review §4) |
|---|---|
| `server.stop` | Item 6 — a socket client must never stop the server |
| `server.reload_config` | Item 6 — config reload is operator-side only |
| `server.reload_agent_manifests` | Item 6 — no remote manifest path remains |
| `notification.show` | Item 10 — toasts are a TUI surface; removed |
| `layout.apply` | Item 9 — applied layouts could set env/cwd/argv on new panes |
| `integration.install`, `integration.uninstall` | Item 5 — agent-CLI hook edits are operator deploy-time work, never socket-driven |
| `worktree.list/create/open/remove` | Item 11 — repo setup is operator/adapter tooling |
| `plugin.*` (all 12: link/list/unlink/enable/disable/action.list/action.invoke/log.list/pane.open/pane.focus/pane.close) | Item 4 — plugin host removed from the socket surface; arbitrary code execution by design, not our product |

Also removed: the `server.stop` fast-path arm in `handle_request()` and the
now-unused `stop_caller` parameter (a stop already in flight via process
signals still fails requests closed with `server_unavailable`). CLI
`herdr server stop|reload-config|reload-agent-manifests` now refuse with a
clear error (`src/cli/server.rs`); the orphaned handler functions were
deleted. Tests in `src/api/server.rs` were updated to assert rejection.

### Same-UID socket gate (`src/api/server.rs`, `src/platform/`)

Risk-review item 8. New `SO_PEERCRED`/`getpeereid` peer-UID lookup:
`platform::socket_peer_uid` (linux, macos; stub on other Unixes),
`platform::local_stream_peer_uid`, enforced in `handle_connection_with_stop`:
connections from a different UID are dropped before the first request is
read. Fails closed — unknown credentials are rejected. Pane children inherit
the socket path and run as the same UID, so they are unaffected. (The socket
file was already created mode 0600.)

### Remote manifest catalog: deleted (`src/detect/manifest_update.rs`)

Risk-review item 1. The curl-based catalog fetch
(`https://herdr.dev/agent-detection/index.toml`) is gone:
`check_and_update_from_url`, `fetch_text`, `catalog_url`, `base_url`,
`join_url`, and the `HERDR_AGENT_DETECTION_MANIFEST_CATALOG_URL` env-var
override were deleted. `check_and_update()` now returns a disabled error;
`auto_update()` reports the disabled state. Manifests are frozen at the
vendored set in `src/detect/manifests/`; the state vocabulary
(working/blocked/done/idle/unknown) and `pane.agent_status_changed` events are
fed by trusted self-reports (`pane.report_agent*`). Three obsolete
network-update tests were replaced with
`auto_update_is_disabled_in_demigod_build`. Background manifest checks are
disabled in `src/app/runtime.rs` (`run_agent_manifest_update_check` is a
no-op), at app construction and across config reloads (`src/app/mod.rs`).

### Self-updater: disabled (`src/update.rs`, `src/app/runtime.rs`, `src/main.rs`)

Risk-review item 2. `update::self_update` always returns
"self-update is disabled in this build"; `update::auto_update` is a no-op;
`run_auto_update_check` is a no-op; construction and config-reload paths
force the checks off. `herdr update` and `herdr channel` are refused at the
CLI entry point. The pinned binary is deployed and updated by the operator,
never by the process itself. `product_announcements::load_unseen_for_current_version`
now returns `None` (no announcement content is ever loaded or shown).

### TUI entry points: refused (`src/main.rs`)

The interactive TUI is disabled. `herdr server` runs the headless session
server; every other entry path refuses with a clear error: bare `herdr`
(TUI launch via `autodetect::auto_detect_launch`), `herdr client`,
`herdr --remote`, `herdr --machine`, `herdr machine`,
`herdr remote-api-bridge`, `herdr remote-client-bridge`. The CLI subcommands
that are thin wrappers over the JSON socket API (`status`, `pane`, `agent`,
`session`, `workspace`, `tab`, `api`, …) still work. `--help` notes the
demigod build. Sound/toast forwarding code remains in-tree but is unreachable:
there is no foreground client in a headless-only binary, and
`notification.show` is removed from the socket API.

### SSH federation: default-off (`src/api/server.rs`, `src/platform/ssh_agent.rs`, `src/main.rs`)

The `SshAgentRegistry` (ssh-agent bridging into panes) is only created when
`DEMIGOD_SSH_AGENT_REGISTRATION=1`; otherwise `server.ssh_agent.register`
reports unavailable and `apply_pane_env` injects no `SSH_AUTH_SOCK`.
`--remote`, `--machine`, `machine`, and the remote bridge subcommands are
refused (see above).

### `agent.start`: deny-by-default gate (`src/app/agents.rs`, `src/agent_resume.rs`)

Risk-review item 7. `agent.start` types a command into a pane's shell, so
caller-controlled argv is a command-injection surface. Now:
- The agent kind must be allowlisted via `DEMIGOD_AGENT_KIND_ALLOWLIST`
  (comma-separated canonical kind labels, e.g. `claude,codex`). Unset or
  empty = every kind rejected with `agent_kind_not_allowed`.
- Caller args must pass `validate_resume_flags`: only allowlisted flags
  (`DEMIGOD_RESUME_FLAG_ALLOWLIST`, default
  `--resume,-r,--continue,-c,--session-id,--session,--conversation-id`) and
  their values; anything else is rejected with `forbidden_agent_argument`.
  This is the fork-side enforcement for the bridge's "adapter-constructed
  argv from allowlisted kinds" rule — the bridge must set both env vars.

### `pane.report_agent_session` validation tightened (`src/agent_resume.rs`)

Risk-review item 13. The existing caps (≤64 args, 8 KiB, no control chars,
plain command name) are kept, plus: the command must be an allowlisted agent
CLI (`DEMIGOD_RESUME_CLI_ALLOWLIST`, default: claude, codex, opencode,
gemini, cursor-agent, copilot, amp, aichat, qwen, kimi, grok, hermes, droid,
pi) and args must be allowlisted resume flags with values. Applies to the
`pane.report_agent_session` socket path and to session-restore filtering, so
a compromised reporter cannot smuggle arbitrary agent-CLI flags (e.g.
permission bypasses) through restore. Tests updated.

### Pane env scrub (`src/integration/env.rs`)

Risk-review item 12. `apply_pane_base_env` now removes any inherited
`HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV`, `HERDR_PANE_ID`,
`HERDR_TAB_ID`, `HERDR_WORKSPACE_ID` from the operator environment before the
server sets its own values — a poisoned operator env can no longer redirect
panes to a foreign socket or binary. (Explicitly-passed launch env via
`tab.create`/`pane.split` `env` params is unchanged; the bridge allowlists
what it sends.)

### `pane_history`: opt-in removed (`src/app/mod.rs`)

Risk-review item 3. `persist_pane_history` is now hard-wired `false` at
construction and across config reloads (with `persist::clear_history()`); the
`[experimental] pane_history` config knob is ignored. Persisted screen
scrollback is a secrets store on disk.

### New environment variables (operator surface)

| Variable | Default | Effect |
|---|---|---|
| `DEMIGOD_AGENT_KIND_ALLOWLIST` | _(empty = deny all)_ | Kinds permitted for `agent.start` |
| `DEMIGOD_AGENT_FLAG_ALLOWLIST` | `--resume,-r,--continue,-c,--session-id,--session,--conversation-id` | Flags permitted in `agent.start` args |
| `DEMIGOD_RESUME_CLI_ALLOWLIST` | claude, codex, opencode, gemini, cursor-agent, copilot, amp, aichat, qwen, kimi, grok, hermes, droid, pi | CLIs accepted in `pane.report_agent_session` resume argv |
| `DEMIGOD_RESUME_FLAG_ALLOWLIST` | same as agent flag default | Flags permitted in resume argv |
| `DEMIGOD_SSH_AGENT_REGISTRATION` | _(unset = off)_ | Set `1` to enable ssh-agent bridging |

### Notes / residual

- `herdr.dev` URLs remain only in comments, the vendored manifest sources,
  and `--help` text. The server process makes no outbound network
  connections except those initiated by pane children.
- `distribution/latest.json` / `distribution/preview.json` and the release
  workflows are untouched; releases of this fork are operator-run.
- The vendored `portable-pty` and `ghostty-vt` patches are untouched.
- `cargo audit` / `cargo deny` in CI: not yet wired (queued follow-up).

### Dead-code cleanup after the strip (same date)

Removing the callers orphaned a number of functions. Kept-vs-deleted:

- **Deleted**: `session::stop_active_server` (only caller was the removed
  `server stop` path); `platform::local_stream_peer_description` (only
  caller was the removed `server.stop` logging).
- **Kept for unit tests**, with `#[allow(dead_code)]` + explanatory
  comments per this repo's convention: the update machinery in
  `src/update.rs` (module-wide), `src/product_announcements.rs`
  (module-wide), `src/release_notes.rs` (module-wide),
  `manifest_update::{auto_update, save_status, now_unix}`,
  `detect::manifest::reload_manifests_for_agents`,
  `events::{UpdateReady, AgentDetectionManifestsUpdated}`,
  `logging::{update_check_started, update_check_failed, update_available}`,
  `platform::{socket_peer_pid, process_name_and_parent}` (linux/macos/
  fallback; their only caller was the deleted peer-description helper).
- The `HERDR_AGENT_DETECTION_MANIFEST_CATALOG_URL` env-var constant was
  removed outright (the override no longer exists); the disabled-behavior
  test uses the literal name.
- `src/platform/mod.rs`: `#[allow(unused_imports)]` on the `pub use linux::*;`
  glob — rustc false-positives on it (the names resolve through
  `crate::platform::`; deleting it breaks the build), documented inline.

---

## Attribution

Original work: herdrdev/herdr, Apache License 2.0. This fork's changes are
likewise Apache-2.0. `LICENSE`, `SPONSORS.md`, and copyright notices are
unchanged.
