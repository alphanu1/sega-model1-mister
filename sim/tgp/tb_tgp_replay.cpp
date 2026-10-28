// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// THE COPROCESSOR, REPLAYED AGAINST MAME'S OWN TRAFFIC.
//
// tools/mame_tgp_stream.lua records, from reset, everything the V60 says to
// the coprocessor (command FIFO pushes, copro RAM address and data writes) and
// every word the coprocessor pushes back. The TGP's only other inputs are its
// ROMs. So with the same stream in, our m1_tgp must push back exactly the same
// words in the same order, and the first one that differs names the handler
// at fault with no V60, no timing and no display list in the way.
//
// This is the instrument findings.md 2026-09-10 asked for ("the matrix arrives
// wrong ... the V60 or the coprocessor produces it"). tgp_wrtrace could not
// answer it: it is driven by OUR V60, so neither side reached a match.
//
// The one ordering the stream cannot carry is when a V60 copro RAM write lands
// relative to the TGP's own execution. Every such write is applied with the
// TGP IDLE - command FIFO drained and the core waiting on it - which is the
// only moment a write cannot race the program. A game that wrote copro RAM
// under a running command would be racing on the real board too.
//
//   tb_tgp_replay <stream.txt> <tgp_prog.hex> <tgp_tables.hex> <stream.bin>
//
// Environment: LAT (memory latency, default 1), JITTER (0/1: random extra
// latency 0..7 on every memory access - the answers must not change),
// MAXFAIL (mismatches printed, default 20), CMDLOG (file: every popped word
// with frame and pc, for tools/tgp_cmd_frames.py).
//
// And three that model a coprocessor that LAGS its V60, to ask whether the
// game depends on the order a copro RAM write lands in: RACE=1 lands V60 RAM
// writes where the stream has them instead of waiting for the TGP to go idle,
// SLACK=<n> lets that many answers be outstanding before the bench lets the
// TGP catch up (default 64), FIFO=<n> bounds the command FIFO the way the
// board's 16-word one does (a full one stalls the V60). Measured on Virtua
// Fighter, 2026-10-28: RACE with SLACK=5000 gives 154,614 wrong answers of
// 1,484,210 (`33800000 00011500` reads a block the next upload overwrote);
// RACE with FIFO=16 gives 0 at LAT 1 and 20. The ordering matters to the game
// and the board's FIFO depth is what keeps it.

#include "Vm1_tgp.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <vector>

static std::vector<uint32_t> load_hex(const char* path, size_t expect) {
  std::vector<uint32_t> v;
  FILE* f = fopen(path, "r");
  if (!f) { printf("SKIP: %s not found\n", path); exit(0); }
  char line[64];
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '\n' || line[0] == '\0') continue;
    v.push_back((uint32_t)strtoul(line, nullptr, 16));
  }
  fclose(f);
  if (expect && v.size() != expect) {
    printf("FAIL: %s has %zu words, expected %zu\n", path, v.size(), expect);
    exit(1);
  }
  return v;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 5) {
    printf("usage: %s stream.txt prog.hex tables.hex stream.bin\n", argv[0]);
    return 2;
  }
  auto ucode  = load_hex(argv[2], 2048);
  auto tables = load_hex(argv[3], 65536);
  // copro_data: the packed stream carries it at byte 0x600000, 2 MB,
  // little-endian 32-bit words (tools/build_rom_image.py).
  std::vector<uint32_t> data(0x80000, 0xffffffffu);
  {
    FILE* f = fopen(argv[4], "rb");
    if (!f) { printf("SKIP: %s not found\n", argv[4]); return 0; }
    fseek(f, 0x600000, SEEK_SET);
    size_t n = fread(data.data(), 4, data.size(), f);
    fclose(f);
    printf("copro_data: %zu words from %s\n", n, argv[4]);
  }
  const int lat    = getenv("LAT") ? atoi(getenv("LAT")) : 1;
  const int race   = getenv("RACE") ? atoi(getenv("RACE")) : 0;
  const int fifo_depth = getenv("FIFO") ? atoi(getenv("FIFO")) : 0;
  const int jitter = getenv("JITTER") ? atoi(getenv("JITTER")) : 0;
  const long maxfail = getenv("MAXFAIL") ? atol(getenv("MAXFAIL")) : 20;
  std::mt19937 rng(0x5e9a1);
  // CMDLOG=<file>: every word the TGP pops, with the frame and the core's pc,
  // so a command stream can be framed into commands (the dispatcher's pop)
  // and arguments, and two streams compared command by command.
  FILE* cmdlog = getenv("CMDLOG") ? fopen(getenv("CMDLOG"), "w") : nullptr;

  auto* d = new Vm1_tgp;
  long cyc = 0;
  auto tick = [&]{ d->clk = 0; d->ucode_clk = 0; d->eval();
                   d->clk = 1; d->ucode_clk = 1; d->eval(); cyc++; };
  d->clk = 0; d->rst_n = 0;
  d->ucode_clk = 0; d->ucode_we = 0; d->ucode_addr = 0; d->ucode_data = 0;
  d->ram_rdata = 0; d->ram_ack = 0;
  d->fifo_in_data = 0; d->fifo_in_valid = 0; d->fifo_out_full = 0;
  d->tbl_rdata = 0; d->tbl_ack = 0; d->dat_rdata = 0; d->dat_ack = 0;
  d->eval();
  for (int i = 0; i < 4; i++) tick();
  d->ucode_we = 1;
  for (size_t i = 0; i < ucode.size(); i++) {
    d->ucode_addr = (uint16_t)i; d->ucode_data = ucode[i]; tick();
  }
  d->ucode_we = 0; tick();
  d->rst_n = 1;

  // ---- the world outside the core
  std::vector<uint32_t> cram(8192, 0);   // MAME: memset 0 in copro_reset
  std::deque<uint32_t> fin;              // V60 -> TGP
  std::deque<uint32_t> ours;             // TGP -> V60, not yet compared
  std::deque<uint32_t> want;             // MAME's answers, not yet compared
  std::deque<uint32_t> lastcmd;          // the last words the TGP popped
  long answers = 0, fails = 0, popped_total = 0, ram_w = 0;
  long busy_cyc = 0, retires = 0; uint16_t last_ret = 0;
  int frame = 0;

  // One outstanding access per port, answered after a latency.
  struct Port { bool busy = false; int wait = 0; };
  Port pr, pt, pd;
  auto newwait = [&]{ return lat + (jitter ? (int)(rng() & 7) : 0); };

  auto cycle = [&]{
    // Drive inputs from the current state, then clock.
    d->fifo_in_valid = !fin.empty();
    d->fifo_in_data  = fin.empty() ? 0 : fin.front();
    d->ram_ack = 0; d->tbl_ack = 0; d->dat_ack = 0;
    d->eval();
    // RAM: as m1_copro_if serves it - one access per request, then idle for
    // a cycle so a request still held after its ack is not served twice.
    if (pr.busy) {
      if (pr.wait > 0) pr.wait--;
      else {
        if (d->ram_we) cram[d->ram_addr & 0x1fff] = d->ram_wdata;
        else           d->ram_rdata = cram[d->ram_addr & 0x1fff];
        d->ram_ack = 1; pr.busy = false;
      }
    } else if (d->ram_req) { pr.busy = true; pr.wait = newwait(); }
    if (pt.busy) {
      if (pt.wait > 0) pt.wait--;
      else { d->tbl_rdata = tables[d->tbl_addr & 0xffff]; d->tbl_ack = 1; pt.busy = false; }
    } else if (d->tbl_req) { pt.busy = true; pt.wait = newwait(); }
    if (pd.busy) {
      if (pd.wait > 0) pd.wait--;
      else { d->dat_rdata = data[d->dat_addr & 0x7ffff]; d->dat_ack = 1; pd.busy = false; }
    } else if (d->dat_req) { pd.busy = true; pd.wait = newwait(); }
    d->eval();
    // busy = not parked on an empty command FIFO; retires counted off the
    // wrapping 16-bit counter's changes.
    if (!(fin.empty() && d->dbg_fifo_rd)) busy_cyc++;
    if (d->dbg_retires != last_ret) { retires++; last_ret = d->dbg_retires; }
    bool pop = d->fifo_in_pop;
    bool push = d->fifo_out_push;
    uint32_t pv = d->fifo_out_data;
    tick();
    if (pop && !fin.empty() && cmdlog)
      fprintf(cmdlog, "%d %03x %08x\n", frame, (unsigned)d->dbg_pc, fin.front());
    if (pop && !fin.empty()) {
      lastcmd.push_back(fin.front()); if (lastcmd.size() > 24) lastcmd.pop_front();
      fin.pop_front(); popped_total++;
    }
    if (push) ours.push_back(pv);
    // compare as soon as both sides have a word
    while (!ours.empty() && !want.empty()) {
      uint32_t a = ours.front(), b = want.front();
      ours.pop_front(); want.pop_front();
      if (a != b) {
        if (fails < maxfail) {
          printf("MISMATCH answer #%ld frame %d: ours %08x MAME %08x  tgp pc=%03x\n",
                 answers, frame, a, b, (unsigned)d->dbg_pc);
          printf("   last words popped (oldest first):");
          for (auto w : lastcmd) printf(" %08x", w);
          printf("\n");
        }
        fails++;
      }
      answers++;
    }
  };
  // Idle = nothing queued for the TGP and it is waiting on the FIFO.
  auto run_to_idle = [&](long limit) -> bool {
    long n = 0;
    while (n++ < limit) {
      cycle();
      if (fin.empty() && d->dbg_fifo_rd && !pr.busy && !pt.busy && !pd.busy) return true;
    }
    return false;
  };

  // ---- the stream, cooked with MAME's own rules (model1_m.cpp)
  FILE* sf = fopen(argv[1], "r");
  if (!sf) { printf("cannot open %s\n", argv[1]); return 1; }
  uint16_t v60_adr = 0, latch[2] = {0, 0};
  uint32_t fifo_w = 0;
  long pushes = 0, never_idle = 0, ram_reads = 0, ram_read_bad = 0;
  char line[128];
  while (fgets(line, sizeof line, sf)) {
    char sp, rw; unsigned a, v, m;
    if (line[0] == 'F') { frame = atoi(line + 2); continue; }
    if (line[0] == 'T') {
      want.push_back((uint32_t)strtoul(line + 2, nullptr, 16));
      // let the core produce what MAME already has before moving on, so a
      // mismatch is reported near the commands that caused it
      continue;
    }
    if (sscanf(line, "%c %c %x %x %x", &sp, &rw, &a, &v, &m) != 5) continue;
    uint32_t base = a & 0xfe0000, odd = (a >> 1) & 1;
    if (base == 0xd80000) {
      if (rw == 'W') {
        if (odd) {
          // FIFO=<n> models the board's bounded command FIFO: a push into a full
          // one stalls the V60 until the TGP takes a word, which is the only
          // thing that ever holds the V60 back in RACE mode.
          if (fifo_depth) { long g = 0; while (fin.size() >= (size_t)fifo_depth && g++ < 4000000) cycle(); }
          fifo_w = (fifo_w & 0xffff) | (v << 16); fin.push_back(fifo_w); pushes++;
        }
        else       fifo_w = (fifo_w & 0xffff0000u) | v;
      }
      // V60 reads of the result FIFO carry phantom zeros (a pop of an empty
      // FIFO stalls the V60 and is retried) - the T lines are the reference.
    } else if (base == 0xd00000) {
      if (rw == 'W') v60_adr = (v60_adr & ~m) | (v & m);
    } else if (base == 0xd20000) {
      if (rw == 'W') {
        latch[odd] = (latch[odd] & ~m) | (v & m);
        if (odd) {
          // RACE=1 lands the write where the stream has it, without waiting
          // for the TGP: what a V60 that outruns its coprocessor does.
          if (!race && !run_to_idle(4000000)) never_idle++;
          cram[v60_adr & 0x1fff] = latch[0] | ((uint32_t)latch[1] << 16);
          ram_w++;
          if (v60_adr & 0x8000) v60_adr++;
        }
      } else {
        // A V60 READ of copro RAM: check our RAM holds what MAME returned,
        // once the TGP has finished whatever it was given.
        if (!run_to_idle(4000000)) never_idle++;
        uint32_t w = cram[v60_adr & 0x1fff];
        uint16_t h = odd ? (w >> 16) : (w & 0xffff);
        ram_reads++;
        if (h != (v & 0xffff)) {
          if (ram_read_bad < 10)
            printf("RAMREAD frame %d adr %04x half %u: ours %04x MAME %04x\n",
                   frame, v60_adr & 0x1fff, odd, h, v & 0xffff);
          ram_read_bad++;
        }
        if (odd && (v60_adr & 0x8000)) v60_adr++;
      }
    }
    // keep the core moving with the stream so the queues stay short
    for (int i = 0; i < 4; i++) cycle();
    if (want.size() > (size_t)(getenv("SLACK") ? atol(getenv("SLACK")) : 64)) run_to_idle(4000000);
  }
  fclose(sf);
  run_to_idle(20000000);
  printf("tgp_replay: frames=%d pushes=%ld popped=%ld answers=%ld fails=%ld "
         "unanswered_mame=%zu extra_ours=%zu ram_writes=%ld ram_reads=%ld ram_read_bad=%ld "
         "never_idle=%ld cycles=%ld busy=%ld retires=%ld\n",
         frame, pushes, popped_total, answers, fails, want.size(), ours.size(),
         ram_w, ram_reads, ram_read_bad, never_idle, cyc, busy_cyc, retires);
  delete d;
  return fails ? 1 : 0;
}
