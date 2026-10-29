// SPDX-License-Identifier: BSD-3-Clause
//
// A reference model of the Yamaha YMW-258-F 'GEW8' (Sega 315-5560 MultiPCM),
// for the replay bench only. It is a transcription of MAME 0.289's
// src/devices/sound/gew.cpp and multipcm.cpp (BSD-3-Clause, copyright-holders
// Miguel Angel Horna), reduced to one chip with no stream machinery, so a
// register log captured from MAME can be played through the same arithmetic
// the reference uses and compared with the RTL sample by sample.
//
// It is MAME's computation, not the silicon's. Where the two might differ is
// the RTL's business to argue; this file only has to agree with MAME.
#pragma once
#include <cstdint>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <functional>

struct MultiPcmRef {
  static constexpr uint32_t TL_SHIFT = 12, EG_SHIFT = 16, LFO_SHIFT = 8;
  enum State { ATTACK, DECAY1, DECAY2, RELEASE };
  struct Sample { uint32_t start=0, loop=0, end=0; uint8_t ar=0, d1r=0, d2r=0, dl=0, rr=0, krs=0, lfo_vib=0, lfo_am=0, format=0; };
  struct Eg { int32_t volume=0; State state=ATTACK; int32_t ar=0, d1r=0, d2r=0, rr=0, dl=0; };
  struct Lfo { uint16_t phase=0; uint32_t phase_step=0; const int32_t *table=nullptr, *scale=nullptr; };
  struct Slot {
    uint8_t regs[8] = {0};
    bool playing=false; Sample s; uint32_t offset=0; uint8_t octave=0; uint16_t pitch=0; uint32_t step=0;
    bool reverse=false; uint32_t pan=0, tl=0, dest_tl=0; int32_t tl_step=0; int32_t prev=0; Eg eg;
    uint8_t lfo_freq=0, vibrato=0, tremolo=0; Lfo plfo, alfo;
  };

  Slot slots[28];
  float rate;
  uint32_t attack_step[64], decay_step[64], freq_step[0x400];
  int32_t lpan[0x800], rpan[0x800], lin2exp[0x400], tl_steps[2];
  int32_t pitch_table[256], amp_table[256], pitch_scale[8][256], amp_scale[8][256];
  uint32_t cur_slot=0, address=0;
  std::function<uint8_t(uint32_t)> read_byte;   // the chip's 22-bit space
  // ABLATIONS, for attributing a difference to one feature. All off is MAME.
  bool no_eg = false;        // envelope held at full scale, key-off stops at once
  bool fmt8 = false;         // every sample read as 8-bit
  bool no_interp = false;    // current sample only
  bool no_lfo = false;       // vibrato and tremolo off (the RTL has no LFO)
  bool exact_step = false;   // step = (4096 + 4*pitch) shifted, no float table
  // rtl_mix: level and pan as m2_multipcm does them (6 dB level steps, shift
  // pan, gain >> 12, chip sum >> 2) and TL without its slew - the parts the
  // RTL does not model - so everything else can be compared bit for bit.
  bool rtl_mix = false;

  static uint32_t fx(uint32_t bits, float v) { return uint32_t(float(1 << bits) * v); }

  explicit MultiPcmRef(float clock) {
    rate = clock / 224.0f;
    static const double BASE_TIMES[64] = {
      0,0,0,0, 6222.95,4978.37,4148.66,3556.01, 3111.47,2489.21,2074.33,1778.00,
      1555.74,1244.63,1037.19,889.02, 777.87,622.31,518.59,444.54, 388.93,311.16,259.32,222.27,
      194.47,155.60,129.66,111.16, 97.23,77.82,64.85,55.60, 48.62,38.91,32.43,27.80,
      24.31,19.46,16.24,13.92, 12.15,9.75,8.12,6.98, 6.08,4.90,4.08,3.49,
      3.04,2.49,2.13,1.90, 1.72,1.41,1.18,1.04, 0.91,0.73,0.59,0.50, 0.45,0.45,0.45,0.45 };
    for (int level = 0; level < 0x80; ++level) {
      const float vol_db = (float)level * (-24.0f) / 64.0f;
      const float total_level = powf(10.0f, vol_db / 20.0f) / 4.0f;
      for (int pan = 0; pan < 0x10; ++pan) {
        float pl, pr;
        if (pan == 0x8) { pl = 0.0; pr = 0.0; }
        else if (pan == 0x0) { pl = 1.0; pr = 1.0; }
        else if (pan & 0x8) {
          pl = 1.0; const int inv = 0x10 - pan; const float db = (float)inv * (-12.0f) / 4.0f;
          pr = pow(10.0f, db / 20.0f); if ((inv & 0x7) == 7) pr = 0.0;
        } else {
          pr = 1.0; const float db = (float)pan * (-12.0f) / 4.0f;
          pl = pow(10.0f, db / 20.0f); if ((pan & 0x7) == 7) pl = 0.0;
        }
        lpan[(pan << 7) | level] = fx(TL_SHIFT, pl * total_level);
        rpan[(pan << 7) | level] = fx(TL_SHIFT, pr * total_level);
      }
    }
    for (int i = 0; i < 0x400; ++i) freq_step[i] = fx(TL_SHIFT, rate * (1024.0f + (float)i) / 1024.0f);
    for (int i = 4; i < 0x40; ++i) {
      attack_step[i] = (float)(0x400 << EG_SHIFT) / (float)(BASE_TIMES[i] * 44100.0 / 1000.0);
      decay_step[i]  = (float)(0x400 << EG_SHIFT) / (float)(BASE_TIMES[i] * 14.32833 * 44100.0 / 1000.0);
    }
    attack_step[0]=attack_step[1]=attack_step[2]=attack_step[3]=0; attack_step[0x3f] = 0x400 << EG_SHIFT;
    decay_step[0]=decay_step[1]=decay_step[2]=decay_step[3]=0;
    tl_steps[0] = -(float)(0x80 << TL_SHIFT) / (78.2f * 44100.0f / 1000.0f);
    tl_steps[1] =  (float)(0x80 << TL_SHIFT) / (78.2f * 2 * 44100.0f / 1000.0f);
    for (int i = 0; i < 0x400; ++i) {
      const float db = -(96.0f - (96.0f * (float)i / (float)0x400));
      lin2exp[i] = fx(TL_SHIFT, powf(10.0f, db / 20.0f));
    }
    static const float PSL[8] = {0.0f,3.378f,5.065f,6.750f,10.114f,20.170f,40.180f,79.307f};
    static const float ASL[8] = {0.0f,0.4f,0.8f,1.5f,3.0f,6.0f,12.0f,24.0f};
    for (int i = 0; i < 256; ++i) {
      pitch_table[i] = i < 64 ? i*2+128 : i < 128 ? 383-i*2 : i < 192 ? 384-i*2 : i*2-383;
      amp_table[i] = i < 128 ? 255-(i*2) : (i*2)-256;
    }
    for (int t = 0; t < 8; ++t) {
      for (int i = -128; i < 128; ++i) {
        const float value = (PSL[t] * (float)i) / 128.0f;
        pitch_scale[t][i+128] = fx(LFO_SHIFT, powf(2.0f, value / 1200.0f));
      }
      for (int i = 0; i < 256; ++i) {
        const float value = (-ASL[t] * (float)i) / 256.0f;
        amp_scale[t][i] = fx(LFO_SHIFT, powf(10.0f, value / 20.0f));
      }
    }
  }

  void init_sample(Sample &s, uint32_t index) {
    uint32_t a = index * 12;
    s.start = (read_byte(a) << 16) | (read_byte(a+1) << 8) | read_byte(a+2);
    s.format = (s.start >> 20) & 0xfe;
    s.start &= 0x3fffff;
    s.loop = (read_byte(a+3) << 8) | read_byte(a+4);
    s.end = 0x10000 - ((read_byte(a+5) << 8) | read_byte(a+6));
    s.ar = (read_byte(a+8) >> 4) & 0xf; s.d1r = read_byte(a+8) & 0xf;
    s.d2r = read_byte(a+9) & 0xf; s.dl = (read_byte(a+9) >> 4) & 0xf;
    s.rr = read_byte(a+10) & 0xf; s.krs = (read_byte(a+10) >> 4) & 0xf;
    s.lfo_vib = read_byte(a+7); s.lfo_am = read_byte(a+11) & 0xf;
  }
  uint32_t get_rate(const uint32_t *steps, int32_t r, uint32_t val) {
    if (val == 0) return steps[0];
    if (val == 0xf) return steps[0x3f];
    return steps[std::clamp(4 * (int)val + r, 0, 0x3f)];
  }
  void eg_calc(Slot &sl) {
    int32_t oct = sl.octave; if (oct & 8) oct -= 16;
    int32_t r = (sl.s.krs != 0xf) ? (oct + sl.s.krs) * 2 + ((sl.pitch >> 9) & 1) : 0;
    sl.eg.ar  = get_rate(attack_step, r, sl.s.ar);
    sl.eg.d1r = get_rate(decay_step, r, sl.s.d1r);
    sl.eg.d2r = get_rate(decay_step, r, sl.s.d2r);
    sl.eg.rr  = get_rate(decay_step, r, sl.s.rr);
    sl.eg.dl  = 0xf - sl.s.dl;
  }
  int32_t eg_update(Slot &sl) {
    Eg &e = sl.eg;
    switch (e.state) {
    case ATTACK:
      e.volume += e.ar;
      if (e.volume >= (0x3ff << EG_SHIFT)) {
        e.state = DECAY1;
        if (e.d1r >= (0x400 << EG_SHIFT)) e.state = DECAY2;
        e.volume = 0x3ff << EG_SHIFT;
      }
      break;
    case DECAY1:
      e.volume -= e.d1r; if (e.volume <= 0) e.volume = 0;
      if (e.volume >> (EG_SHIFT + 6) <= e.dl) e.state = DECAY2;
      break;
    case DECAY2:
      e.volume -= e.d2r; if (e.volume <= 0) e.volume = 0;
      break;
    case RELEASE:
      e.volume -= e.rr; if (e.volume <= 0) { e.volume = 0; sl.playing = false; }
      break;
    }
    return no_eg ? lin2exp[0x3ff] : lin2exp[e.volume >> EG_SHIFT];
  }
  void update_step(Slot &sl) {
    const uint8_t oct = (sl.octave - 1) & 0xf;
    uint32_t p = freq_step[sl.pitch];
    if (exact_step) {
      p = 4096 + 4 * sl.pitch;
      if (oct & 0x8) p >>= (16 - oct); else p <<= oct;
      sl.step = p; return;
    }
    if (oct & 0x8) p >>= (16 - oct); else p <<= oct;
    sl.step = p / rate;
  }
  void retrigger(Slot &sl) {
    sl.offset = 0; sl.prev = 0; sl.tl = sl.dest_tl << TL_SHIFT;
    eg_calc(sl); sl.eg.state = ATTACK; sl.eg.volume = 0;
  }
  void lfo_compute_step(Lfo &l, uint32_t f, uint32_t sc, bool am) {
    static const float LFO_FREQ[8] = {0.168f,2.019f,3.196f,4.206f,5.215f,5.888f,6.224f,7.066f};
    float st = (float)LFO_FREQ[f] * 256.0f / (float)rate;
    l.phase_step = uint32_t(float(1 << LFO_SHIFT) * st);
    l.table = am ? amp_table : pitch_table;
    l.scale = am ? amp_scale[sc] : pitch_scale[sc];
  }
  int32_t lfo_step(Lfo &l) {
    l.phase += l.phase_step;
    int32_t p = l.table[(l.phase >> LFO_SHIFT) & 0xff];
    p = l.scale[p];
    return p << (TL_SHIFT - LFO_SHIFT);
  }
  void write_slot(Slot &sl, int reg, uint8_t data) {
    sl.regs[reg] = data;
    switch (reg) {
    case 0: sl.pan = (data >> 4) & 0xf; break;
    case 1:
      init_sample(sl.s, sl.regs[1] | ((sl.regs[2] & 1) << 8));
      write_slot(sl, 6, sl.s.lfo_vib);
      write_slot(sl, 7, sl.s.lfo_am);
      if (sl.playing) retrigger(sl);
      break;
    case 2: case 3:
      sl.octave = sl.regs[3] >> 4;
      sl.pitch = ((sl.regs[3] & 0xf) << 6) | (sl.regs[2] >> 2);
      update_step(sl);
      break;
    case 4:
      if (data & 0x80) { sl.playing = true; retrigger(sl); }
      else if (sl.playing) {
        if (sl.s.rr != 0xf && !no_eg) sl.eg.state = RELEASE; else sl.playing = false;
      }
      break;
    case 5:
      sl.dest_tl = (data >> 1) & 0x7f;
      if (!(data & 1)) sl.tl_step = ((sl.tl >> TL_SHIFT) > sl.dest_tl) ? tl_steps[0] : tl_steps[1];
      else sl.tl = sl.dest_tl << TL_SHIFT;
      break;
    case 6: case 7:
      sl.lfo_freq = (sl.regs[6] >> 3) & 7; sl.vibrato = sl.regs[6] & 7; sl.tremolo = sl.regs[7] & 7;
      if (data) { lfo_compute_step(sl.plfo, sl.lfo_freq, sl.vibrato, false);
                  lfo_compute_step(sl.alfo, sl.lfo_freq, sl.tremolo, true); }
      break;
    }
  }
  void write(int offset, uint8_t data) {
    static const int32_t V2C[32] = {0,1,2,3,4,5,6,-1, 7,8,9,10,11,12,13,-1, 14,15,16,17,18,19,20,-1, 21,22,23,24,25,26,27,-1};
    switch (offset) {
    case 0: if (cur_slot < 28) write_slot(slots[cur_slot], address, data); break;   // MAME would index slot -1
    case 1: cur_slot = (uint32_t)V2C[data & 0x1f]; break;
    case 2: address = (data > 7) ? 7 : data; break;
    }
  }
  // One output sample. Per-voice sample values are returned through `voice`
  // when it is non-null (the value summed before panning), for voice diffs.
  void step(int32_t &outl, int32_t &outr, int32_t *voice = nullptr) {
    int32_t smpl = 0, smpr = 0;
    for (int v = 0; v < 28; ++v) {
      Slot &sl = slots[v];
      if (voice) voice[v] = 0;
      if (!sl.playing) continue;
      uint32_t vol = (sl.tl >> TL_SHIFT) | (sl.pan << 7);
      uint32_t spos = sl.offset >> TL_SHIFT;
      uint32_t st = sl.step;
      int32_t cs = 0;
      int32_t fpart = sl.offset & ((1 << TL_SHIFT) - 1);
      if (sl.reverse) spos = sl.s.end - spos - 1;
      if ((sl.s.format & 4) && !fmt8) {
        uint32_t adr = (sl.s.start + (spos >> 1) * 3) & 0x3fffff;
        if (!(spos & 1)) { int16_t w0 = (int16_t)(read_byte(adr) << 8 | ((read_byte((adr + 1) & 0x3fffff) & 0xf) << 4)); cs = w0; }
        else { int16_t w0 = (int16_t)((read_byte((adr + 2) & 0x3fffff) << 8) | (read_byte((adr + 1) & 0x3fffff) & 0xf0)); cs = w0; }
      } else {
        cs = (int16_t)(read_byte((sl.s.start + spos) & 0x3fffff) << 8);
      }
      int32_t sample = no_interp ? cs : (cs * fpart + sl.prev * ((1 << TL_SHIFT) - fpart)) >> TL_SHIFT;
      if (sl.vibrato && !no_lfo) { st = st * lfo_step(sl.plfo); st >>= TL_SHIFT; }
      sl.offset += st;
      if (spos ^ (sl.offset >> TL_SHIFT)) sl.prev = cs;
      if (sl.offset >= (sl.s.end << TL_SHIFT)) { sl.offset -= (sl.s.end - sl.s.loop) << TL_SHIFT; sl.reverse = false; }
      if ((sl.tl >> TL_SHIFT) != sl.dest_tl) sl.tl += sl.tl_step;
      if (sl.tremolo && !no_lfo) { sample = sample * lfo_step(sl.alfo); sample >>= TL_SHIFT; }
      if (rtl_mix) {
        int32_t e = (int32_t)(int16_t)sample * eg_update(sl);
        int16_t es = (int16_t)(e >> 12);
        int16_t at = es >> ((sl.regs[5] >> 1) >> 4);
        auto pans = [&](int16_t x, bool left) -> int16_t {
          const int pan = sl.pan;
          if (pan == 8) return 0;
          if (pan == 0) return x;
          if (!(pan & 8)) { if (!left) return x; if (pan == 7) return 0; return x >> ((pan + 1) >> 1); }
          const int dist = (16 - pan) & 15;
          if (left) return x; if (dist == 7) return 0; return x >> ((dist + 1) >> 1);
        };
        if (voice) voice[v] = es;
        smpl += pans(at, true); smpr += pans(at, false);
        continue;
      }
      sample = (sample * eg_update(sl)) >> 10;
      if (voice) voice[v] = sample;
      smpl += (lpan[vol] * sample) >> TL_SHIFT;
      smpr += (rpan[vol] * sample) >> TL_SHIFT;
    }
    if (rtl_mix) { smpl >>= 2; smpr >>= 2; }
    outl = smpl; outr = smpr;
  }
};
