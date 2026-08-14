#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Bootstrap upstream dependencies for the Model 1 core.
#
#   tools/bootstrap.sh              read-only clones into third_party/
#   tools/bootstrap.sh --fork       fork to your GitHub account first (needs gh)
#   tools/bootstrap.sh --no-mame    skip the MAME sparse checkout
#   tools/bootstrap.sh --update     re-pin deps.lock to current upstream HEADs
#
# Everything lands in third_party/. Nothing is copied into rtl/ automatically:
# licence terms differ per dependency and one of them forbids copying outright.
# Read the licence report this prints before lifting any code.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
LOCK="$ROOT/deps.lock"

DO_FORK=0
DO_MAME=1
DO_UPDATE=0

for a in "$@"; do
  case "$a" in
    --fork)    DO_FORK=1 ;;
    --no-mame) DO_MAME=0 ;;
    --update)  DO_UPDATE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------- dependencies
#
# name | repo | branch | role | licence | forkable

DEPS=(
  "template|MiSTer-devel/Template_MiSTer|master|core skeleton and sys/ framework|GPL-2.0-or-later|yes"
  "s32|meathax/s32|main|V60 CPU source and its verification suite|GPL-3.0|yes"
  "geometrizer|frangarcj/geometrizer|main|V60 + MB86233 oracle, MAME lockstep harness|NONE|no"
)

# --------------------------------------------------------------------- helpers

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

pin() { # repo dir -> "name sha"
  git -C "$1" rev-parse HEAD 2>/dev/null || echo "UNKNOWN"
}

pinned_sha() { # name -> sha recorded in the existing deps.lock, empty if none
  [ -f "$LOCK" ] || return 0
  awk -v n="$1" '$1 == n { print $3 }' "$LOCK"
}

# Move a fresh clone back onto its recorded pin.
#
# Without this the lock was decorative: every clone took branch HEAD and then
# deps.lock was overwritten with whatever arrived, so the file recorded what you
# happened to get instead of constraining what you got. MAME is the oracle this
# project verifies against — it silently moving between two machines, or between
# two runs on the same machine, undermines every comparison made against it.
#
# GitHub permits fetching a reachable SHA directly, so this stays a shallow
# fetch rather than deepening the clone.
# Written with explicit if/return rather than `test && return 0` guards: this
# script runs under `set -e`, where a bare failing test as the final command of
# a && list is a well-known way to abort the whole run.
checkout_pin() { # name dir -> checks out the pinned sha if one is recorded
  local name="$1" dir="$2" want have
  if [ "$DO_UPDATE" = 1 ]; then return 0; fi
  want="$(pinned_sha "$name")"
  if [ -z "$want" ] || [ "$want" = "UNKNOWN" ]; then return 0; fi
  have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$have" = "$want" ]; then return 0; fi
  if git -C "$dir" fetch --depth 1 -q origin "$want" 2>/dev/null; then
    git -C "$dir" checkout -q FETCH_HEAD
    echo "  $name: pinned to $want"
  else
    warn "  $name: pinned $want not fetchable, left at branch HEAD ($(pin "$dir"))"
    warn "  $name: rerun with --update to re-pin deliberately"
  fi
}

# ------------------------------------------------------------------ toolchain

say "== toolchain"
need git
for t in verilator yosys; do
  if have "$t"; then echo "  $t        $(command -v $t)"
  else warn "  $t        MISSING — 'make test' and 'make area' will not run"; fi
done
if have quartus_map; then
  echo "  quartus    $(quartus_map --version 2>/dev/null | head -1)"
else
  warn "  quartus    MISSING — 'make quartus' will not run. M0 gate needs 17.0.x Lite."
fi
if [ "$DO_FORK" = 1 ]; then
  need gh
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"
  echo "  gh         $(gh api user --jq .login) (fork mode)"
fi
echo

# -------------------------------------------------------------------- vendors

mkdir -p "$VENDOR"
: > "$LOCK.tmp"
echo "# Pinned upstream revisions. Regenerate with tools/bootstrap.sh --update" >> "$LOCK.tmp"
echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOCK.tmp"

say "== dependencies"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo branch role lic forkable <<< "$entry"
  dest="$VENDOR/$name"
  url="https://github.com/$repo.git"

  if [ "$DO_FORK" = 1 ] && [ "$forkable" = "yes" ]; then
    user="$(gh api user --jq .login)"
    if gh repo view "$user/$(basename "$repo")" >/dev/null 2>&1; then
      echo "  $name: fork already exists at $user/$(basename "$repo")"
    else
      echo "  $name: forking $repo -> $user"
      gh repo fork "$repo" --clone=false --remote=false >/dev/null
    fi
    url="https://github.com/$user/$(basename "$repo").git"
  elif [ "$DO_FORK" = 1 ]; then
    warn "  $name: not forked ($lic licence — see licence report below)"
  fi

  if [ -d "$dest/.git" ]; then
    if [ "$DO_UPDATE" = 1 ]; then
      echo "  $name: updating"
      git -C "$dest" fetch --depth 1 origin "$branch" -q
      git -C "$dest" checkout -q FETCH_HEAD
    else
      echo "  $name: present, skipping (use --update to re-pin)"
      want="$(pinned_sha "$name")"
      if [ -n "$want" ] && [ "$want" != "UNKNOWN" ] \
         && [ "$(pin "$dest")" != "$want" ]; then
        warn "  $name: DRIFT — on disk $(pin "$dest"), lock says $want"
      fi
    fi
  else
    echo "  $name: cloning $repo"
    git clone --depth 1 --branch "$branch" -q "$url" "$dest"
    # Keep upstream reachable even when working from a fork.
    git -C "$dest" remote add upstream "https://github.com/$repo.git" 2>/dev/null || true
    checkout_pin "$name" "$dest"
  fi

  printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$dest")" >> "$LOCK.tmp"
done

# ------------------------------------------------------------------ MAME
#
# MAME is enormous. Blobless partial clone plus a non-cone sparse checkout
# pulls only the reference sources this project reads, a few MB rather than
# several GB.

if [ "$DO_MAME" = 1 ]; then
  echo
  say "== mame (sparse reference checkout)"
  dest="$VENDOR/mame"
  if [ -d "$dest/.git" ]; then
    echo "  present, skipping"
  else
    git clone --filter=blob:none --no-checkout --depth 1 -q \
      https://github.com/mamedev/mame.git "$dest"
    git -C "$dest" sparse-checkout init --no-cone
    git -C "$dest" sparse-checkout set \
      '/src/devices/cpu/mb86233/*' \
      '/src/devices/cpu/v60/*' \
      '/src/mame/sega/model1*' \
      '/src/mame/sega/segaic24*' \
      '/src/devices/sound/multipcm.*' \
      '/src/devices/machine/mb8421.*' \
      '/LICENSE.md'
    # Pin only AFTER sparse-checkout is configured. The clone is --no-checkout,
    # so checking out a ref before the sparse patterns exist would materialise
    # all ~31k tracked files and demand every blob — gigabytes, on a clone whose
    # entire purpose is to stay at a few MB.
    checkout_pin "mame" "$dest"
    git -C "$dest" checkout -q
    echo "  checked out $(find "$dest/src" -type f 2>/dev/null | wc -l) reference files"
  fi
  printf '%-14s %s %s\n' "mame" "mamedev/mame" "$(pin "$dest")" >> "$LOCK.tmp"
fi

mv "$LOCK.tmp" "$LOCK"

# --------------------------------------------------------------------- report

cat <<'REPORT'

================================ LICENCE REPORT ================================

Read this before copying a single line out of third_party/.

  template     GPL-2.0-or-later
               The repo LICENSE file is a GPLv2 copy, but the per-file headers
               in sys/ read "either version 2 of the License, or (at your
               option) any later version". That or-later clause is what makes
               the next line legal.

  s32          GPL-3.0
               GPL-3 and GPL-2-ONLY cannot be combined. They are only
               compatible here because MiSTer's sys/ is GPL-2-OR-LATER, which
               can be upgraded to GPL-3. CONSEQUENCE: taking the V60 forces
               this entire core to ship as GPL-3. Decide that deliberately —
               most MiSTer cores are GPL-2-or-later and yours would not be
               interchangeable with them.

  geometrizer  NO LICENCE FILE
               No licence means all rights reserved. It can be run as an
               external oracle process and read as a behavioural reference.
               Its code CANNOT be copied or adapted into this repo. Ask
               frangarcj before lifting anything, including the harness.

  mame         Mixed. The specific files vendored here carry BSD-3-Clause
               headers (mb86233.cpp is "license:BSD-3-Clause,
               copyright-holders:Olivier Galibert"). MAME as a whole is
               GPL-2.0. Check the header of every file you read, not the
               repo licence.

================================================================================
REPORT

cat <<'NEXT'
Useful paths now available:

  third_party/s32/rtl/cpu/v60/s32_v60.sv        V60 core
  third_party/s32/verif/v60/                    ~35 directed testbenches
  third_party/s32/verif/cosim/mame_v60_trace.patch   MAME trace instrumentation
  third_party/s32/verif/quartus_v60/area/       V60 standalone area project
  third_party/mame/src/devices/cpu/mb86233/     TGP behavioural model
  third_party/mame/src/mame/sega/model1*        board layout, chips, clocks
  third_party/template/sys/                     MiSTer framework

Note s32 already ships a V60 verification suite and a standalone Quartus area
project. That is most of M1's verification scaffolding and it exists today —
read verif/v60/BASELINE.md before writing any new V60 tests.

Next: tools/bootstrap.sh --fork   (if you want write access to template + s32)
      make test                   (M0 FP units)
NEXT
