# Third-party components and licence position

This core is licensed **GPL-3.0-or-later**. See `LICENSE`.

That choice is forced, not preferred. It is recorded as decision D7 in
`docs/00-decisions.md` along with the conditions that would reverse it.

---

## Why GPL-3

The V60 CPU comes from `meathax/s32`, which is **GPL-3.0**. GPL-3 cannot be combined
with GPL-2-only code.

MiSTer's `sys/` framework is distributed under a repo LICENSE file containing the GPLv2
text, but every source file header reads:

> either version 2 of the License, or (at your option) any later version

That or-later clause permits upgrading `sys/` to GPL-3, which is the only reason this
combination is lawful.

**Consequence.** Most MiSTer cores are GPL-2-or-later. This one is GPL-3, so code cannot
flow from this repo back into them. Code can flow *in* from GPL-2-or-later cores.

**To relicense as GPL-2-or-later**, the s32 V60 must be removed and replaced with an
independently written V60, or meathax must agree to dual-license. Nothing else in the
tree blocks it.

---

## Components

### Incorporated (code may be used, subject to terms)

| Component | Origin | Licence | Notes |
|---|---|---|---|
| V60 CPU core | `meathax/s32` `rtl/cpu/v60/` | GPL-3.0 | Forces this repo to GPL-3 |
| V60 verification suite | `meathax/s32` `verif/` | GPL-3.0 | ~35 testbenches, cosim harness, area project |
| MiSTer framework | `MiSTer-devel/Template_MiSTer` `sys/` | GPL-2.0-or-later | Upgraded to GPL-3 in combination |
| MB86233 behavioural model | MAME `src/devices/cpu/mb86233/` | BSD-3-Clause | © Olivier Galibert. Reference for `rtl/tgp/`. Retain the copyright notice. |
| MB8421 dual-port RAM model | MAME `src/devices/machine/mb8421.*` | check file header | Verify before use |
| MultiPCM model | MAME `src/devices/sound/multipcm.*` | check file header | Verify before use |
| Model 1 board documentation | MAME `src/mame/sega/model1*` | check file header | Chip identification, clocks, memory map |

MAME is GPL-2.0 **as a whole**, but individual files carry their own SPDX headers and
many are BSD-3-Clause. Check the header of every file you read. Do not rely on the
repository-level licence.

### Reference only (code must NOT be copied)

| Component | Origin | Licence |
|---|---|---|
| V60 + MB86233 oracle, MAME lockstep harness | `frangarcj/geometrizer` | **NONE** |

`geometrizer` ships **no licence file**, which means all rights reserved by default.

Permitted: running it as an external oracle process, reading it to understand hardware
behaviour, comparing traces against it.

**Not permitted:** copying or adapting any of its source into this repository. That
includes the verification harness, the fuzzing driver, and the trace-diffing tooling.
Reimplement those against the MAME device model (BSD-3-Clause) instead, or ask
frangarcj for explicit permission first.

---

## Originally written here

Everything under `rtl/tgp/` except where a file header says otherwise, plus `sim/`,
`tools/`, `quartus/` and `docs/`. GPL-3.0-or-later.

`rtl/tgp/mb86233_pkg.sv` transcribes constants — opcode numbering, status flag bit
positions, and the exponent/mantissa field accessors — from MAME's BSD-3-Clause
`mb86233.cpp`. The BSD attribution is carried in that file's header.

---

## Redistribution checklist

Before publishing a release:

- [ ] `LICENSE` present and unmodified
- [ ] SPDX header on every source file
- [ ] This file lists every vendored component actually used
- [ ] `deps.lock` pins the exact upstream revisions built against
- [ ] Olivier Galibert's BSD-3-Clause notice retained wherever MAME-derived
- [ ] No `geometrizer` code present anywhere in the tree
- [ ] ROM images are not distributed. Ever.
