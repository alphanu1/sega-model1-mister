#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Install Quartus Prime Lite 17.0.x alongside any newer Quartus, unattended.
#
# 17.0.0 and 17.0.2 are both fine. MiSTer's Template.qsf records
# LAST_QUARTUS_VERSION "17.0.2 Standard Edition", but that field is a marker,
# not a requirement: sys/pll_q17.qip lists HDL that ships pre-generated in the
# repo, so nothing is regenerated as long as the toolchain is 17.0.x. If an M1
# core build ever behaves oddly, the point release is a variable worth
# eliminating — it is not one for the M0 spike, which uses no IP at all.
#
#   tools/install-quartus17.sh <installer> [installdir]
#
# <installer> is either:
#   Quartus-lite-17.0.0.595-linux.tar        combined archive, all devices
#   QuartusLiteSetup-17.0.0.595-linux.run    base installer; the Cyclone V
#                                            device file cyclonev-17.0.0.595.qdz
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
# Snapshot the cache once instead of piping into `grep -q` per library. Under
# `set -o pipefail` grep -q exits on the first match and SIGPIPEs ldconfig, so
# the pipeline reports failure on SUCCESS — every library comes back MISSING
# even when installed. Confidently wrong output is worse than none.
ldcache="$(ldconfig -p 2>/dev/null || true)"
for l in libpng12.so.0 libfreetype.so.6; do
  case "$ldcache" in
    *"$l"*) echo "  $l present" ;;
    *)      warn "  $l MISSING — only affects the GUI, not quartus_map/fit/sta" ;;
  esac
done

RUN=""
CLEAN=""
case "$SRC" in
  *.tar)
    # Extract beside the archive, NOT in /tmp. /tmp is commonly a tmpfs — 15.6G
    # of RAM on this machine — and these archives run to several GB, so mktemp -d
    # would spend that much RAM and can fail outright on a smaller box.
    TMP="$SRCDIR/.quartus-extract-$$"; CLEAN="$TMP"
    need_kb=$(( $(stat -c %s "$SRC") / 1024 * 2 ))   # archive plus extracted
    free_kb=$(df -Pk "$SRCDIR" | awk 'NR==2{print $4}')
    say "== extracting archive"
    echo "  into $TMP"
    printf '  need ~%s MB, free %s MB\n' "$((need_kb/1024))" "$((free_kb/1024))"
    [ "$free_kb" -gt "$need_kb" ] || die "not enough space in $SRCDIR"
    mkdir -p "$TMP"
    tar -xf "$SRC" -C "$TMP"
    # Parenthesised: without the group, -maxdepth applies per-branch and the
    # -o precedence makes the match unreliable.
    RUN="$(find "$TMP" -maxdepth 2 \( -name 'setup.sh' -o -name '*Setup*.run' \) | head -1)"
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
# No --disable-components. The component names differ between Quartus releases
# and an unrecognised one can abort the whole unattended run; disk is cheap
# next to re-downloading several GB. Trim afterwards if it matters.
"$RUN" --mode unattended --installdir "$DEST" --accept_eula 1 2>&1 | tail -20 || true

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
