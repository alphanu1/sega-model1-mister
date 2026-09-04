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
// THE I/O BOARD AS A COMPUTER, NOT AN IMITATION (study R60).
//
// Sega's Model 1 I/O board -- the same physical PCB in Model 1 cabinets and in
// model2o cabinets, Daytona included -- is a Z80 running EPR-14869. Studies
// R37-R41 imitated its observed behaviour and stalled exactly where the board
// COMPUTES rather than responds: the credit digits on the settings splash are
// arithmetic the firmware performs on data the game round-trips through the
// dual-port RAM. So this runs the firmware.
//
// The map and devices are taken from MAME (model1io.cpp, 315_5338a.cpp,
// msm6253.cpp), which is this project's ruling reference:
//
//   0x0000-0x3fff  firmware ROM (first 16 KB of the 64 KB EPROM; no banking)
//   0x4000-0x5fff  8 KB work RAM
//   0x8000-0x800f  Sega 315-5338A I/O custom
//   0xc000-0xc003  OKI MSM6253 ADC, 4 channels, serial MSB-first readout
//
// THE DPRAM IS BEHIND THE 315-5338A, not memory-mapped: the Z80 sets a 16-bit
// address through commands 0x00/0x01 (low/high from the serial-output
// register), writes dpram[addr] with command 0x07, writes dpram[0..7] directly
// with commands 0x70-0x77, and reads dpram[addr] at register 0x0c. That
// byte-at-a-time shape is exactly the exchange the DPRAM traces always showed.
//
// 315-5338A ports, per model1io.cpp's bindings:
//   PB (1) / PC (2) / PD (3)  <- IN0 / IN1 / IN2, or DSW1-3 when the firmware
//                                selects SECONDARY controls with PA bit 0.
//                                No longer deferred: the multiplex is
//                                implemented, and the oracle that closed it was
//                                the UART, not the input test -- see the note
//                                on `secondary` below.
//   PE (4)                    <- drive board (absent: 0xff)
//   PF (5)                    -> output latch (lamps etc.; latched, unused)
//   PG (6)                    <- button board / EEPROM DO (absent: 0xff)
//
// CEN_DIV pacing: the real Z80 runs at 32 MHz / 8 = 4 MHz, which is clk_sys /
// 12. The firmware's power-on delays (R40 measured them as ~0.12 s and ~3.0 s)
// are Z80 delay loops, so they now come from the program itself rather than
// from two magic constants. Simulation may pace CEN faster; the semantics are
// unchanged, only the seconds compress.

`timescale 1ns/1ps

module m1_ioz80 #(
  parameter int unsigned CEN_DIV = 12
) (
  input  logic        clk,
  input  logic        rst_n,

  // THE FIRMWARE LIVES IN SDRAM, NOT IN BLOCK RAM.
  //
  // 16 KB as 8192 x 16 is SIXTEEN M10K - an M10K is 8192 deep at one bit wide,
  // so a 16-bit word costs one block per bit - and with the work RAM's eight
  // and a read port on the shared RAM the board wants 26 of the 17 this design
  // has left. The firmware is the natural thing to move: it is read-only, and
  // the Z80 is slow enough to wait.
  //
  // A ONE-WORD CACHE, because the Z80 reads two bytes out of every word it
  // fetches. That halves the traffic for a handful of flops, which matters:
  // the V60 already stalls on memory for half its cycles and that is what
  // limits the frame rate in busy scenes, so the I/O board must not become a
  // third heavy reader. If it still shows, a line cache is the next step and
  // this is the shape it would extend.
  output logic        fw_req,
  output logic [12:0] fw_word,   // 16-bit word index inside the 16 KB
  input  logic        fw_ack,
  input  logic [15:0] fw_din,

  // Cabinet inputs, ACTIVE LOW at rest (0xff = nothing pressed), matching
  // model2.cpp's port definitions: IN0 = {VR3,VR2,VR1,START1,SERVICE,TEST,
  // COIN2,COIN1}, IN1 bits 6:4 = gearbox (ACTIVE HIGH), bit 0 = VR4.
  input  logic  [7:0] in0,
  input  logic  [7:0] in1,
  input  logic  [7:0] in2,
  // THE I/O BOARD'S OWN DIP BANKS, WHICH ARE NOT THE GAME'S. This board
  // carries three 8-way switches of its own (model1io.h: required_ioport_array
  // <3> m_dsw) and the firmware reaches them by MULTIPLEXING PB/PC/PD -- see
  // `secondary` below. Daytona defines all 24 bits PORT_DIPUNUSED_DIPLOC with
  // the default equal to the mask, so every bank reads 0xFF.
  input  logic  [7:0] dsw1,
  input  logic  [7:0] dsw2,
  input  logic  [7:0] dsw3,
  // BUSY from the DPRAM, so the firmware's status waits mean something. See the
  // note in m1_ioboard: with a constant status the firmware never waits and
  // refills the window under the game's feet.
  input  logic        dp_busy,
  input  logic  [7:0] adc0,   // steering, centre 0x80
  input  logic  [7:0] adc1,   // accelerator, idle 0x20
  input  logic  [7:0] adc2,   // brake, idle 0x20
  input  logic  [7:0] adc3,

  // Dual-port RAM, the Z80's side. Byte-addressed, 2 KB.
  output logic        z_we,
  output logic [10:0] z_addr,
  output logic  [7:0] z_wdata,
  input  logic  [7:0] z_rdata,

  // Debug: last DPRAM command write, and the output latch.
  output logic  [7:0] dbg_ee,    // {cs, clk, di, do, st[2:0], ewen}
  output logic [15:0] dbg_wrcnt,  // {io-write strobes, any-write strobes}
  output logic        dbg_wr_stb,
  output logic  [7:0] dbg_dout,
  output logic  [7:0] dbg_di,
  output logic        dbg_rd_end,
  output logic [15:0] dbg_ra,
  output logic  [7:0] dbg_rdat,
  output logic        dbg_m1_n,
  output logic [15:0] dbg_a,
  output logic [15:0] dbg_last_wr,   // {addr[7:0], data}
  output logic  [7:0] dbg_pf,
  // THE CONTROL SWITCH, ON THE WIRE. Bit 0 of PA decides whether PB/PC/PD carry
  // the cabinet inputs or the board's DIP banks, and whether the firmware ever
  // throws it is the load-bearing question -- so it is reported rather than
  // reasoned about. The count saturates instead of wrapping: "many" and "a few"
  // are different answers and a wrap would confuse them.
  output logic  [7:0] dbg_pa,
  output logic [15:0] dbg_seccnt
);

  // ------------------------------------------------------------ Z80 pacing
  logic [$clog2(CEN_DIV)-1:0] cen_ctr;
  logic cen;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin cen_ctr <= '0; cen <= 1'b0; end
    else begin
      cen     <= (cen_ctr == '0);
      cen_ctr <= (cen_ctr == ($clog2(CEN_DIV))'(CEN_DIV - 1)) ? '0 : cen_ctr + 1'b1;
    end
  end

  // ------------------------------------------------------------ the CPU
  logic [15:0] A;
  logic  [7:0] di, dout;
  logic        mreq_n, rd_n, wr_n;

  tv80s u_z80 (
    // STALLED BY ITS CLOCK ENABLE, NOT BY wait_n.
    //
    // wait_n was tried first and the Z80 fetched word 0 twice and stopped:
    // tv80 samples wait_n inside a memory cycle against its own paced clock,
    // and a combinational ~miss is not stable there. Holding `cen` low is the
    // blunt instrument and the right one - the core simply does not advance,
    // which is exactly what a CPU waiting on memory does, and it needs no
    // assumption about which T-state samples what.
    .reset_n(rst_n), .clk(clk), .cen(cen && !fw_miss),
    .wait_n(1'b1), .int_n(1'b1), .nmi_n(1'b1), .busrq_n(1'b1),
    .m1_n(dbg_m1_n), .mreq_n(mreq_n), .iorq_n(), .rd_n(rd_n), .wr_n(wr_n),
    .rfsh_n(), .halt_n(), .busak_n(),
    .A(A), .di(di), .dout(dout)
  );

  assign dbg_a = A;
  wire mem_rd = !mreq_n && !rd_n;
  wire mem_wr = !mreq_n && !wr_n;

  // ONE EVENT PER STROBE. Under CEN pacing the Z80 holds rd/wr for many clk
  // cycles; acting on the level would repeat every side effect. The habit is
  // R43's: act on the edge, never the level.
  logic mem_wr_d, mem_rd_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin mem_wr_d <= 1'b0; mem_rd_d <= 1'b0; end
    else begin mem_wr_d <= mem_wr; mem_rd_d <= mem_rd; end
  end
  // COMMIT ON THE TRAILING EDGE, WITH LATCHED OPERANDS. At the strobe's
  // leading edge tv80 has not yet settled dout -- observed as "ld (hl),n"
  // storing the byte before its operand -- and by the trailing edge A may be
  // moving on. So A and dout are latched every cycle the strobe is high and
  // the commit happens once, at its end, from the latches.
  logic [15:0] aw_l;
  logic  [7:0] dw_l;
  always_ff @(posedge clk) if (mem_wr) begin aw_l <= A; dw_l <= dout; end
  wire wr_stb = !mem_wr && mem_wr_d;   // trailing edge; aw_l/dw_l hold truth
  wire rd_end = !mem_rd && mem_rd_d;   // read completed: safe to shift

  // ------------------------------------------------------------ ROM and RAM
  // Registered reads settle within one 48 MHz cycle; the Z80 samples many
  // cycles later under CEN pacing, so no wait states are needed.
  // The firmware is NOT here any more - see the fetch below. Only the work RAM
  // is on chip, and it has to be: it is the Z80's stack.
  (* ramstyle = "M10K" *) logic [7:0] ram [8192];
  // NEGEDGE READS, and this is load-bearing. tv80 drives A on a rising CEN
  // edge and samples data against later rising edges of the same paced clock;
  // a posedge-registered read hands it fw[PREVIOUS A] at every sampling point
  // -- observed directly as `ld (hl),n` storing the byte BEFORE its operand.
  // Reading on the falling edge puts fresh data on the bus half a cycle after
  // the address, which is the async-ROM shape every T80-family design expects,
  // and M10K clocks on either edge without complaint.
  logic [15:0] fw_w;
  logic  [7:0] ram_q;
  logic  [7:0] fw_q;
  // ONE EDGE, for the same reason as the work RAM below: a posedge write against
  // a negedge read makes this a dual-clock M10K whose read-during-write Quartus
  // declares UNDEFINED on silicon and Verilator models as defined. The download
  // and execution do not overlap in practice, so this one is unlikely to bite --
  // but "unlikely" is how the work RAM's version would have been described too,
  // and an undefined array holding the firmware is not worth keeping for the
  // sake of half a cycle.
  // The fetch, with its one-word cache. `fw_hit` is what lets the Z80 run; a
  // miss holds wait_n low until the word arrives, which is the whole reason
  // the core's wait_n is no longer tied high.
  logic        fw_cv;                 // the cache holds a valid word
  logic [12:0] fw_ca;                 // and this is its address
  wire         fw_sel  = mem_rd && (A[15:14] == 2'b00);
  wire         fw_hit  = fw_cv && (fw_ca == A[13:1]);
  wire         fw_miss = fw_sel && !fw_hit;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fw_cv <= 1'b0; fw_ca <= '0; fw_w <= '0; fw_req <= 1'b0;
    end else begin
      // Held until acknowledged, not pulsed. Anything talking to this
      // controller that pulses a request has it missed - the rule is in
      // CLAUDE.md and it has cost this project two sessions.
      if (fw_miss && !fw_req && !fw_ack) fw_req <= 1'b1;
      if (fw_ack) begin
        fw_req <= 1'b0;
        fw_w   <= fw_din;
        fw_ca  <= A[13:1];
        fw_cv  <= 1'b1;
      end
    end
  end
  assign fw_word = A[13:1];
  assign fw_q    = A[0] ? fw_w[15:8] : fw_w[7:0];
  // WRITE ON THE SAME EDGE AS THE READ, AND THAT IS THE POINT.
  //
  // This wrote on posedge while the read below happens on negedge, so Quartus
  // inferred a DUAL-CLOCK M10K and said what that costs:
  //
  //   Warning (276027): Inferred dual-clock RAM node "m1_ioz80|ram_rtl_0" ...
  //   The read-during-write behavior of a dual-clock RAM is UNDEFINED and may
  //   not match the behavior of the original design.
  //
  // Undefined on silicon, well-defined in Verilator -- so the Z80 can read back
  // a byte it has just written and get one answer here and another on the
  // board. This is the firmware's own work RAM: its DPRAM retry budget lives at
  // 0x5803 (R63) along with every other piece of its state, and it is read and
  // written constantly.
  //
  // Moving the write to the falling edge makes the array single-clock, which
  // gives it DEFINED read-during-write, and costs nothing else: aw_l and dw_l
  // are already latched and stable, and the Z80 is paced at CEN_DIV=12 so half
  // a cycle of write delay is invisible to it. The read keeps the async-ROM
  // shape tv80 needs -- data half a cycle after the address.
  always_ff @(negedge clk) begin
    if (wr_stb && aw_l[15:13] == 3'b010) ram[aw_l[12:0]] <= dw_l;   // 0x4000-0x5fff
  end
  always_ff @(negedge clk) ram_q <= ram[A[12:0]];

  // ------------------------------------------------------------ 315-5338A
  logic [15:0] io_address;     // the DPRAM address, built by commands 0x00/0x01
  logic [10:0] z_addr_r;
  logic  [7:0] ser_out;        // register 0x0a, the datum commands consume
  logic  [7:0] cmd_r;          // register 0x0b reads it back
  logic  [7:0] port_out [8];   // latched output ports (PA, PF, ...)
  logic  [7:0] dir_r;

  // THE CONTROL SWITCH, and it is why the settings block was never right.
  //
  // model1io.cpp, io_pa_w:  "-------0  control switch (0 = first, 1 = second)"
  // and every input port is muxed on it:
  //
  //     io_pb_r() { return m_secondary_controls ? m_dsw[0]->read() : m_in_cb[0](0); }
  //
  // This file previously returned the cabinet inputs UNCONDITIONALLY, and said
  // so -- the multiplex was recorded above as deferred "until the game's own
  // INPUT TEST screen can serve as the oracle". The UART became that oracle
  // first: DPRAM 0x100, which holds "SEGA...", was caught alternating with
  // 7F FF -- idle analog and idle digital, i.e. the SCAN pattern written where
  // the settings belong. The firmware selects secondary, we hand it controls
  // instead of switches, and the game rejects the block and reissues forever.
  //
  // No new register: PA writes already land in port_out[0], which is exactly
  // where MAME takes the bit from.
  wire secondary = port_out[0][0];

  wire io_sel  = (A[15:4] == 12'h800);   // 0x8000-0x800f
  wire adc_sel = (A[15:2] == 14'h3000);  // 0xc000-0xc003
  // ONE PULSE AT THE READ'S LEADING EDGE. See the ADC block below for why the
  // shift is bound to this rather than to the read's end.
  wire adc_rd_start = mem_rd && !mem_rd_d && adc_sel;

  // Reads. dpram reads go through z_rdata: z_addr tracks io_address
  // continuously, the DPRAM's registered read settles long before the paced
  // Z80 samples it, and io_address only changes via commands.
  logic [7:0] io_q;
  always_comb begin
    io_q = 8'hff;
    case (A[3:0])
      4'h0: io_q = port_out[0];
      4'h1: io_q = secondary ? dsw1 : in0;   // PB
      4'h2: io_q = secondary ? dsw2 : in1;   // PC
      4'h3: io_q = secondary ? dsw3 : in2;   // PD
      4'h4: io_q = 8'hff;            // PE: drive board absent
      4'h5: io_q = port_out[5];      // PF: output latch reads back
      4'h6: io_q = {ee_do, 7'h7f};   // PG bit 7: EEPROM DO
      4'h8: io_q = dir_r;
      4'ha: io_q = ser_out;
      4'hb: io_q = cmd_r;
      4'hc: io_q = z_rdata;          // dpram[io_address]
      // STATUS. CONSTANT 0x08, which is what MAME's 315_5338a.cpp returns:
      //
      //     case 0x0d:   // 7654---- unknown, ----3--- transfer finished?
      //                  // -----21- unknown, -------0 command acknowledged
      //        data = 0x08;
      //
      // Bit 0 is "command acknowledged" and ZERO is the acknowledgement. A
      // previous version drove it from a real busy signal, on the reasoning
      // that a dual-port RAM has one - and on Model 1 that DEADLOCKS. The V60
      // polls the shared RAM continuously while it waits for this board, so a
      // busy bit derived from the game's accesses is set almost always; the
      // firmware then waits for an acknowledgement that only arrives when the
      // game stops polling, and the game only stops when the firmware answers.
      // Each side waits for the other. Measured: the firmware read this
      // register 254,982 times in 100 M cycles and never moved on.
      4'hd: io_q = 8'h08;
      default: ;
    endcase
  end

  // Writes, including the DPRAM command path.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      io_address <= 16'd0; ser_out <= 8'd0; cmd_r <= 8'd0; dir_r <= 8'd0;
      z_we <= 1'b0; z_wdata <= 8'd0; z_addr_r <= 11'd0; dbg_last_wr <= 16'd0;
      dbg_seccnt <= 16'd0;
      for (int i = 0; i < 8; i++) port_out[i] <= 8'd0;
    end else begin
      z_we <= 1'b0;
      if (wr_stb && aw_l[15:4] == 12'h800) begin
        case (aw_l[3:0])
          4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: begin
            port_out[aw_l[2:0]] <= dw_l;
            if (aw_l[3:0] == 4'h0 && dw_l[0] && !(&dbg_seccnt))
              dbg_seccnt <= dbg_seccnt + 16'd1;
          end
          4'h8: dir_r <= dw_l;
          4'h9: begin
            cmd_r <= dw_l;
            case (dw_l)
              8'h00: io_address[7:0]  <= ser_out;
              8'h01: io_address[15:8] <= ser_out;
              8'h07: begin
                z_we <= 1'b1; z_wdata <= ser_out; z_addr_r <= io_address[10:0];
                dbg_last_wr <= {io_address[7:0], ser_out};
              end
              8'h70, 8'h71, 8'h72, 8'h73,
              8'h74, 8'h75, 8'h76, 8'h77: begin
                z_we <= 1'b1; z_wdata <= ser_out; z_addr_r <= {8'd0, dw_l[2:0]};
                dbg_last_wr <= {5'd0, dw_l[2:0], ser_out};
              end
              default: ;   // 0x87 arms serial reception; reads already work
            endcase
          end
          4'ha: ser_out <= dw_l;
          default: ;
        endcase
      end
    end
  end

  // The z-port address travels WITH the write it belongs to -- registered in
  // the same cycle as z_we, so a command's address cannot be replaced under it.
  // Reads keep the port pointed at io_address continuously.
  assign z_addr = z_we ? z_addr_r : io_address[10:0];
  assign dbg_pf = port_out[5];
  assign dbg_pa = port_out[0];

  // ------------------------------------------------------------ 93C46 EEPROM
  // The board's own settings store, bit-banged by the firmware through the
  // 315-5338A: PA7 = CLK, PA6 = CS, PA5 = DI, PG7 = DO (model1io.cpp io_pa_w).
  // The boot spins forever retrying the serial read if this is absent, which
  // is how it announced itself. 93C46 in 16-bit mode: 64 words; start bit,
  // 2-bit opcode, 6-bit address; READ shifts a dummy 0 then 16 bits MSB-first.
  // Powers up erased (all-ones): the firmware finds a virgin part, applies its
  // defaults, and writes them back -- so WRITE/ERASE/EWEN are implemented, not
  // just READ. Contents are volatile here; persistence can ride the NVRAM
  // mechanism later if board-local settings turn out to matter.
  logic [15:0] ee  [64];
  logic        ee_do;
  logic  [8:0] ee_sh;         // start + opcode + address collector
  logic  [3:0] ee_nbits;
  logic [16:0] ee_out;        // dummy 0 + 16 data bits
  logic [15:0] ee_in;
  logic  [4:0] ee_wcnt;
  logic        ee_ewen;
  logic  [5:0] ee_addr;
  typedef enum logic [2:0] {EE_CMD, EE_READ, EE_WRITE, EE_DONE} ee_st_t;
  ee_st_t ee_st;
  wire ee_clk = port_out[0][7];
  wire ee_cs  = port_out[0][6];
  wire ee_di  = port_out[0][5];
  logic ee_clk_d;
  initial for (int i = 0; i < 64; i++) ee[i] = 16'hffff;
`ifdef VERILATOR
  // THE EEPROM HAS CONTENTS AND THEY MATTER. 93c45.bin is 128 bytes sitting in
  // vr.zip, and read as little-endian words its first two are 0x5345 0x4741 -
  // "SEGA", the same signature the V60 writes into the shared RAM. A firmware
  // that checks it against a blank device would loop exactly where this one
  // does. Simulation only for now; hardware needs a load path.
  initial $readmemh("build/rom/vr_ee_le.hex", ee);
`endif
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ee_do <= 1'b1; ee_sh <= 9'd0; ee_nbits <= 4'd0; ee_out <= 17'd0;
      ee_in <= 16'd0; ee_wcnt <= 5'd0; ee_ewen <= 1'b0; ee_addr <= 6'd0;
      ee_st <= EE_CMD; ee_clk_d <= 1'b0;
    end else begin
      ee_clk_d <= ee_clk;
      if (!ee_cs) begin
        ee_st <= EE_CMD; ee_nbits <= 4'd0; ee_sh <= 9'd0; ee_do <= 1'b1;
      end else if (ee_clk && !ee_clk_d) begin
        case (ee_st)
          EE_CMD: begin
            // Collect start + opcode + address. The start bit is the first 1.
            if (ee_sh == 9'd0 && !ee_di) ;   // still waiting for the start bit
            else begin
              ee_sh    <= {ee_sh[7:0], ee_di};
              ee_nbits <= ee_nbits + 4'd1;
              if (ee_nbits == 4'd8) begin
                // ee_sh[7:6] after this shift = opcode, [5:0] = address.
                ee_addr <= {ee_sh[4:0], ee_di};
                case (ee_sh[6:5])
                  2'b10: begin ee_st <= EE_READ;
                               ee_out <= {1'b0, ee[{ee_sh[4:0], ee_di}]}; end
                  2'b01: begin ee_st <= EE_WRITE; ee_wcnt <= 5'd0; end
                  2'b11: begin if (ee_ewen) ee[{ee_sh[4:0], ee_di}] <= 16'hffff;
                               ee_st <= EE_DONE; end
                  2'b00: begin ee_ewen <= (ee_sh[4:3] == 2'b11);
                               ee_st <= EE_DONE; end
                endcase
              end
            end
          end
          EE_READ: begin
            ee_do  <= ee_out[16];
            ee_out <= {ee_out[15:0], 1'b0};
          end
          EE_WRITE: begin
            ee_in   <= {ee_in[14:0], ee_di};
            ee_wcnt <= ee_wcnt + 5'd1;
            if (ee_wcnt == 5'd15) begin
              if (ee_ewen) ee[ee_addr] <= {ee_in[14:0], ee_di};
              ee_st <= EE_DONE;
            end
          end
          EE_DONE: ee_do <= 1'b1;   // ready/busy: high = ready
          default: ee_st <= EE_CMD;
        endcase
      end
    end
  end

  assign dbg_ee = {ee_cs, ee_clk, ee_di, ee_do, ee_st, ee_ewen};
  assign dbg_wr_stb = wr_stb;
  assign dbg_dout   = dout;
  assign dbg_di     = di;
  logic [15:0] ar_l; logic [7:0] dr_l;
  always_ff @(posedge clk) if (mem_rd) begin ar_l <= A; dr_l <= di; end
  assign dbg_rd_end = rd_end;
  assign dbg_ra     = ar_l;
  assign dbg_rdat   = dr_l;
  logic [7:0] wrc_io, wrc_any;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wrc_io <= 8'd0; wrc_any <= 8'd0; end
    else begin
      if (wr_stb && !(&wrc_any)) wrc_any <= wrc_any + 8'd1;
      if (wr_stb && io_sel && !(&wrc_io)) wrc_io <= wrc_io + 8'd1;
    end
  end
  assign dbg_wrcnt = {wrc_io, wrc_any};

  // ------------------------------------------------------------ MSM6253 ADC
  // address_w latches the selected channel into a shift register; d0_r shifts
  // it out MSB-first, one bit per read, in bit 0.
  // ATOMIC CAPTURE-THEN-SHIFT, because the two were separable and drifted.
  //
  // MEASURED ON HARDWARE, against MAME running the same firmware: every analog
  // byte the firmware deposited was its input shifted LEFT BY ONE.
  //
  //     DPRAM   board  MAME   fed in
  //     0x00     00     80    0x80     steering
  //     0x01     40     20    0x20     accelerator
  //     0x02     40     20    0x20     brake
  //     0x04-07  FE     FF    0xFF     the secondary bank
  //
  // Eight independent bytes, one relationship: the first read returned bit 6
  // instead of bit 7, so a shift happened between the channel latch and the
  // first read. This is R65's "ADC off-by-one", with a mechanism at last.
  //
  // The old shape emitted `adc_shift[7]` combinationally and shifted on the
  // read's TRAILING edge, which is two events that must agree exactly once per
  // read. The reference makes them one event:
  //
  //     bool msm6253_device::shift_out() {
  //       bool msb = BIT(m_shift_register, 7);
  //       m_shift_register <<= 1;
  //       return msb;
  //     }
  //
  // So capture and shift on the SAME edge and hold the bit for the read. Under
  // CEN pacing the Z80 samples many cycles after the strobe rises -- the same
  // assumption the registered ROM and RAM reads above already rest on -- so a
  // bit registered on the leading edge is settled long before it is latched.
  logic [7:0] adc_shift;
  logic       adc_bit;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin adc_shift <= 8'd0; adc_bit <= 1'b1; end
    else if (wr_stb && aw_l[15:2] == 14'h3000) begin
      case (aw_l[1:0])
        // "analog port switching is handled by two 74hc4066 analog switches"
        // -- model1io.cpp, and analogN_r picks an_cb[N+4] when secondary is
        // selected. model2o binds 0-2 only, so the secondary bank is unbound
        // and an unbound devcb_read8 reads 0xFF.
        2'd0: adc_shift <= secondary ? 8'hFF : adc0;
        2'd1: adc_shift <= secondary ? 8'hFF : adc1;
        2'd2: adc_shift <= secondary ? 8'hFF : adc2;
        2'd3: adc_shift <= secondary ? 8'hFF : adc3;
      endcase
    end else if (adc_rd_start) begin
      adc_bit   <= adc_shift[7];              // the bit this read returns
      adc_shift <= {adc_shift[6:0], 1'b0};    // and it is consumed by taking it
    end
  end

  // ------------------------------------------------------------ read mux
  always_comb begin
    di = 8'hff;
    if      (A[15:14] == 2'b00) di = fw_q;                    // 0x0000-0x3fff
    else if (A[15:13] == 3'b010) di = ram_q;                  // 0x4000-0x5fff
    else if (io_sel)             di = io_q;
    // d0_r returns the bit in position 0 with the unmapped bits reading as
    // ones: `shift_out() | (space.unmap() & 0xfe)`.
    else if (adc_sel)            di = {7'h7f, adc_bit};
  end

endmodule
