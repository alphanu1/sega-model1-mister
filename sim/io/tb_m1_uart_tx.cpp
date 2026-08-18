// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The UART transmitter, decoded by an independent receiver.
//
// The point of this channel is that a wrong byte is INVISIBLE — it arrives on a
// terminal as a plausible character and there is nothing to compare it against.
// So the check is a receiver written from the 8N1 definition rather than from the
// transmitter's structure: sample at the middle of each bit time, verify the start
// bit, take eight data bits LSB first, verify the stop bit is high.

#include "Vm1_uart_tx.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static const int DIV = 694;          // 80 MHz / 115200

static long checks = 0, fails = 0;

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_uart_tx;
  std::mt19937 rng(20260818u);

  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst_n = 0; d->wr = 0; d->din = 0;
  for (int i = 0; i < 8; i++) tick();
  d->rst_n = 1;

  // Idle must be high, or a receiver sees a permanent break.
  checks++;
  if (!d->tx) { printf("  FAIL idle line is low\n"); fails++; }

  // Queue a spread of bytes including the two that break a shifter written with
  // the wrong fill: 0x00 leaves the line low through all eight data bits and 0xff
  // leaves it high, so a missing start or stop bit is invisible on one of them and
  // obvious on the other.
  std::vector<uint8_t> sent = {0x00, 0xff, 0x55, 0xaa, 0x41, 0x7f, 0x80, 0x01};
  for (int i = 0; i < 24; i++) sent.push_back((uint8_t)rng());

  size_t next_in = 0;
  std::vector<uint8_t> got;
  long cyc = 0;
  int  prev = 1;

  // Receiver state
  bool in_frame = false;
  long frame_start = 0;
  uint8_t acc = 0;

  while (got.size() < sent.size() && cyc < 4000000) {
    // Feed the FIFO whenever it has room.
    d->wr = 0;
    if (next_in < sent.size() && !d->full) {
      d->wr = 1; d->din = sent[next_in++];
    }
    tick(); cyc++;
    d->wr = 0;

    if (!in_frame && prev == 1 && d->tx == 0) {   // falling edge = start bit
      in_frame = true; frame_start = cyc; acc = 0;
    } else if (in_frame) {
      long off = cyc - frame_start;
      for (int b = 0; b < 8; b++) {
        if (off == (long)DIV * (b + 1) + DIV / 2) acc |= (uint8_t)(d->tx << b);
      }
      if (off == (long)DIV * 9 + DIV / 2) {
        checks++;
        if (!d->tx) { printf("  FAIL stop bit low for byte %zu\n", got.size()); fails++; }
        got.push_back(acc);
        in_frame = false;
      }
    }
    prev = d->tx;
  }

  checks++;
  if (got.size() != sent.size()) {
    printf("  FAIL received %zu of %zu bytes\n", got.size(), sent.size());
    fails++;
  }
  for (size_t i = 0; i < got.size() && i < sent.size(); i++) {
    checks++;
    if (got[i] != sent[i]) {
      if (fails < 8)
        printf("  FAIL byte %zu got %02x want %02x\n", i, got[i], sent[i]);
      fails++;
    }
  }

  // Overflow must be reported and must not wedge the transmitter: a debug channel
  // that stalls the design it is instrumenting is worse than no channel.
  checks++;
  if (d->overflow) { printf("  FAIL overflow set on a run that never overfilled\n"); fails++; }
  for (int i = 0; i < 2000; i++) { d->wr = 1; d->din = (uint8_t)i; tick(); }
  d->wr = 0;
  checks++;
  if (!d->overflow) { printf("  FAIL overflow not reported after flooding\n"); fails++; }
  long before = 0;
  for (int i = 0; i < 200000; i++) { tick(); if (!d->tx) before++; }
  checks++;
  if (before == 0) { printf("  FAIL transmitter stopped after an overflow\n"); fails++; }

  printf("m1_uart_tx: checks=%ld fails=%ld bytes=%zu\n", checks, fails, got.size());
  delete d;
  return fails ? 1 : 0;
}
