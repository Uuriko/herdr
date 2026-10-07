# Demigod pinned herdr packaging

Pinned, verifiable distribution of the herdr fork binary for Project Room's
session adapter. No `latest` fetch, no auto-update — upgrades are lane-claimed,
never automatic (REDESIGN.md §2.4).

## Layout

- `install.sh` — pinned installer. Downloads ONLY the artifacts listed below
  from this fork's `demigod/pkg-v1` GitHub release, verifies SHA-256 against
  an embedded pin table (mirrors `pinned-herdr.json`; CI fails on drift),
  refuses on mismatch, then smoke-tests version + socket protocol (22).
- `pinned-herdr.json` — machine-readable pin manifest. The coordinator wires
  its content into `server/session-adapter/pinned-herdr.json` at integration.
- `artifacts/` — scratch copies used at pin time (NOT shipped; see provenance).

## Pin (demigod/pkg-v1)

- herdrVersion: `0.9.3`, protocolVersion: `22`
- forkCommit: `a124eed73c1f911ddf89a6ac5b2f7ab70d76f5c2`
  (Uuriko/herdr master at pin time, 2026-10-06; B1's strip not yet landed —
  tree is byte-identical to upstream master at this commit)
- Release: https://github.com/Uuriko/herdr/releases/tag/demigod/pkg-v1

## Artifact provenance

| artifact | built from | provenance |
|---|---|---|
| `herdr-linux-x86_64` | fork @ a124eed7, Rust 1.96.1, `cargo build --release --locked` | fork-source-build |
| `herdr-linux-aarch64` | fork @ a124eed7, Rust 1.96.1, `cargo build --release --locked --target aarch64-unknown-linux-gnu` (zig 0.16.0 cc as cross linker; zig 0.16.0 also required by the vendored libghostty-vt build) | fork-source-build |
| `herdr-macos-x86_64` | upstream v0.9.3 release asset, SHA-256 verified against upstream `distribution/latest.json` | upstream-release-verified (interim) |
| `herdr-macos-aarch64` | upstream v0.9.3 release asset, SHA-256 verified against upstream `distribution/latest.json` | upstream-release-verified (interim) |

macOS binaries are republished from upstream's signed release (Apache-2.0
redistribution) because macOS builds require the Apple SDK, unavailable on the
build host. They are checksummed and pinned like everything else; replacing
them with fork-built binaries is a future lane claim. Upstream v0.9.3 ==
protocol 22, same protocol as the fork pin.

## Rebuild from source (pinned-source rebuild path)

```bash
# pinned toolchain (rust-toolchain.toml)
rustup toolchain install 1.96.1
git checkout a124eed73c1f911ddf89a6ac5b2f7ab70d76f5c2
cargo build --release --locked          # linux-x86_64
# linux-aarch64: cargo + zig 0.16.0 cc as the cross linker
cargo build --release --locked --target aarch64-unknown-linux-gnu
```

Verify: `sha256sum target/release/herdr target/aarch64-unknown-linux-gnu/release/herdr`,
then `./herdr --version` and the protocol gate in `install.sh` (`ping` → `protocol: 22`).

## Repin procedure (for the next lane)

1. New fork commit lands (e.g. B1's strip).
2. Rebuild all fork-source artifacts, recompute SHA-256.
3. Update `install.sh` pin table AND `pinned-herdr.json` together.
4. Upload to a new `demigod/pkg-vN` release; never overwrite an existing tag's assets.
5. CI check: install.sh table vs pinned-herdr.json must match exactly.
