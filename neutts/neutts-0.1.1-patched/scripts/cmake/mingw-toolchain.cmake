# cmake/mingw-toolchain.cmake
#
# CMake cross-compilation toolchain for targeting Windows (x86_64-pc-windows-gnu)
# from a Linux or macOS host using MinGW-w64.
#
# ── Install MinGW-w64 ─────────────────────────────────────────────────────────
#   Ubuntu / Debian:  sudo apt install gcc-mingw-w64-x86-64
#   Fedora:           sudo dnf install mingw64-gcc-c++
#   macOS:            brew install mingw-w64
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   cmake -S src -B bld \
#         -DCMAKE_TOOLCHAIN_FILE=scripts/cmake/mingw-toolchain.cmake
#
# Override the prefix via the ESPEAK_CROSS_PREFIX env var (build.rs) or the
# MINGW_PREFIX cmake variable:
#   cmake ... -DMINGW_PREFIX=i686-w64-mingw32-   # 32-bit Windows
# ─────────────────────────────────────────────────────────────────────────────

# Target system
set(CMAKE_SYSTEM_NAME    Windows)
set(CMAKE_SYSTEM_VERSION 10)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Toolchain prefix — override with -DMINGW_PREFIX=... or ESPEAK_CROSS_PREFIX env.
if(NOT DEFINED MINGW_PREFIX)
    if(DEFINED ENV{ESPEAK_CROSS_PREFIX})
        set(MINGW_PREFIX "$ENV{ESPEAK_CROSS_PREFIX}")
    else()
        set(MINGW_PREFIX "x86_64-w64-mingw32-")
    endif()
endif()

# Compilers
find_program(CMAKE_C_COMPILER   NAMES "${MINGW_PREFIX}gcc"   REQUIRED)
find_program(CMAKE_CXX_COMPILER NAMES "${MINGW_PREFIX}g++"   REQUIRED)
find_program(CMAKE_RC_COMPILER  NAMES "${MINGW_PREFIX}windres" NO_CMAKE_FIND_ROOT_PATH)

# Archiver and related tools — used by build.rs's merge step.
find_program(CMAKE_AR      NAMES "${MINGW_PREFIX}ar"      REQUIRED)
find_program(CMAKE_RANLIB  NAMES "${MINGW_PREFIX}ranlib"  REQUIRED)
find_program(CMAKE_LINKER  NAMES "${MINGW_PREFIX}ld"      REQUIRED)
find_program(CMAKE_NM      NAMES "${MINGW_PREFIX}nm"      REQUIRED)
find_program(CMAKE_OBJDUMP NAMES "${MINGW_PREFIX}objdump" REQUIRED)
find_program(CMAKE_STRIP   NAMES "${MINGW_PREFIX}strip"   REQUIRED)

# Search for libraries/programs in the sysroot, not the host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# Disable features that require a running executable (cross-compile safe).
set(CMAKE_CROSSCOMPILING_EMULATOR "")
