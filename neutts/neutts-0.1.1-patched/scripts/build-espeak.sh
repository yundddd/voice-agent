#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/build-espeak.sh
#
# Build a static libespeak-ng and cache it under
#   <crate-root>/espeak-static/lib/
#
# Supported targets:
#   • macOS arm64 / x86_64    (native; merges with libtool -static)
#   • Linux x86_64 / aarch64  (native; merges with ar MRI script)
#   • Windows x86_64-gnu      (cross-compile from Linux/macOS with MinGW-w64;
#                               set CROSS_TARGET=x86_64-w64-mingw32)
#
# For native Windows MSVC builds use scripts\build-espeak-windows.ps1 instead.
#
# ── Environment variables ─────────────────────────────────────────────────────
#   ESPEAK_VERSION    espeak-ng release tag (default: 1.52.0)
#   BUILD_DIR         temporary build root (default: <system tmpdir>/espeak-build-$$)
#   CROSS_TARGET      MinGW target triple for cross-compile
#                     e.g. x86_64-w64-mingw32
#   CMAKE_EXTRA_ARGS  extra flags passed verbatim to cmake configure
#   JOBS              parallel build jobs (default: nproc / sysctl)
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   # Native build
#   bash scripts/build-espeak.sh
#
#   # Cross-compile to Windows-GNU from Linux (requires gcc-mingw-w64-x86-64)
#   CROSS_TARGET=x86_64-w64-mingw32 bash scripts/build-espeak.sh
#
# After running, set ESPEAK_LIB_DIR or let build.rs find the cache:
#   cargo build --features espeak
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ESPEAK_VERSION="${ESPEAK_VERSION:-1.52.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$CRATE_ROOT/espeak-static"
TARBALL_URL="https://github.com/espeak-ng/espeak-ng/archive/refs/tags/${ESPEAK_VERSION}.tar.gz"

# Temporary build tree — using a system tmpdir keeps paths short.
TMP_ROOT="${BUILD_DIR:-$(mktemp -d -t espeak-build-XXXX 2>/dev/null || mktemp -d)}"
SRC_DIR="$TMP_ROOT/src"
BLD_DIR="$TMP_ROOT/bld"
INST_DIR="$TMP_ROOT/inst"
TARBALL="$TMP_ROOT/espeak-${ESPEAK_VERSION}.tar.gz"

JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
CROSS_TARGET="${CROSS_TARGET:-}"
CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS:-}"

LIB_DIR="$OUT_DIR/lib"
MERGED_LIB="$LIB_DIR/libespeak-ng-merged.a"
STAMP_FILE="$LIB_DIR/libespeak-ng-merged.stamp"

# ── Colour helpers ─────────────────────────────────────────────────────────────
step()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
warn()  { printf '  \033[33m⚠ %s\033[0m\n' "$*" >&2; }
die()   { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── Detect host OS ─────────────────────────────────────────────────────────────
HOST_OS="$(uname -s)"

# ── Cross-compile toolchain ────────────────────────────────────────────────────
if [[ -n "$CROSS_TARGET" ]]; then
    CC="${CROSS_TARGET}-gcc"
    CXX="${CROSS_TARGET}-g++"
    AR="${CROSS_TARGET}-ar"
    RANLIB="${CROSS_TARGET}-ranlib"
    RC="${CROSS_TARGET}-windres"
    TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/mingw-toolchain.cmake"

    step "Cross-compilation → $CROSS_TARGET"
    for tool in "$CC" "$CXX" "$AR"; do
        if ! command -v "$tool" &>/dev/null; then
            die "$tool not found.  Install MinGW-w64:
  Ubuntu:   sudo apt install gcc-mingw-w64-x86-64
  Fedora:   sudo dnf install mingw64-gcc-c++
  macOS:    brew install mingw-w64"
        fi
        ok "$tool: $(command -v "$tool")"
    done

    MERGED_LIB="$LIB_DIR/libespeak-ng-merged.a"  # MinGW still uses .a
    EXTRA_CMAKE=(
        "-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN_FILE"
        "-DCMAKE_C_COMPILER=$CC"
        "-DCMAKE_CXX_COMPILER=$CXX"
        "-DCMAKE_RC_COMPILER=$RC"
        "-DMINGW_PREFIX=${CROSS_TARGET}-"
        "-DESPEAK_CROSS_PREFIX=${CROSS_TARGET}-"
    )
    # Ninja works on all hosts and avoids GNU make recursive issues.
    if command -v ninja &>/dev/null; then
        EXTRA_CMAKE+=("-GNinja")
    fi
else
    AR="ar"
    RANLIB="ranlib"
    EXTRA_CMAKE=()
    if [[ "$HOST_OS" == Darwin ]]; then
        # Prefer Ninja on macOS too (avoids Xcode generator surprises).
        if command -v ninja &>/dev/null; then
            EXTRA_CMAKE+=("-GNinja")
        fi
    fi
fi

# ── Already built? ─────────────────────────────────────────────────────────────
step "Checking for cached build"
if [[ -f "$MERGED_LIB" && -f "$STAMP_FILE" ]] && \
   grep -q "^${ESPEAK_VERSION}$" "$STAMP_FILE" 2>/dev/null; then
    ok "Already built: $MERGED_LIB"
    echo "  (delete espeak-static/ to force a rebuild)"
    exit 0
fi
# Clean stale merged lib.
rm -f "$MERGED_LIB" "$STAMP_FILE"

# ── Prerequisites ──────────────────────────────────────────────────────────────
step "Checking prerequisites"
for tool in cmake git; do
    if ! command -v "$tool" &>/dev/null; then
        die "$tool not found.  macOS: brew install $tool  |  Ubuntu: sudo apt install $tool"
    fi
    ok "$tool: $(command -v "$tool")"
done

# ── Create directories ─────────────────────────────────────────────────────────
mkdir -p "$SRC_DIR" "$BLD_DIR" "$INST_DIR" "$LIB_DIR"
trap 'echo "Cleaning up $TMP_ROOT…"; rm -rf "$TMP_ROOT"' EXIT

# ── Download + extract ─────────────────────────────────────────────────────────
step "Fetching espeak-ng $ESPEAK_VERSION"
if [[ ! -f "$TARBALL" ]]; then
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$TARBALL" "$TARBALL_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O "$TARBALL" "$TARBALL_URL"
    else
        die "Neither curl nor wget found."
    fi
fi

if [[ ! -f "$SRC_DIR/CMakeLists.txt" ]]; then
    tar -xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1
fi
ok "Source ready: $SRC_DIR"

# ── cmake configure ────────────────────────────────────────────────────────────
step "CMake configure"
cmake \
    -S "$SRC_DIR" \
    -B "$BLD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INST_DIR" \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_MBROLA=OFF \
    -DUSE_LIBSONIC=OFF \
    -DUSE_LIBPCAUDIO=OFF \
    -DUSE_ASYNC=OFF \
    "${EXTRA_CMAKE[@]}" \
    ${CMAKE_EXTRA_ARGS} \
    || die "cmake configure failed."

# ── cmake build ───────────────────────────────────────────────────────────────
step "CMake build ($JOBS threads)"
cmake --build "$BLD_DIR" --config Release --parallel "$JOBS" \
    || die "cmake build failed."

# ── cmake install (headers + data; .a install may be skipped by cmake) ────────
step "Installing headers and data"
cmake --install "$BLD_DIR" || true  # non-fatal: we copy libs manually below

# ── Collect archives ───────────────────────────────────────────────────────────
step "Collecting static archives"
mapfile -t ALL_LIBS < <(find "$BLD_DIR" -name "*.a" 2>/dev/null | sort)

if [[ ${#ALL_LIBS[@]} -eq 0 ]]; then
    die "No .a files found after cmake build in $BLD_DIR"
fi

for lib in "${ALL_LIBS[@]}"; do
    name="$(basename "$lib")"
    dest="$LIB_DIR/$name"
    cp "$lib" "$dest"
    ok "$(basename "$lib")  ($( du -sh "$lib" | cut -f1 ))"
done

# ── Merge into one fat archive ─────────────────────────────────────────────────
step "Merging ${#ALL_LIBS[@]} archive(s) → libespeak-ng-merged.a"

if [[ "$HOST_OS" == Darwin && -z "$CROSS_TARGET" ]]; then
    # macOS native: libtool -static is always available with Xcode CLT.
    libtool -static -o "$MERGED_LIB" "${ALL_LIBS[@]}" \
        || die "libtool merge failed."
else
    # Linux / cross to Windows-GNU: use ar MRI script.
    {
        echo "CREATE $MERGED_LIB"
        for lib in "${ALL_LIBS[@]}"; do echo "ADDLIB $lib"; done
        echo "SAVE"
        echo "END"
    } | "$AR" -M || die "ar MRI merge failed."
fi

ok "Merged: $MERGED_LIB  ($( du -sh "$MERGED_LIB" | cut -f1 ))"

# ── Copy espeak-ng-data ────────────────────────────────────────────────────────
DATA_DEST="$OUT_DIR/share/espeak-ng-data"
if [[ ! -d "$DATA_DEST" ]]; then
    for candidate in \
        "$INST_DIR/share/espeak-ng-data" \
        "$SRC_DIR/espeak-ng-data" \
        "$BLD_DIR/espeak-ng-data"; do
        if [[ -d "$candidate" ]]; then
            mkdir -p "$OUT_DIR/share"
            cp -r "$candidate" "$DATA_DEST"
            ok "espeak-ng-data → $DATA_DEST"
            break
        fi
    done
fi

# ── Stamp ──────────────────────────────────────────────────────────────────────
echo "$ESPEAK_VERSION" > "$STAMP_FILE"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────"
if [[ -n "$CROSS_TARGET" ]]; then
    echo "  espeak-ng $ESPEAK_VERSION for $CROSS_TARGET ready!"
else
    echo "  espeak-ng $ESPEAK_VERSION ready!"
fi
echo ""
echo "  Library : $MERGED_LIB"
[[ -d "$DATA_DEST" ]] && echo "  Data    : $DATA_DEST"
echo ""
echo "  Build with:"
echo "    cargo build --features espeak"
echo ""
echo "  Or set explicitly:"
echo "    ESPEAK_LIB_DIR=$LIB_DIR cargo build --features espeak"
echo "────────────────────────────────────────────────────"
