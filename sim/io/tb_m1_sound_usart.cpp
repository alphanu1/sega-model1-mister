// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// The main board's uPD71051C, checked against i8251.cpp's state machine.
//
// What matters here is not that bytes go anywhere - nothing consumes them yet -
// but that TxRDY behaves as MAME's does, because TxRDY IS IRQ LEVEL 3 and the
// games drain their sound queues on it. Two properties carry that:
//
//   - the DB buffer is DOUBLE BUFFERED. data_w clears TX_READY and
//     check_for_tx_start() sets it straight back if the shifter was idle, so a
//     write to an idle transmitter leaves TxRDY HIGH and raises the interrupt
//     again. That is the drain loop. Modelling it as a plain busy flag would
//     drain one byte per unmask instead of one per character.
//   - TxRDY is gated by TxEN. Before the game writes its command byte the line
//     must read low, or level 3 fires during initialisation.

#include "Vm1_sound_usart.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

// Must match the RTL default: 10 bits at 31.25 kbit/s against a 16 MHz V60.
static const int CHAR_CLKS = 5120;

struct Usart {
  Vm1_sound_usart* d;
  long ready_events = 0;
  Usart() {
    d = new Vm1_sound_usart;
    d->clk = 0; d->ce = 1; d->rst_n = 0;
    d->sel = 0; d->we = 0; d->a = 0; d->be = 3; d->wdata = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
  }
  ~Usart() { delete d; }
  void tick() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    if (d->ready_ev) ready_events++;
  }
  void wr(int addr, uint8_t v) { wr_held(addr, v, 1); }
  // The bus holds `we` for the WHOLE transaction, several cycles - m_req stays
  // up until it sees the acknowledge. `cycles` is how many.
  void wr_held(int addr, uint8_t v, int cycles) {
    d->sel = 1; d->we = 1; d->a = addr; d->wdata = v;
    for (int i = 0; i < cycles; i++) tick();
    // The bus always drops m_req before the next transaction - B_ACK holds the
    // acknowledge until it does - so there is at least one idle cycle between
    // two writes. The edge detector in the DUT depends on that; model it.
    d->sel = 0; d->we = 0; tick();
  }
  uint16_t rd(int addr) { d->a = addr; d->eval(); return d->rdata; }
  uint8_t status() { return rd(1) & 0xff; }
  void run(int n) { for (int i = 0; i < n; i++) tick(); }
  // Mode byte then command byte, the order an i8251 demands after reset.
  void configure(uint8_t command) { wr(1, 0x4e); wr(1, command); }
};

static long checks = 0, fails = 0;
static void chk(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

static const uint8_t ST_TXRDY = 0x01, ST_TXEMPTY = 0x04;

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: reset state is buffer free, shifter idle, line disabled\n");
  {
    Usart u;
    chk((u.status() & ST_TXRDY) != 0,   "TX_READY set at reset");
    chk((u.status() & ST_TXEMPTY) != 0, "TX_EMPTY set at reset");
    // txrdy_r() is is_tx_enabled() && TX_READY, and TxEN is still 0.
    chk(u.d->txrdy == 0, "the interrupt line is low until TxEN is written");
  }

  printf("test: TxEN gates the line, not the status bit\n");
  {
    Usart u;
    chk(u.d->txrdy == 0, "disabled");
    u.configure(0x01);                     // TxEN
    chk(u.d->txrdy == 1, "TxEN raises it with the buffer free");
    chk((u.status() & ST_TXRDY) != 0, "and the status bit was set all along");
  }

  printf("test: a write to an idle transmitter leaves TxRDY UP\n");
  {
    // start_tx() moves the byte to the shifter inside data_w, so the buffer is
    // free again immediately. This is what lets the queue pump run.
    Usart u;
    u.configure(0x01);
    u.wr(0, 0x42);
    chk(u.d->txrdy == 1, "still ready right after the write");
    chk((u.status() & ST_TXEMPTY) == 0, "but the shifter is busy");
  }

  printf("test: the SECOND byte waits, and TxRDY drops until the shifter frees\n");
  {
    Usart u;
    u.configure(0x01);
    u.wr(0, 0x11);                         // into the shifter
    u.wr(0, 0x22);                         // into the buffer
    chk(u.d->txrdy == 0, "buffer full: line down");

    u.run(CHAR_CLKS - 8);
    chk(u.d->txrdy == 0, "still down part way through the character");

    u.run(64);
    chk(u.d->txrdy == 1, "up again once the character completed");
    chk((u.status() & ST_TXEMPTY) == 0, "the queued byte is now shifting");

    u.run(CHAR_CLKS + 8);
    chk((u.status() & ST_TXEMPTY) != 0, "and empty once that one finishes too");
  }

  printf("test: a character takes CHAR_CLKS clock enables, not fewer\n");
  {
    Usart u;
    u.configure(0x01);
    u.wr(0, 0x11);
    u.wr(0, 0x22);
    int n = 0;
    while (!u.d->txrdy && n < CHAR_CLKS * 3) { u.tick(); n++; }
    chk(n > CHAR_CLKS - 64 && n < CHAR_CLKS + 64, "one character time, within a few clocks");
  }

  printf("test: ce gates the character timer\n");
  {
    // The timer is a ratio of the CPU, so with the clock enable low nothing
    // may advance - otherwise the sound pacing detaches from the game's.
    Usart u;
    u.configure(0x01);
    u.wr(0, 0x11);
    u.wr(0, 0x22);
    u.d->ce = 0;
    u.run(CHAR_CLKS * 2);
    chk(u.d->txrdy == 0, "no progress with ce low");
    u.d->ce = 1;
    u.run(CHAR_CLKS + 64);
    chk(u.d->txrdy == 1, "and it resumes when ce returns");
  }

  printf("test: every state change pulses ready_ev, as update_tx_ready() is called\n");
  {
    Usart u;
    u.configure(0x01);
    long before = u.ready_events;
    u.wr(0, 0x42);
    chk(u.ready_events == before + 1, "the write is one event");
    before = u.ready_events;
    u.run(CHAR_CLKS + 64);
    chk(u.ready_events == before + 1, "the character boundary is another");
  }

  // THIS IS THE ONE THAT NEARLY SHIPPED WRONG. Every other consumer on this bus
  // takes `we` as a level held for the whole transaction because its writes are
  // idempotent; a USART's are not, and a level-held write launched a character
  // per cycle - four bytes and four interrupts from one `mov.b`.
  printf("test: a write held for the whole transaction transmits ONE character\n");
  {
    Usart u;
    u.configure(0x01);
    long before = u.ready_events;
    u.wr_held(0, 0x42, 5);               // five cycles, as the bus would
    chk(u.ready_events == before + 1, "one update_tx_ready, not five");
    chk(u.d->txrdy == 1, "buffer still free: nothing was queued behind it");

    // And it really is one character on the wire, not five: after a single
    // character time the shifter must be idle.
    u.run(CHAR_CLKS + 64);
    chk((u.status() & ST_TXEMPTY) != 0, "idle after exactly one character");
  }

  printf("test: two writes separated by the bus dropping we are two characters\n");
  {
    Usart u;
    u.configure(0x01);
    u.wr_held(0, 0x11, 3);
    u.wr_held(0, 0x22, 3);
    chk(u.d->txrdy == 0, "the second one queued behind the first");
    u.run(CHAR_CLKS * 2 + 128);
    chk((u.status() & ST_TXEMPTY) != 0, "both gone after two character times");
  }

  printf("test: an internal reset command returns it to expecting a mode byte\n");
  {
    Usart u;
    u.configure(0x01);
    chk(u.d->txrdy == 1, "enabled");
    u.wr(1, 0x40);                          // command bit 6: internal reset
    chk(u.d->txrdy == 0, "TxEN cleared by the reset");
    u.wr(1, 0x4e);                          // taken as the mode byte again
    chk(u.d->txrdy == 0, "a mode byte does not enable");
    u.wr(1, 0x01);
    chk(u.d->txrdy == 1, "the command byte after it does");
  }

  printf("test: reads - status on the odd word, nothing ever received\n");
  {
    Usart u;
    u.configure(0x01);
    chk((u.rd(1) & 0xff00) == 0, "status is a byte in the low lane");
    chk((u.status() & 0x02) == 0, "RX_READY never sets: nothing transmits to us");
    chk(u.rd(0) == 0, "the data register reads back zero");
  }

  printf("test: a write with the low byte lane deselected is ignored\n");
  {
    Usart u;
    u.configure(0x01);
    u.d->be = 2;                            // high lane only
    u.wr(0, 0x42);
    chk((u.status() & ST_TXEMPTY) != 0, "nothing was transmitted");
    u.d->be = 3;
  }

  printf("m1_sound_usart: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
