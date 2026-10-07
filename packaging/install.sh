#!/usr/bin/env bash
# install.sh — pinned herdr fork installer (Demigod / Project Room).
#
# Downloads ONLY the pinned release artifacts from our fork's GitHub release,
# verifies SHA-256 against the embedded pin table (no network trust beyond the
# release host), and refuses on any mismatch. There is deliberately NO
# "latest" fetch and NO auto-update: upgrades are lane-claimed, never automatic.
#
# Usage:
#   packaging/install.sh [--dir DIR] [--platform PLAT] [--no-smoke]
# Platforms: linux-x86_64 | linux-aarch64 | darwin-x86_64 | darwin-aarch64
#
# Exit codes: 0 ok · 1 checksum/platform/download failure · 2 usage error.

set -euo pipefail

PIN_TAG="demigod/pkg-v1"
RELEASE_BASE="https://github.com/Uuriko/herdr/releases/download/${PIN_TAG}"
FORK_COMMIT="a124eed73c1f911ddf89a6ac5b2f7ab70d76f5c2"
EXPECTED_PROTOCOL="22"
EXPECTED_VERSION="0.9.3"

# Pinned SHA-256 per artifact file name. Source of truth for verification.
# Mirrors packaging/pinned-herdr.json (CI fails if the two drift).
declare -A PIN_SHA256=(
  ["herdr-linux-x86_64"]="36558bce438b49f0d479554b2cc619c8535ea7d48971c2aa4b6f33768c683f58"
  ["herdr-linux-aarch64"]="7be04800ee52336005397d5889ca76d6d7d677684963f3cd05e43d340e2d55bc"
  ["herdr-macos-x86_64"]="db62d548ff3e832b087a96b1894a08d26be3905f1830309cd556783f215d4054"
  ["herdr-macos-aarch64"]="5173a3e0ae42d5d1ab7ebfa5d5e6329f7c3d23f8e1a3677c7ce3231da2884157"
)

DEST_DIR="${HOME}/.local/bin"
PLATFORM=""
SMOKE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        DEST_DIR="${2:?}"; shift 2 ;;
    --platform)   PLATFORM="${2:?}"; shift 2 ;;
    --no-smoke)   SMOKE=0; shift ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) echo "unsupported OS: $os" >&2; exit 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported arch: $arch" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

[ -z "$PLATFORM" ] && PLATFORM="$(detect_platform)"

case "$PLATFORM" in
  linux-x86_64)   FILE="herdr-linux-x86_64" ;;
  linux-aarch64)  FILE="herdr-linux-aarch64" ;;
  darwin-x86_64)  FILE="herdr-macos-x86_64" ;;
  darwin-aarch64) FILE="herdr-macos-aarch64" ;;
  *) echo "unsupported platform: $PLATFORM" >&2; exit 1 ;;
esac

EXPECTED_SHA="${PIN_SHA256[$FILE]:-}"
if [ -z "$EXPECTED_SHA" ] || [[ "$EXPECTED_SHA" == __SHA* ]]; then
  echo "FATAL: no pinned checksum for $FILE — install.sh pin table incomplete" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="${RELEASE_BASE}/${FILE}"
echo "downloading pinned artifact: ${URL}"
if ! curl -fsSL --retry 3 --max-time 300 -o "${TMP}/${FILE}" "$URL"; then
  echo "FATAL: download failed: ${URL}" >&2
  exit 1
fi

ACTUAL_SHA="$(sha256sum "${TMP}/${FILE}" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "FATAL: checksum mismatch for ${FILE}" >&2
  echo "  expected: ${EXPECTED_SHA}" >&2
  echo "  actual:   ${ACTUAL_SHA}" >&2
  echo "refusing to install." >&2
  exit 1
fi
echo "checksum OK: ${ACTUAL_SHA}"

install -m 0755 "${TMP}/${FILE}" "${DEST_DIR}/herdr"
echo "installed: ${DEST_DIR}/herdr"

if [ "$SMOKE" -eq 1 ]; then
  echo "smoke: version + protocol gate..."
  VER="$("${DEST_DIR}/herdr" --version 2>/dev/null | head -1 || true)"
  echo "  binary reports: ${VER}"
  case "$VER" in
    *"${EXPECTED_VERSION}"*) ;;
    *) echo "FATAL: version gate failed (expected ${EXPECTED_VERSION} in '${VER}')" >&2; exit 1 ;;
  esac

  # Protocol gate: start a throwaway server, ping it, require protocol 22.
  SMOKE_HOME="$(mktemp -d)"
  export XDG_CONFIG_HOME="$SMOKE_HOME"
  SOCK="${SMOKE_HOME}/herdr/herdr.sock"
  "${DEST_DIR}/herdr" server >/dev/null 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
  if [ ! -S "$SOCK" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    echo "FATAL: smoke server did not create socket" >&2; exit 1
  fi
  PONG="$(printf '{"id":"pin-smoke","method":"ping","params":{}}\n' | \
    timeout 10 python3 -c "
import json,sys,socket
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read())
buf=b''
while b'\n' not in buf: buf+=s.recv(4096)
print(buf.decode().strip())" "$SOCK" 2>/dev/null || true)"
  kill "$SRV_PID" 2>/dev/null || true
  wait "$SRV_PID" 2>/dev/null || true
  rm -rf "$SMOKE_HOME"
  PROTO="$(printf '%s' "$PONG" | python3 -c "
import json,sys
try:
    r=json.loads(sys.stdin.read()); print(r['result']['protocol'])
except Exception: print('')" 2>/dev/null || true)"
  if [ "$PROTO" != "$EXPECTED_PROTOCOL" ]; then
    echo "FATAL: protocol gate failed (server=${PROTO:-none} expected=${EXPECTED_PROTOCOL})" >&2
    exit 1
  fi
  echo "protocol OK: ${PROTO}"
fi

echo "done. fork commit: ${FORK_COMMIT}"
