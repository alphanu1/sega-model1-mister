#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Install Quartus Prime Lite 17.0.2 alongside any newer Quartus, unattended.
#
#   tools/install-quartus17.sh <installer> [installdir]
#
# <installer> is either:
#   Quartus-lite-17.0.2.602-linux.tar        combined archive, all devices
#   QuartusLiteSetup-17.0.2.602-linux.run    base installer; the Cyclone V
#                                            device file cyclonev-17.0.2.602.qdz
#                                            must sit in the SAME directory
#
# Default installdir is ~/intelFPGA_lite/17.0, which is where the Makefile's
# auto-detection looks. Versions live in separate trees and do not interfere;
# select one with `make quartus QUARTUS=17.0`.
#
# WHY 17.0.x AT ALL: MiSTer's sys/ ships pre-generated Altera PLL IP for
# Quartus 13.1 and 17.0 only — third_party/template/sys/pll_q13.qip and
# pll_q17.qip. Opening that project in a newer Quartus forces an IP upgrade
# that regenerates the video PLLs. The M0 spike does not use sys/ and builds
# fine on anything supporting Cyclone V, but M1 onwards needs 17.0.x.
#
# The installer cannot be fetched automatically: Altera's CDN returns 403 to
# unauthenticated requests, so the download needs a signed-in browser session.

set -euo pipefail

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

SRC="${1:-}"
DEST="${2:-$HOME/intelFPGA_lite/17.0}"

[ -n "$SRC" ] || die "usage: $0 <installer .tar or .run> [installdir]"
[ -f "$SRC" ] || die "not a file: $SRC"

SRC="$(readlink -f "$SRC")"
SRCDIR="$(dirname "$SRC")"

say "== target"
echo "  installer $SRC"
echo "  installdir $DEST"

if [ -x "$DEST/quartus/bin/quartus_map" ]; then
  warn "  already installed at $DEST — nothing to do"
  "$DEST/quartus/bin/quartus_map" --version 2>/dev/null | head -2
  exit 0
fi

# Quartus 17.0 is a 2017 build. The command-line tools this project uses
# (quartus_map/fit/sta) generally run on a current distro; the GUI is where old
# library dependencies bite. Report rather than fail — the flow never opens it.
say "== host libraries"
for l in libpng12.so.0 libfreetype.so.6; do
  if ldconfig -p 2>/dev/null | grep -q "$l"; then echo "  $l present"
  else warn "  $l MISSING — only affects the GUI, not quartus_map/fit/sta"; fi
done

RUN=""
CLEAN=""
case "$SRC" in
  *.tar)
    say "== extracting archive"
    TMP="$(mktemp -d)"; CLEAN="$TMP"
    tar -xf "$SRC" -C "$TMP"
    RUN="$(find "$TMP" -maxdepth 2 -name 'setup.sh' -o -maxdepth 2 -name '*Setup*.run' | head -1)"
    [ -n "$RUN" ] || die "no setup.sh or *Setup*.run inside $SRC"
    chmod +x "$RUN" 2>/dev/null || true
    ;;
  *.run)
    RUN="$SRC"
    chmod +x "$RUN" 2>/dev/null || true
    # The base .run installs devices from .qdz files sitting beside it.
    if ! ls "$SRCDIR"/cyclonev-*.qdz >/dev/null 2>&1; then
      warn "  no cyclonev-*.qdz next to the installer"
      warn "  Cyclone V support will be missing and 5CSEBA6U23I7 will not build."
      warn "  Download the Cyclone V device file into $SRCDIR and rerun."
    else
      echo "  device file: $(ls "$SRCDIR"/cyclonev-*.qdz | head -1)"
    fi
    ;;
  *) die "expected a .tar or .run installer, got $SRC" ;;
esac

say "== installing (unattended, this takes a while)"
mkdir -p "$DEST"
"$RUN" --mode unattended --installdir "$DEST" --accept_eula 1 \
  --disable-components quartus_help,questa_fse,questa_fe 2>&1 | tail -20 || true

[ -n "$CLEAN" ] && rm -rf "$CLEAN"

say "== verify"
if [ -x "$DEST/quartus/bin/quartus_map" ]; then
  "$DEST/quartus/bin/quartus_map" --version 2>&1 | head -3
  if [ -d "$DEST/quartus/common/devinfo/cyclonev" ]; then
    echo "  cyclonev devinfo present"
  else
    warn "  cyclonev devinfo MISSING — 5CSEBA6U23I7 will not build"
  fi
  echo
  say "next"
  echo "  make quartus_list"
  echo "  make quartus MOD=mb86233_alu QUARTUS=17.0"
else
  die "install failed: no $DEST/quartus/bin/quartus_map"
fi
