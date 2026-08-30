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
// The display-list walker: the front end of the 3D path.
//
// WHAT IT IS
//
// The V60 and the TGP build a display list in one of the two 32 K-word buffers at
// 0x600000 and 0x610000, and the geometry hardware walks it. This module is that
// walk: it reads the list a word at a time, decodes the command stream, and emits
// one typed event per parameter. It draws nothing and transforms nothing - the
// stages downstream of it do that - so it can be built and verified before any of
// them exist.
//
// It is `tgp_render`'s interpreter loop, model1_v.cpp:1451-1601, and nothing else.
//
// WHY THIS IS THE PIECE TO BUILD FIRST
//
// Because it is the piece that can be CHECKED. MAME logs every command it decodes
// under LOG_TGP - "draw object (%x, %x, %x)", "viewport (...)", "matrix (...)" -
// so our event stream diffs against the reference's exactly the way `v60_trace`
// and `tgp_trace` do. Every other stage of M3 needs floating-point geometry before
// it produces anything comparable; this one is comparable on its first run.
//
// It also answers a question that is open regardless of the rasterizer: whether
// our V60 builds a display list the reference would recognise at all. A walker
// that reaches `end` after two commands says the list is empty, and that is worth
// knowing before three more stages are built on top of it.
//
// THE STRIDES ARE THE WHOLE CORRECTNESS PROBLEM
//
// There is no framing and no length prefix: each command's size is implied by its
// type, so ONE wrong stride desynchronises everything after it and the remainder
// of the list decodes as garbage that still looks like plausible commands. That is
// the bug this module can have, and it is what the bench is built to catch.
//
// Two of them are easy to get wrong and are reproduced as MAME has them:
//
//   * command 4's length is `readi(+4) + 1`, commands 5 and 6 are `readi(+4)`.
//     The +1 is on the colour write ONLY. Not tidied - hard rule 4.
//   * command 3 reads its first parameter as a 32-bit word and the following six
//     as SINGLE 16-bit words at a two-word pitch, so words 5, 7, 9, 11, 13 and 15
//     of that command are skipped entirely. Reading them as 32-bit values gives a
//     viewport that is wrong and a stride that is right, which is the hardest
//     version of this bug to see.
//
// COMMAND 2 IS WALKED, NOT DECODED. `push_direct` carries quads already in screen
// space and its length is data-dependent - a loop over sub-records whose own type
// field says whether the next one is 12 or 20 words. The walk is implemented
// exactly (skip_direct, :1286) so the list stays in sync; emitting the quads
// themselves is the direct path's job and is not this module's.

`timescale 1ns/1ps

module m1_listwalk #(
  parameter int unsigned AW = 15          // 32 K words per display list buffer
) (
  input  logic        clk,
  input  logic        rst_n,

  // Start one walk. The caller pulses this once per frame, after it has decided
  // which buffer to read - the buffer select is the caller's, so this module has
  // no opinion about the listctl double-buffer handshake.
  input  logic        start,
  output logic        busy,
  output logic        done,               // one cycle, at the end of the list

  // Word-serial read port into the display list. Held request, so it can sit in
  // front of a RAM with any latency: the SDRAM path will need that even though
  // block RAM answers next cycle.
  output logic [AW-1:0] mem_addr,
  output logic          mem_req,
  input  logic          mem_valid,
  input  logic [15:0]   mem_data,

  // One event per decoded parameter. `kind` is the command's type byte, so a
  // consumer filters on it and ignores the rest; `idx` counts parameters within
  // the command and `data` is the value, sign-extended for the 16-bit ones.
  output logic          ev_valid,
  output logic [7:0]    ev_kind,
  output logic [15:0]   ev_idx,
  output logic [31:0]   ev_data,

  // Counted for the bench and the overlay. `cmds` distinguishes "the list is
  // empty" from "the walk never ran", which a silent module cannot.
  output logic [15:0]   dbg_cmds,
  output logic [15:0]   dbg_objects,
  output logic [15:0]   dbg_words,
  output logic          dbg_bad_type,       // hit a type the reference ends on
  output logic          dbg_overrun         // walked off the end of the buffer
);

  // Command types, from tgp_render's switch.
  localparam logic [7:0] C_NOP      = 8'h00;
  localparam logic [7:0] C_OBJECT   = 8'h01;
  localparam logic [7:0] C_DIRECT   = 8'h02;
  localparam logic [7:0] C_VIEWPORT = 8'h03;
  localparam logic [7:0] C_COLOR    = 8'h04;
  localparam logic [7:0] C_POLYRAM  = 8'h05;
  localparam logic [7:0] C_LIGHTP   = 8'h06;
  localparam logic [7:0] C_MODE     = 8'h07;
  localparam logic [7:0] C_SELECT   = 8'h08;
  localparam logic [7:0] C_ZOOM     = 8'h09;
  localparam logic [7:0] C_LIGHTV   = 8'h0a;
  localparam logic [7:0] C_MATRIX   = 8'h0b;
  localparam logic [7:0] C_TRANS    = 8'h0c;
  localparam logic [7:0] C_OBJHUD   = 8'h41;
  localparam logic [7:0] C_END      = 8'h0f;

  typedef enum logic [3:0] {
    S_IDLE, S_TYPE, S_DISPATCH, S_PARAM, S_BODY,
    S_DIR_FLAGS, S_NEXT, S_DONE
  } state_t;
  state_t st;

  // ONE BIT WIDER THAN THE BUFFER, deliberately: it is what makes running off the
  // end detectable instead of silently wrapping to word 0.
  logic [AW:0]   off;          // word offset of the command being decoded
  logic [AW-1:0] cur;          // word offset being read
  logic [7:0]    cmd;
  logic [23:0]   cmd_hi;      // the rest of the type word: nonzero ends the list
  logic [15:0]   p_idx;        // parameter index within the command
  logic [15:0]   p_n;          // how many parameters this phase has
  logic [AW-1:0] p_base;       // word offset of parameter 0
  logic          p_w32;        // 32-bit parameters, or single 16-bit ones
  logic [15:0]   body_len;     // items in a variable-length command
  logic [AW-1:0] stride;       // words to advance when the command is finished

  logic          p2;           // in a command's SECOND parameter phase
  logic          half;         // reading the high half of a 32-bit parameter
  logic [15:0]   lo;

  // ONE OUTSTANDING READ, and a cycle's gap between them.
  //
  // The alternative - hold mem_req and change mem_addr every cycle - is faster
  // and ambiguous: the walk changes its next address BASED on the word it just
  // received (a command's type picks its stride, a direct sub-record's flags pick
  // the next record), so a request issued before that word arrives is for an
  // address the walk may not want. Tracking the in-flight one would mean
  // discarding it, which is a pipeline this module does not need: a 32 K-word
  // list at two cycles a word is 65 K cycles of a 380 K-cycle frame.
  logic          rd_gap;

  assign busy     = (st != S_IDLE);
  assign mem_addr = cur;
  wire [AW-1:0] off_w = off[AW-1:0];

  wire in_read    = (st == S_TYPE) || (st == S_PARAM)
                 || (st == S_BODY) || (st == S_DIR_FLAGS);
  assign mem_req  = in_read && !rd_gap;

  // A word has arrived for the address we asked for. The gap is what makes that
  // unambiguous: after each accepted word the request drops for one cycle, so a
  // memory that answers a held request every cycle cannot deliver a second word
  // for an address the walk has already moved past.
  wire got = mem_req && mem_valid;

  // The item count of a variable-length command, available in the cycle its
  // second parameter completes. Command 4 counts one more item than it states -
  // MAME's `readi(+4) + 1` for the colour write against `readi(+4)` for commands
  // 5 and 6. That asymmetry is real; hard rule 4 says reproduce it.
  wire [15:0] body_n = (cmd == C_COLOR) ? (lo + 16'd1) : lo;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; off <= '0; cur <= '0; cmd <= '0; cmd_hi <= '0;
      rd_gap <= 1'b0;
      p_idx <= '0; p_n <= '0; p_base <= '0; p_w32 <= 1'b0; p2 <= 1'b0;
      body_len <= '0; stride <= '0; half <= 1'b0; lo <= '0;
      ev_valid <= 1'b0; ev_kind <= '0; ev_idx <= '0; ev_data <= '0;
      dbg_cmds <= '0; dbg_objects <= '0; dbg_words <= '0; dbg_bad_type <= 1'b0; dbg_overrun <= 1'b0;
      done <= 1'b0;
    end else begin
      ev_valid <= 1'b0;
      done     <= 1'b0;
      rd_gap   <= got;

      case (st)
        S_IDLE: begin
          if (start) begin
            off <= '0; cur <= '0; half <= 1'b0;
            dbg_cmds <= '0; dbg_objects <= '0; dbg_words <= '0;
            dbg_bad_type <= 1'b0; dbg_overrun <= 1'b0;
            st  <= S_TYPE;
          end
        end

        // The type is a 32-bit read, so two words, and only the low byte is
        // dispatched on - `case 0x41` is a byte value in a 32-bit field.
        S_TYPE: begin
          if (got) begin
            dbg_words <= dbg_words + 16'd1;
            if (!half) begin
              lo   <= mem_data;
              cur  <= cur + AW'(1);
              half <= 1'b1;
            end else begin
              half   <= 1'b0;
              cmd    <= lo[7:0];
              // THE TYPE IS COMPARED AS A FULL 32-BIT VALUE. `switch(readi(off))`
              // against `case 1`, not against a byte, so a word of 0x00010000 is
              // NOT a nop with rubbish in the top half - it matches no case, hits
              // `default` and ENDS the list. Dispatching on the low byte instead
              // decodes past the end of a list the reference stops at, and every
              // command after that point is invented.
              cmd_hi <= {mem_data, lo[15:8]};
              st     <= S_DISPATCH;
            end
          end
        end

        S_DISPATCH: begin
          p_idx  <= '0;
          p_base <= AW'(2);
          p_w32  <= 1'b1;
          p2     <= 1'b0;
          if (dbg_cmds != 16'hffff) dbg_cmds <= dbg_cmds + 16'd1;

          case (cmd_hi == 24'd0 ? cmd : 8'hff)
            C_NOP: begin
              stride <= AW'(2); st <= S_NEXT;
            end
            C_OBJECT, C_OBJHUD: begin
              p_n <= 16'd3; stride <= AW'(8);
              if (dbg_objects != 16'hffff) dbg_objects <= dbg_objects + 16'd1;
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            C_DIRECT: begin
              // push_direct/skip_direct: an 18-word header, then sub-records
              // until one has type 0 in its flags, then four more words.
              off <= off + (AW+1)'(18);
              cur <= off_w + AW'(18) + AW'(2);
              st  <= S_DIR_FLAGS;
            end
            C_VIEWPORT: begin
              p_n <= 16'd1; stride <= AW'(16);
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            C_COLOR, C_POLYRAM, C_LIGHTP: begin
              p_n <= 16'd2;                        // adr, len
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            C_MODE, C_SELECT: begin
              p_n <= 16'd1; stride <= AW'(4);
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            C_ZOOM, C_TRANS: begin
              p_n <= 16'd2; stride <= AW'(6);
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            C_LIGHTV: begin
              p_n <= 16'd3; stride <= AW'(8);
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            C_MATRIX: begin
              p_n <= 16'd12; stride <= AW'(26);
              cur <= off_w + AW'(2); st <= S_PARAM;
            end
            default: begin
              // 0x0f ends the list, and so does anything unrecognised: the
              // reference's `default` falls through to the same `goto end`, so
              // an unknown type is a terminator and not an error to recover
              // from. Flagged, because "the list ended early" and "the list
              // ended on garbage" are different faults.
              if (cmd != C_END || cmd_hi != 24'd0) dbg_bad_type <= 1'b1;
              st <= S_DONE;
            end
          endcase
        end

        // Header parameters: two words each, or one for the 16-bit form.
        S_PARAM: begin
          if (got) begin
            dbg_words <= dbg_words + 16'd1;
            if (p_w32 && !half) begin
              lo   <= mem_data;
              cur  <= cur + AW'(1);
              half <= 1'b1;
            end else begin
              half     <= 1'b0;
              ev_valid <= 1'b1;
              ev_kind  <= cmd;
              ev_idx   <= p_idx;
              // The 16-bit form is readi16, which returns int16_t - sign
              // extended, because a viewport edge is legitimately negative.
              ev_data  <= p_w32 ? {mem_data, lo}
                                : {{16{mem_data[15]}}, mem_data};

              if (p_idx + 16'd1 == p_n) begin
                // Header done. Commands with a body go on to it; the rest are
                // finished and advance by their fixed stride.
                case (cmd)
                  C_VIEWPORT: begin
                    // Phase two: six 16-bit words at +4, pitch 2.
                    //
                    // GUARDED BY p2, because this branch is reached on the last
                    // parameter of WHICHEVER phase just finished - and without
                    // the guard the second phase's completion starts a third,
                    // identical one, and the walk never leaves the command. That
                    // is a hang, not a wrong picture, so it shows up at once;
                    // the version of it that does not is a command whose phases
                    // differ, which is why the flag is explicit rather than
                    // inferred from p_base.
                    if (!p2) begin
                      p2     <= 1'b1;
                      p_idx  <= 16'd0; p_n <= 16'd6;
                      p_base <= AW'(4); p_w32 <= 1'b0;
                      cur    <= off_w + AW'(4);
                      st     <= S_PARAM;
                    end else begin
                      st <= S_NEXT;
                    end
                  end
                  C_COLOR, C_POLYRAM, C_LIGHTP: begin
                    // `len` is parameter 1, and command 4 counts one more item
                    // than it states. MAME: `readi(+4) + 1` for the colour
                    // write, `readi(+4)` for the other two. Deliberate.
                    // `len` is parameter 1's low 16 bits, which is `lo` - the
                    // half latched first. Reading mem_data here would take the
                    // HIGH half and give a length of zero on every real list.
                    body_len <= body_n;
                    stride   <= AW'(6) + AW'(body_n << 1);
                    p_idx    <= 16'd0;
                    p_base   <= AW'(6);
                    p_w32    <= (cmd != C_COLOR);   // command 4's items are 16-bit
                    cur      <= off_w + AW'(6);
                    st       <= S_BODY;
                  end
                  default: st <= S_NEXT;
                endcase
              end else begin
                p_idx <= p_idx + 16'd1;
                cur   <= off_w + p_base + AW'((p_idx + 16'd1) << 1);
              end
            end
          end
        end

        // Variable-length bodies: `body_len` items, same two-word pitch.
        S_BODY: begin
          if (body_len == 16'd0) begin
            st <= S_NEXT;
          end else if (got) begin
            dbg_words <= dbg_words + 16'd1;
            if (p_w32 && !half) begin
              lo   <= mem_data;
              cur  <= cur + AW'(1);
              half <= 1'b1;
            end else begin
              half     <= 1'b0;
              ev_valid <= 1'b1;
              ev_kind  <= cmd;
              ev_idx   <= p_idx;
              ev_data  <= p_w32 ? {mem_data, lo} : {16'd0, mem_data};
              if (p_idx + 16'd1 == body_len) begin
                st <= S_NEXT;
              end else begin
                p_idx <= p_idx + 16'd1;
                cur   <= off_w + p_base + AW'((p_idx + 16'd1) << 1);
              end
            end
          end
        end

        // The direct path's sub-record walk. Only the flags word is read; the
        // quads themselves are not this module's to emit.
        S_DIR_FLAGS: begin
          if (got) begin
            dbg_words <= dbg_words + 16'd1;
            // flags = readi(off+2); only bits 1:0 matter for the walk, and they
            // are in the low word.
            if (mem_data[1:0] == 2'b00) begin
              stride <= AW'(4);              // the trailing four words
              st     <= S_NEXT;
            end else if (mem_data[1:0] == 2'b10) begin
              off <= off + (AW+1)'(12);
              cur <= off_w + AW'(12) + AW'(2);
            end else begin
              off <= off + (AW+1)'(20);
              cur <= off_w + AW'(20) + AW'(2);
            end
          end
        end

        S_NEXT: begin
          // THE BUFFER'S END IS A TERMINATOR, and it has to be, because the
          // reference has none: readi masks with 0x7fff, so a list of nothing but
          // nops walks forever and MAME loops forever with it. Real lists always
          // terminate, so this cannot fire on one - but in hardware "never
          // terminates" is a walker holding busy for good, and a display path
          // that cannot recover from a corrupt list is worse than one that gives
          // up on it. Flagged, so it is visible rather than a silent truncation.
          if ((off + {1'b0, stride}) >= (AW+1)'(1 << AW)) begin
            dbg_overrun <= 1'b1;
            st          <= S_DONE;
          end else begin
            off <= off + {1'b0, stride};
            cur <= off_w + stride;
            st  <= S_TYPE;
          end
        end

        S_DONE: begin
          done <= 1'b1;
          st   <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
