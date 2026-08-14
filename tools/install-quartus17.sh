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
#   tools/install-quartus17.sh <installer> [installdir] [--keep]
#
# The archive is unpacked into tools/quartus-unpack/ and the installer is run
# from there, then the unpacked tree is deleted unless --keep is given. That
# path is gitignored and the script refuses to run if it is not: the payload is
# Altera-licensed and several GB, and must never be committed.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where the archive is unpacked before the installer runs. Under tools/, which
# is a TRACKED directory — .gitignore excludes this path, and it must stay
# excluded: the Quartus payload is Altera-licensed and redistributing it is not
# permitted. Same class of rule as third_party/geometrizer.
EXTRACT="$ROOT/tools/quartus-unpack"

KEEP=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --keep) KEEP=1 ;;          # leave the unpacked tree in place afterwards
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]:-}"

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
    # Unpack into tools/quartus-unpack, never /tmp: /tmp is commonly a tmpfs
    # (15.6G of RAM on this machine) and these archives run to several GB, so
    # extracting there spends that much RAM and fails outright on a smaller box.
    TMP="$EXTRACT"
    [ "$KEEP" = 1 ] || CLEAN="$TMP"
    need_kb=$(( $(stat -c %s "$SRC") / 1024 ))       # extracted tree only
    free_kb=$(df -Pk "$ROOT" | awk 'NR==2{print $4}')
    say "== extracting archive"
    echo "  into $TMP"
    printf '  need ~%s MB, free %s MB\n' "$((need_kb/1024))" "$((free_kb/1024))"
    [ "$free_kb" -gt "$need_kb" ] || die "not enough space on the filesystem holding $ROOT"

    # Refuse to run if the unpack path is not ignored. An accidental `git add -A`
    # would otherwise stage several GB of Altera-licensed installer.
    if command -v git >/dev/null && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      if ! git -C "$ROOT" check-ignore -q "$TMP" 2>/dev/null; then
        die "$TMP is not gitignored — refusing to unpack an Altera-licensed installer into a tracked tree"
      fi
      echo "  gitignored: yes"
    fi

    # Reuse an existing unpack rather than spending minutes re-extracting 6 GB
    # when only the installer arguments needed fixing.
    if [ -f "$TMP/setup.sh" ]; then
      echo "  reusing existing unpack (delete $TMP to force a fresh one)"
    else
      rm -rf "$TMP"
      mkdir -p "$TMP"
      tar -xf "$SRC" -C "$TMP"
    fi
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

say "== installing"
mkdir -p "$DEST"

# WHAT ACTUALLY WORKS, established the hard way on 2026-08-14.
#
# setup.sh installs the Quartus binaries and — critically — marks the install
# as Lite Edition. Skipping it and running QuartusLiteSetup.run directly gets
# the binaries but leaves the install identifying as "SJ Standard Edition",
# which then fails every build with:
#
#   Error (292025): License file is not specified.
#
# Lite is the licence-free edition, so that marker is not cosmetic.
#
# BUT setup.sh reliably stalls partway through, before installing the device
# families. Twice observed: the process stops writing files, CPU time freezes,
# and it sits in futex_wait indefinitely. With the default UI it blocks on a
# GUI progress dialog (the base installer forces --unattendedmodeui minimal on
# its children regardless of what it was given); with --unattendedmodeui none
# it still stalls, just without a window. Either way it never reaches the
# devices.
#
# So: run setup.sh until the binaries and the Lite marker exist, stop it, and
# install the device families by hand. Each .qdz is a plain zip already rooted
# at quartus/common/devinfo/<family>/, so extracting it into the install
# directory puts every file exactly where the installer would have.
# quartus_sh --qinstall is NOT an alternative: it takes -qda and rejects .qdz
# as a different format.

opts="$("$RUN" --help 2>&1 || true)"
inst_args=(--mode unattended --installdir "$DEST")
case "$opts" in *--unattendedmodeui*) inst_args+=(--unattendedmodeui none) ;; esac
case "$opts" in *--accept_eula*)      inst_args+=(--accept_eula 1) ;; esac

allowed="$(printf '%s\n' "$opts" \
  | awk '/--disable-components/{f=1} f && /Allowed:/{sub(/.*Allowed: */,""); print; exit}')"
drop=""
for c in quartus_help quartus_update modelsim_ase modelsim_ae \
         arria_lite cyclone cyclone10lp max max10; do
  for a in $allowed; do
    if [ "$a" = "$c" ]; then drop="${drop:+$drop,}$c"; break; fi
  done
done
if [ -n "$drop" ]; then
  echo "  skipping components: $drop"
  inst_args+=(--disable-components "$drop")
fi

echo "  running setup.sh in the background; it will be stopped once the"
echo "  binaries and the Lite edition marker are present"
"$RUN" "${inst_args[@]}" > "$DEST/../quartus17-setup.log" 2>&1 &
setup_pid=$!

# Poll for the two things setup.sh is needed for. Give up after 30 minutes.
deadline=$(( SECONDS + 1800 ))
have_bins=0
while [ $SECONDS -lt $deadline ]; do
  if [ -x "$DEST/quartus/bin/quartus_sh" ] \
     && "$DEST/quartus/bin/quartus_sh" --version 2>/dev/null | grep -qi 'lite edition'; then
    have_bins=1
    break
  fi
  kill -0 $setup_pid 2>/dev/null || break
  sleep 15
done

if kill -0 $setup_pid 2>/dev/null; then
  echo "  binaries and Lite marker present; stopping the installer"
  pkill -9 -P $setup_pid 2>/dev/null || true
  kill -9 $setup_pid 2>/dev/null || true
  wait $setup_pid 2>/dev/null || true
fi

[ "$have_bins" = 1 ] || die "setup.sh never produced a Lite-edition install; see $DEST/../quartus17-setup.log"

say "== installing device families from the .qdz archives"
# Idempotent: re-extracting over an existing family is harmless.
qdz_dir="$(dirname "$RUN")/components"
[ -d "$qdz_dir" ] || qdz_dir="$(dirname "$RUN")"
for q in "$qdz_dir"/cyclonev-*.qdz; do
  [ -f "$q" ] || continue
  echo "  extracting $(basename "$q")"
  python3 - "$q" "$DEST" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
    print(f"    {len(z.namelist())} entries")
PYEOF
done

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
