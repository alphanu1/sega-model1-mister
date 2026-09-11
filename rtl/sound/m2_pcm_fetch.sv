// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// An eight-byte per-voice buffer in front of a MULTIPCM's sample fetch --
// AND A BYPASS, WHICH IS THE DEFAULT.
//
// WHY IT DEFAULTS OFF. The plain byte-per-fetch path -- this module doing
// nothing -- is the last arrangement the board reported as sounding like the
// game. It was slow, and slow was recognisable. Everything since has sounded
// wrong, and three separate REAL faults were found and fixed in that time
// without changing that: a second sample chip reading four megabytes past the
// samples (R92), a sample rate that followed memory latency (R91), and a
// one-line cache with a hit rate of zero. Fixing three real things and changing
// nothing audible means the fault that matters is in one of the stages added
// alongside them, not in anything they touched.
//
// So it is a parameter rather than a deletion. The cache is measured to work
// and is byte-exact in simulation over 109,140 reads; deleting it would throw
// that away along with the fault. Bypass restores what worked, then one stage
// at a time can be turned on against the board.
//
// WHAT IT DOES WHEN ENABLED. The chip asks for one byte and the controller
// returns four words, so seven of every eight were fetched and discarded. It
// also stalls its own slot counter while a fetch is outstanding, so that waste
// came straight off the sample rate. One line PER VOICE, because the chip
// round-robins 28 slots: consecutive fetches come from 28 unrelated streams,
// and a single shared line was measured to have a hit rate of zero.

`timescale 1ns/1ps

module m2_pcm_fetch #(
  parameter bit BYPASS = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // The chip's side. It holds c_req high and expects c_data valid in the SAME
  // cycle as c_ack -- `if (rom_req && rom_ack)` captures rom_data right there.
  input  logic        c_req,
  input  logic  [4:0] c_slot,
  input  logic [21:0] c_addr,
  output wire         c_ack,
  output wire   [7:0] c_data,

  // The memory's side: a four-word burst at an eight-byte-aligned address.
  output wire         m_req,
  output logic [21:3] m_addr,
  input  logic        m_ack,
  input  logic [63:0] m_data,

  output logic [15:0] dbg_mean_lat,
  output logic [15:0] dbg_miss_1k
);

  // ---------------------------------------------------------------- bypass
  // Request straight through, byte taken out of the burst combinationally --
  // exactly what the top level used to do inline.
  wire [7:0] by_data = m_data[{3'd0, c_addr[2:0]} * 8 +: 8];

  // ---------------------------------------------------------------- cached
  // THE LINE DATA IS A MEMORY, NOT 2,048 FLIP-FLOPS (R221). MLABs, because
  // the M10K blocks are all spoken for (553 of 553; two of these in M10K
  // took 4 and the fitter refused the design). Read registered: the word for the requesting slot is fetched on
  // the request's first cycle (F_LOOK) and held on the RAM's output while
  // the slot address stands, which it does for the whole request. A miss
  // writes the line and the same held address reads it back by F_ACK. One
  // cycle more per hit than the flip-flop version. Tags and valid bits stay
  // in registers: 32 x 20 bits, and the valid bits must clear at reset.
  (* ramstyle = "MLAB" *) logic [63:0] buf_q [32];
  logic [63:0] buf_rd;
  logic [21:3] tag_q [32];
  logic [31:0] val_q;
  logic        m_req_r, c_ack_r;

  wire hit = val_q[c_slot] && (tag_q[c_slot] == c_addr[21:3]);

  typedef enum logic [2:0] { F_IDLE, F_LOOK, F_FETCH, F_ARM, F_ACK } fst_t;
  fst_t st;

  logic [25:0] lat_acc;
  logic [15:0] lat_now;
  logic  [9:0] fetch_n;
  logic [15:0] miss_n;

  assign m_addr = c_addr[21:3];
  assign m_req  = BYPASS ? c_req : m_req_r;
  assign c_ack  = BYPASS ? m_ack : c_ack_r;
  assign c_data = BYPASS ? by_data
                         : buf_rd[{3'd0, c_addr[2:0]} * 8 +: 8];
  // The registered read, every cycle at the requesting slot.
  always_ff @(posedge clk) buf_rd <= buf_q[c_slot];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= F_IDLE; m_req_r <= 1'b0; c_ack_r <= 1'b0;
      lat_acc <= '0; lat_now <= '0; fetch_n <= '0; miss_n <= '0;
      dbg_mean_lat <= '0; dbg_miss_1k <= '0;
      // The tags are not cleared -- the valid bits are, which is the standing
      // rule about never clearing an array in reset.
      val_q <= 32'd0;
    end else begin
      c_ack_r <= 1'b0;
      case (st)
        F_IDLE: if (c_req) st <= F_LOOK;     // R221: the line word is being read
        F_LOOK: begin
          fetch_n <= fetch_n + 10'd1;
          if (fetch_n == 10'd1023) begin
            dbg_mean_lat <= lat_acc[25:10];   // /1024, as a shift
            dbg_miss_1k  <= miss_n;
            lat_acc <= '0;
            miss_n  <= '0;
          end
          if (hit) begin
            c_ack_r <= 1'b1;
            st      <= F_ACK;
          end else begin
            m_req_r <= 1'b1;
            lat_now <= 16'd0;
            miss_n  <= miss_n + 16'd1;
            st      <= F_FETCH;
          end
        end
        F_FETCH: begin
          if (!(&lat_now)) lat_now <= lat_now + 16'd1;
          if (m_ack) begin
            lat_acc       <= lat_acc + {10'd0, lat_now};
            buf_q[c_slot] <= m_data;
            tag_q[c_slot] <= c_addr[21:3];
            val_q[c_slot] <= 1'b1;
            m_req_r       <= 1'b0;
            st            <= F_ARM;
          end
        end
        // One cycle so the acknowledge lands with buf_q already written.
        F_ARM: begin
          c_ack_r <= 1'b1;
          st      <= F_ACK;
        end
        // The chip drops c_req on the acknowledge; waiting for that stops one
        // request being served twice.
        default: if (!c_req) st <= F_IDLE;
      endcase
    end
  end

endmodule
