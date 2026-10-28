// SPDX-License-Identifier: GPL-3.0-or-later
//
// Does the Model 1 sound board's 68000 actually boot?
//
// THREE HARDWARE ROUND TRIPS WENT ON THIS QUESTION AND NONE OF THEM ANSWERED IT.
// The board is silent, the debug UART is compiled out to make the design fit, and
// a 45-minute Quartus build per hypothesis is not a debugger. The rules file says so
// outright: "measure BEFORE building ... Simulation and MAME together answer most
// questions for free."
//
// THE ORACLE, measured from MAME's :m1audio:sndcpu over 240 frames:
//   - it settles in a main loop at PC 0x1100 (217 of 240 frames)
//   - it reads D00000, the YM status, 985,000 times -- about 4,100 a frame
//   - it writes C40000 (15,511) and C60000 (11,061), both MultiPCMs
// Anything else is a hang, and WHERE it stops names the cause.
//
// TWO THINGS HERE ARE THIS CORE'S OWN AND ARE THE SUSPECTS:
//   1. the 68000's 64 KB work RAM is EXTERNAL (SDRAM, served with latency)
//      where Model 2 keeps it in M10K -- the CPU touches RAM within a few
//      instructions of reset, so a broken handshake is a silent dead board
//   2. the FM is stubbed to timers and status only (m1_ym_timer), and the
//      firmware polls that status 4,100 times a frame
#include <verilated.h>
#include "Vm1_sndboard_harness.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <cmath>

static bool load_file(const std::string &p, std::vector<uint8_t> &out) {
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  out.resize(n);
  bool ok = std::fread(out.data(), 1, n, f) == (size_t)n;
  std::fclose(f); return ok;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *d = new Vm1_sndboard_harness;

  // epr-14870a.7, 0x20000 bytes, ROM_LOAD16_WORD_SWAP in MAME -- the same byte
  // order the MRA produces with <interleave output="16"> map="12".
  const char *home = std::getenv("HOME");
  std::string base = std::string(home ? home : ".") + "/roms/";
  std::vector<uint8_t> a;
  if (!load_file(base + "vr/epr-14870a.7", a) &&
      !load_file(base + "epr-14870a.7", a)) {
    std::printf("m1_sndboard: SKIP (no epr-14870a.7 under ~/roms/vr/)\n");
    return 0;
  }
  std::vector<uint16_t> rom(a.size() / 2);
  for (size_t w = 0; w < rom.size(); w++)
    rom[w] = uint16_t((a[w * 2 + 1] << 8) | a[w * 2]);
  std::printf("m1_sndboard: ROM %zu bytes, reset SP=%04x%04x PC=%04x%04x\n",
              a.size(), rom[0], rom[1], rom[2], rom[3]);

  // THE REAL SAMPLE ROMS. Feeding zeros here makes the mix flat zero no matter
  // what the chips do, which looks exactly like the hardware fault and is not.
  std::vector<uint8_t> s1, s2;
  if (!load_file(base + "vr/mpr-14873.32", s1)) load_file(base + "mpr-14873.32", s1);
  if (!load_file(base + "vr/mpr-14876.4",  s2)) load_file(base + "mpr-14876.4",  s2);
  std::printf("m1_sndboard: samples %zu + %zu bytes\n", s1.size(), s2.size());

  std::map<uint32_t, uint16_t> ram;      // the external 64 KB work RAM
  long rom_lat = 0, ram_lat = 0;
  long p1_lat = 0, p2_lat = 0; int p1_busy = 0, p2_busy = 0;
  // LATENCY IS NOT A CONSTANT ON HARDWARE. Ten ports share one controller,
  // so the sound port waits behind the V60, the tile fetch, the 3D reads and
  // two PCM streams. A fixed 12 cycles is the easy case; this makes it long
  // and variable, which is what the board actually sees.
  unsigned lcg = 12345;
  const long ROM_MIN = std::getenv("SND_LAT") ? atol(getenv("SND_LAT")) : 12;
  d->rst_n = 0; d->rx_valid = 0; d->tx_ack = 1;
  d->rom_ack = 0; d->ram_ack = 0;
  d->pcm1_ack = 0; d->pcm2_ack = 0;

  std::map<uint32_t, long> pc_hist;
  long nonzero_l = 0, nonzero_r = 0; int16_t peak = 0, peak_r = 0;
  std::vector<std::string> pcmseq, dfseq, ymseq;

  // THE V60'S COMMAND STREAM, captured from MAME by tools/mame_snd_cmds.lua.
  //
  // Without this the 68000 sits in its idle loop and the board makes only the
  // low-level drone -- which is what every earlier measurement here described,
  // and why sizing a gain against it was wrong. The reference's real audio is
  // COMMANDED: `b0 56` at frame 2074 (34.6 s) is what starts it.
  //
  // The idle gaps are COMPRESSED. The driver cares about the order of its
  // commands, not about the thirty seconds the attract loop spends waiting, so
  // frame 280 -> frame 2074 becomes a short pause. That turns a 2.8-billion
  // cycle run into one that fits in a few hundred million.
  struct Cmd { long cyc; uint8_t b; };
  const long MS = 80000;                       // cycles per millisecond
  std::vector<Cmd> cmds = {
    // Captured from MAME by tools/mame_snd_cmds.lua WITH A COIN AND START --
    // the attract loop's commands produce only the drone, and the sound
    // EFFECTS are what a running car makes. Idle gaps compressed; the driver
    // cares about order, not about the seconds the attract spends waiting.
    { 20*MS,0x00},{ 21*MS,0x00},{ 22*MS,0x00},
    { 25*MS,0x40},{ 26*MS,0x4e},{ 27*MS,0x37},
    { 30*MS,0x81},{ 31*MS,0x00},
    {120*MS,0xc1},{121*MS,0x08},{123*MS,0x81},{124*MS,0x00},
    {126*MS,0xc0},{127*MS,0x00},{129*MS,0xc0},{130*MS,0x00},
    {132*MS,0xc1},{133*MS,0x08},{135*MS,0xc1},{136*MS,0x13},
    {138*MS,0xc1},{139*MS,0x11},{141*MS,0xc0},{142*MS,0x00},
    {144*MS,0xc1},{145*MS,0x08},{147*MS,0xc1},{148*MS,0x13},
    {150*MS,0xc1},{151*MS,0x11},
    // and the ones that start a race
    {200*MS,0xb0},{201*MS,0x06},{203*MS,0xb0},{204*MS,0x5b},
    {260*MS,0xb0},{261*MS,0x2e},{263*MS,0xb0},{264*MS,0x2e},
    {400*MS,0xb0},{401*MS,0x5c},
  };

  size_t cmdi = 0; long rx_hold = 0;

  // A WAV OF WHAT THE BOARD ACTUALLY PRODUCES.
  //
  // The register traffic now matches MAME's tap byte for byte, so the chips are
  // programmed correctly and the fault is downstream of that. The fastest way
  // to know whether simulation reproduces the board's rumble is to LISTEN to
  // the simulation -- if it does, this is fixable here instead of one 40-minute
  // Quartus build at a time.
  //
  // 44,100 in the header rather than the chip's 44,643: close enough to judge
  // by ear and every player opens it.
  std::vector<int16_t> wav;
  long wavdiv = 0;
  long insns_last = 0, stuck = 0;
  const int ACK_HOLD = std::getenv("ACK_HOLD") ? atoi(getenv("ACK_HOLD")) : 1;
  const int PCM_LAT  = std::getenv("PCM_LAT")  ? atoi(getenv("PCM_LAT"))  : 1;
  const int SHARED_COMB = std::getenv("SHARED_COMB") ? atoi(getenv("SHARED_COMB")) : 0;
  // HOW LONG IS LONG ENOUGH? MAME's reference peaks at 127 over TWENTY
  // seconds; 40 M cycles is half a second at 80 MHz, which may be before the
  // game plays anything at all. Overridable so the window is a measurement
  // rather than an assumption.
  const long CYCLES = std::getenv("CYCLES") ? atol(getenv("CYCLES")) : 40000000;

  for (long c = 0; c < CYCLES; c++) {
    if (c == 200) d->rst_n = 1;
    d->clk = 0; d->eval();

    // ONE SHARED PORT, BECAUSE THAT IS WHAT THE BOARD HAS.
    //
    // This bench served the 68000's ROM and its work RAM from TWO independent
    // servers with independent acknowledges. Model1.sv puts both on SDRAM
    // PORT 7 -- one address, one write enable, one set of byte enables, one
    // acknowledge -- because a 68000 has one bus and the work RAM is
    // externalised here (Model 2 keeps it on-chip). The shared-port hazard
    // therefore could not exist in simulation, and the board simulated
    // perfectly while failing on hardware.
    //
    // SHARED_COMB=1 reproduces the ORIGINAL arbitration: every field muxed on
    // the current value of ram_req, so a ROM fetch in flight when ram_req
    // rises has its address changed under it and its acknowledge delivered to
    // the RAM. Default 0 is the latched ownership Model1.sv has now.
    static int p7_busy = 0, p7_ram = 0, p7_lat = 0;
    {
      int want_ram = d->ram_req, want_rom = d->rom_req;
      if (SHARED_COMB) {
        // the defect: ownership follows ram_req moment to moment
        p7_ram = want_ram;
        p7_busy = want_ram || want_rom;
      } else if (!p7_busy) {
        if      (want_ram) { p7_busy = 1; p7_ram = 1; p7_lat = 0; }
        else if (want_rom) { p7_busy = 1; p7_ram = 0; p7_lat = 0; }
      }
      d->rom_ack = 0; d->ram_ack = 0;
      if (p7_busy) {
        if (++p7_lat >= ROM_MIN + (long)((lcg = lcg*1103515245+12345) >> 28)) {
          if (p7_ram) {
            uint32_t wa = d->ram_addr;
            if (d->ram_we) {
              uint16_t cur = ram.count(wa) ? ram[wa] : 0xffff;
              uint16_t nw  = d->ram_wdata;
              if (!(d->ram_be & 2)) nw = (nw & 0x00ff) | (cur & 0xff00);
              if (!(d->ram_be & 1)) nw = (nw & 0xff00) | (cur & 0x00ff);
              ram[wa] = nw;
            }
            d->ram_data = ram.count(wa) ? ram[wa] : 0xffff;
            d->ram_ack  = 1;
          } else {
            uint32_t wa = d->rom_addr;
            d->rom_data = (wa < rom.size()) ? rom[wa] : 0xffff;
            d->rom_ack  = 1;
          }
          p7_busy = 0; p7_lat = 0;
        }
      }
    }

    // ---------------------------------------------------------------------
    // THE SAMPLE ROMS. s1 and s2 were LOADED AND NEVER SERVED.
    //
    // pcm1_ack/pcm2_ack were set to 0 once at init and never assigned again,
    // and pcm1_data/pcm2_data were never driven at all - so every MULTIPCM
    // fetch that missed the per-voice cache waited forever for an
    // acknowledge that could not arrive.
    //
    // WHAT THAT COST. The chip ran correctly on cache hits for 113 ms of a
    // 387 ms run -- 224.00 ce per sample against a nominal 224, exactly on
    // rate -- then issued a descriptor fetch and hung for the rest. Read as
    // an average it looked like "the chip produces 20,202 Hz against 44,643",
    // which was chased as a rate fault, then as fetch latency, then as a
    // descriptor-fetch hang in the RTL. It was none of those. The comment
    // above the ROM load warned about exactly this and the servant was still
    // missing.
    //
    // ACK HELD UNTIL THE REQUEST DROPS. m2_pcm_fetch clears m_req on m_ack,
    // and a pulse that lands on the wrong cycle is the fault that has cost
    // this project the most time -- it cost tb_v60_ifetch a false 73,584
    // failures earlier today.
    //
    // ABOVE 2 MB READS AS ZERO, matching Model1.sv, which masks the SDRAM
    // return with `snd_pcm1_addr[21] ? 64'd0 : p_dout[8]`. Each chip sees a
    // 2 MB space whose upper half is a bank window.
    {
      auto serve = [&](uint8_t req, uint32_t addr_hi, const std::vector<uint8_t>& smp,
                       long& lat, int& busy, uint64_t& data, uint8_t& ack) {
        if (!req) { busy = 0; lat = 0; ack = 0; return; }
        if (ack) return;                       // held until req drops
        if (!busy) { busy = 1; lat = 0; }
        if (++lat < ROM_MIN + (long)((lcg = lcg*1103515245+12345) >> 28)) return;
        uint64_t v = 0;
        uint32_t byte_addr = addr_hi << 3;     // addr is [21:3]
        if (!(byte_addr & 0x200000))           // bit 21: above 2 MB reads zero
          for (int k = 0; k < 8; k++) {
            size_t a2 = (size_t)byte_addr + k;
            if (a2 < smp.size()) v |= (uint64_t)smp[a2] << (k * 8);
          }
        data = v; ack = 1; busy = 0; lat = 0;
      };
      serve(d->pcm1_req, d->pcm1_addr, s1, p1_lat, p1_busy, d->pcm1_data, d->pcm1_ack);
      serve(d->pcm2_req, d->pcm2_addr, s2, p2_lat, p2_busy, d->pcm2_data, d->pcm2_ack);
    }

    // feed the captured command stream
    if (rx_hold > 0) { if (d->rx_ack) { d->rx_valid = 0; rx_hold = 0; } else rx_hold--; }
    else if (cmdi < cmds.size() && c >= cmds[cmdi].cyc) {
      d->rx_data = cmds[cmdi].b; d->rx_valid = 1; rx_hold = 4000; cmdi++;
    }
    d->clk = 1; d->eval();

    // THE REGISTER TRAFFIC, sampled after the rising edge because the strobe is
    // an edge detect in the harness. Diffed against tools/mame_pcm_tap.lua.
    if (d->dbg_yw_stb && ymseq.size() < 48) {
      char b[24]; snprintf(b, sizeof b, "%02x=%02x", d->dbg_yw_reg, d->dbg_yw_val);
      ymseq.push_back(b);
    }
    if (d->dbg_df_stb && dfseq.size() < 24) {
      char b[48]; snprintf(b, sizeof b, "s%03x@%06x", d->dbg_df_sample, d->dbg_df_start);
      dfseq.push_back(b);
    }
    if (d->dbg_bw_stb && pcmseq.size() < 64) {
      char b[32]; snprintf(b, sizeof b, "bank=%02x", d->dbg_bw_data);
      pcmseq.push_back(b);
    }
    if (d->dbg_pw_stb && pcmseq.size() < 64) {
      char b[32]; snprintf(b, sizeof b, "%s%d=%02x",
                           d->dbg_pw_chip ? "B" : "", d->dbg_pw_addr, d->dbg_pw_data);
      pcmseq.push_back(b);
    }

    { int16_t l = (int16_t)d->snd_l, r = (int16_t)d->snd_r;
      if (l) nonzero_l++; if (r) nonzero_r++;
      // DECIMATED TO THE AUDIO RATE. The first version pushed one frame per
      // CLOCK, so two seconds of emulation became 5 ms of audio stretched over
      // ten -- a drone, which is exactly the artefact being investigated and
      // would have been mistaken for the fault.
      if (++wavdiv >= 80000000 / 44100) {
        wavdiv = 0;
        if (wav.size() < 44100u * 2u * 30u) { wav.push_back(l); wav.push_back(r); }
      }
      // BOTH CHANNELS. `peak` tracked only the LEFT, so a dead right channel
      // was invisible here - and the flat-zero check below used && , which
      // passes as long as ONE side has signal. A stuck ym_r or a mis-wired
      // mix_r would have shipped. Ben asked what about ym_r; nothing was
      // watching it.
      int16_t a = l < 0 ? -l : l; if (a > peak) peak = a;
      int16_t b2 = r < 0 ? -r : r; if (b2 > peak_r) peak_r = b2; }
    if ((c & 0xffff) == 0) {
      pc_hist[d->dbg_pc & 0xffff00]++;
      if (d->dbg_insns == insns_last) stuck++; else { stuck = 0; insns_last = d->dbg_insns; }
    }
  }

  std::printf("m1_sndboard: insns=%u pc=%06x ym_writes=%u pcm_writes=%u wram_writes=%u\n",
              (unsigned)d->dbg_insns, (unsigned)d->dbg_pc,
              (unsigned)d->dbg_ym_writes, (unsigned)d->dbg_pcm_writes, (unsigned)d->dbg_wram_writes);
  std::printf("  MIX: %.2f s simulated, non-zero L=%ld R=%ld cycles, peak |l|=%d (%.1f dBFS) |r|=%d (%.1f dBFS)\n",
              (double)CYCLES/80e6, nonzero_l, nonzero_r, peak,
              peak ? 20.0*log10((double)peak/32767.0) : -999.0, peak_r,
              peak_r ? 20.0*log10((double)peak_r/32767.0) : -999.0);
  // THE RATE, against the chip's own 44,643 Hz. Below that the chip is being
  // starved by fetch latency, which sounds like crackle rather than like
  // quiet, and no amount of gain fixes it.
  {
    double secs = (double)CYCLES / 80e6;
    double sps  = secs > 0 ? (double)d->dbg_pcm_samples / secs : 0.0;
    std::printf("  RATE: %u samples in %.3f s = %.0f Hz (chip wants 44643), underruns=%u, PCM_LAT=%d\n",
                d->dbg_pcm_samples, secs, sps, d->dbg_pcm_under, PCM_LAT);
  }
  // WHERE THE CHIP'S 990 ce PER SAMPLE ACTUALLY GO.
  {
    double tot = (double)(d->dbg_ce_adv + d->dbg_ce_romreq + d->dbg_ce_dfbusy);
    std::printf("  STALL: advancing=%u (%.1f%%)  rom_req=%u (%.1f%%)  df_busy=%u (%.1f%%)\n",
                d->dbg_ce_adv,    tot ? 100.0*d->dbg_ce_adv/tot    : 0.0,
                d->dbg_ce_romreq, tot ? 100.0*d->dbg_ce_romreq/tot : 0.0,
                d->dbg_ce_dfbusy, tot ? 100.0*d->dbg_ce_dfbusy/tot : 0.0);
    std::printf("         descriptor fetches: started=%u completed=%u\n",
                d->dbg_df_starts, d->dbg_df_done);
    if (d->dbg_pcm_samples)
      std::printf("         %.0f ce per sample (nominal 224: 28 slots x 8 ticks)\n",
                  tot / (double)d->dbg_pcm_samples);
  }

  // THE FIRST REGISTER WRITES, to diff against MAME's tap. See
  // tools/mame_pcm_tap.lua -- the reference opens with
  //   bank=01 bank=01  then per slot: 02=<slot> 04=09 00=0f 04=05 00=fe ...
  {
    const char* wp = std::getenv("WAVOUT") ? std::getenv("WAVOUT") : "snd.wav";
    FILE* f = fopen(wp, "wb");
    if (f) {
      uint32_t nd = (uint32_t)(wav.size() * 2), rate = 44100;
      uint32_t br = rate * 2 * 2; uint16_t ba = 4, bits = 16, ch = 2, fmt = 1;
      uint32_t sz = 36 + nd, sub1 = 16;
      fwrite("RIFF", 1, 4, f); fwrite(&sz, 4, 1, f); fwrite("WAVE", 1, 4, f);
      fwrite("fmt ", 1, 4, f); fwrite(&sub1, 4, 1, f); fwrite(&fmt, 2, 1, f);
      fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&br, 4, 1, f);
      fwrite(&ba, 2, 1, f); fwrite(&bits, 2, 1, f);
      fwrite("data", 1, 4, f); fwrite(&nd, 4, 1, f);
      fwrite(wav.data(), 2, wav.size(), f);
      fclose(f);
      std::printf("  WAV: %s, %zu stereo frames\n", wp, wav.size() / 2);
    }
  }
  std::printf("  YMREGS:");
  for (size_t i = 0; i < ymseq.size(); i++) std::printf(" %s", ymseq[i].c_str());
  std::printf("\n");
  std::printf("  IRQ: timer(IRQ4) fired %u times, uart(IRQ2) %u times\n",
              d->dbg_irq4_n, d->dbg_irq2_n);
  std::printf("  DESCRIPTORS (sample index @ start addr):");
  for (size_t i = 0; i < dfseq.size(); i++) std::printf(" %s", dfseq[i].c_str());
  std::printf("\n");
  std::printf("  PCMSEQ:");
  for (size_t i = 0; i < pcmseq.size() && i < 40; i++) std::printf(" %s", pcmseq[i].c_str());
  std::printf("\n");
  std::printf("  PC pages visited:");
  for (auto &kv : pc_hist) std::printf(" %06x(%ld)", kv.first, kv.second);
  std::printf("\n");

  int fails = 0;
  // MAME's reference reaches its main loop at 0x1100 and drives both PCMs.
  if (d->dbg_insns < 10000) {
    std::printf("  FAIL only %u instructions retired -- the 68000 is not running\n",
                (unsigned)d->dbg_insns); fails++;
  }
  // WORK RAM IS ON-CHIP NOW, so `ram` (the external-port shadow) is correctly
  // empty and cannot be the test. The board counts its own writes instead.
  if (d->dbg_wram_writes == 0) {
    std::printf("  FAIL the 68000 never wrote work RAM -- it died before clearing it\n");
    fails++;
  }
  // EITHER CHANNEL FLAT IS A FAULT, not just both. This was && , which a
  // one-sided break passes: the YM, both MULTIPCMs and the mixer all carry L
  // and R independently, so a single dropped connection kills one side only.
  if (nonzero_l == 0 && nonzero_r == 0) {
    std::printf("  FAIL the mix is flat zero -- the chips play but nothing comes out\n");
    fails++;
  } else if (nonzero_l == 0 || nonzero_r == 0) {
    std::printf("  FAIL one channel is flat zero (L=%ld R=%ld cycles) -- a dropped connection on %s\n",
                nonzero_l, nonzero_r, nonzero_l == 0 ? "the LEFT" : "the RIGHT");
    fails++;
  }
  if (d->dbg_pcm_writes == 0) {
    std::printf("  FAIL no MultiPCM writes -- the reference makes 26,572 in 240 frames\n");
    fails++;
  }
  std::printf("m1_sndboard: checks=5 fails=%d\n", fails);
  return 0;
}
