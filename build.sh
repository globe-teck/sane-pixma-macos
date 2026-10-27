#!/bin/sh
# Build the SANE pixma backend and scanimage from a pinned sane-backends
# release into a user prefix on macOS. No sudo. Safe to run again.
#
#   ./build.sh                 # build into $HOME/sane
#   PREFIX=/opt/me/sane ./build.sh
#   ./build.sh --force         # rebuild even if the same version is installed
#   ./build.sh --no-brew       # don't install Homebrew packages
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SANE_VERSION="1.4.0"
SANE_SHA256="f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72"  # pragma: allowlist secret (public release sha256)
SANE_URL="https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-${SANE_VERSION}.tar.gz"

PREFIX="${PREFIX:-$HOME/sane}"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/sane-pixma-build}"
BREW_DEPS="libusb jpeg-turbo libtiff libpng pkg-config"
FORCE=0
USE_BREW=1

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --no-brew) USE_BREW=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'build.sh: error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "don't run this as root; it installs into a user prefix"
[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS"

STAMP="$PREFIX/.sane-pixma-build"
WANT="version=$SANE_VERSION backends=pixma pthread=yes"
if [ "$FORCE" -eq 0 ] && [ -x "$PREFIX/bin/scanimage" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
  say "sane-backends $SANE_VERSION (pixma, pthread) is already installed in $PREFIX; use --force to rebuild"
  exit 0
fi

if [ "$USE_BREW" -eq 1 ]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew not found; install it or use --no-brew with the deps already present"
  for pkg in $BREW_DEPS; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      say "brew: $pkg already installed"
    else
      say "brew install $pkg"
      brew install "$pkg"
    fi
  done
  BREW_PREFIX="$(brew --prefix)"
  CPPFLAGS="-I$BREW_PREFIX/include ${CPPFLAGS:-}"
  LDFLAGS="-L$BREW_PREFIX/lib ${LDFLAGS:-}"
  PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:$(brew --prefix jpeg-turbo)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CPPFLAGS LDFLAGS PKG_CONFIG_PATH
  CPPFLAGS="-I$(brew --prefix jpeg-turbo)/include $CPPFLAGS"
  LDFLAGS="-L$(brew --prefix jpeg-turbo)/lib $LDFLAGS"
fi

mkdir -p "$WORKDIR"
TARBALL="$WORKDIR/sane-backends-$SANE_VERSION.tar.gz"

sha_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$SANE_SHA256" ]; }

if sha_ok "$TARBALL"; then
  say "using cached $TARBALL (sha256 ok)"
else
  say "downloading sane-backends $SANE_VERSION"
  rm -f "$TARBALL.part"
  curl --proto '=https' --tlsv1.2 -fSL --retry 3 -o "$TARBALL.part" "$SANE_URL"
  sha_ok "$TARBALL.part" || { rm -f "$TARBALL.part"; die "sha256 mismatch for the downloaded tarball"; }
  mv "$TARBALL.part" "$TARBALL"
fi

SRC="$WORKDIR/sane-backends-$SANE_VERSION"
rm -rf "$SRC"
tar -xzf "$TARBALL" -C "$WORKDIR"
cd "$SRC"

say "configure (pixma only, pthread reader, prefix $PREFIX)"
BACKENDS="pixma" ./configure \
  --prefix="$PREFIX" \
  --enable-pthread \
  --disable-nls \
  --disable-locking \
  --with-usb \
  --without-snmp \
  --without-avahi \
  --without-gphoto2 \
  --without-v4l \
  --without-systemd >"$WORKDIR/configure.log" 2>&1 || {
    tail -40 "$WORKDIR/configure.log" >&2; die "configure failed (full log: $WORKDIR/configure.log)"; }

# sanei_thread runs the pixma reader in a forked child process unless
# USE_PTHREAD is defined. Upstream's 1.3.1 notes say SANE on macOS doesn't
# work multi-process with libusb, so make sure the thread path is used.
CONFIG_H="include/sane/config.h"
if grep -q '^#define USE_PTHREAD' "$CONFIG_H"; then
  say "USE_PTHREAD is defined by configure"
else
  say "configure did not define USE_PTHREAD; forcing it in $CONFIG_H"
  printf '\n/* forced by sane-pixma-macos build.sh */\n#define USE_PTHREAD "yes"\n' >>"$CONFIG_H"
fi

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
say "make -j$JOBS"
make -j"$JOBS" >"$WORKDIR/make.log" 2>&1 || { tail -40 "$WORKDIR/make.log" >&2; die "make failed (full log: $WORKDIR/make.log)"; }
say "make install"
make install >"$WORKDIR/install.log" 2>&1 || { tail -40 "$WORKDIR/install.log" >&2; die "make install failed"; }

# Keep only pixma in dll.conf so scanimage doesn't probe other backends.
DLL_CONF="$PREFIX/etc/sane.d/dll.conf"
if [ -f "$DLL_CONF" ] && ! grep -qx 'pixma' "$DLL_CONF"; then
  printf 'pixma\n' >>"$DLL_CONF"
fi

DYLD_LIBRARY_PATH="$PREFIX/lib" SANE_CONFIG_DIR="$PREFIX/etc/sane.d" "$PREFIX/bin/scanimage" --version
printf '%s\n' "$WANT" >"$STAMP"
say "done. Try: $SCRIPT_DIR/bin/scan --list"
