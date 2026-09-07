`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2' — SDRAM_CLK, 80 MHz with a TUNABLE PHASE.
	//
	// SDRAM_CLK was `~clk_sys` assigned to the pin: a fixed 180-degree inversion
	// through fabric routing, with no phase to adjust. The established MiSTer
	// recipe sources the generated clock from a PLL OUTPUT precisely so the phase
	// CAN be adjusted - "typically ranging between -0.5 ns and -2.5 ns" - and that
	// is the one knob the whole constrained-SDRAM method turns on.
	//
	// 6250 ps is exactly half of the 12500 ps period, so this starts out
	// bit-identical to the inversion it replaces. Changing it is then a one-line
	// experiment instead of a redesign.
	output wire outclk_2,
	// The 3D layer's clock. Exactly twice outclk_1 (clk_cpu), so the crossing
	// between them is a clock enable rather than a handshake - this project has
	// lost time twice to pulse-versus-level faults across domains, and a
	// synchronous ratio removes that class of bug instead of testing for it.
	//
	// 53.333 and not 80: THE TGP IS THE LIMIT, not the 3D units -- see below
	// once m1_fp_pool's operand mux is registered, so 80 still does not close.
	// It was 47.059, held down by the pool's unregistered mux at 39.6 MHz.
	// Measured, not assumed.
	//
	// AND 53.333 RATHER THAN 54, BECAUSE THE PLL CANNOT MAKE 54. Every output
	// is an integer divisor of the 800 MHz VCO -- 80 = 800/10, 23.529412 =
	// 800/34, 47.058824 = 800/17 -- so asking for a round 54.0 fails the fit
	// with "output_clock_frequency is set to an illegal value". 57.142857 is
	// 800/14 and 28.571429 is 800/28, which keeps the exact 2x tie.
	//
	// 800/14 AND 800/28 -- 57.143 / 28.571 -- WAS TRIED AND FAILS TIMING, and
	// not where anyone expected. m1_geometry reaches 59.36 MHz and
	// m1_raster_fill 58.84, both clear of 57.143. What misses is the
	// COPROCESSOR: mb86233_core|state.S_DST_W -> state.S_DST and -> S_LABB, at
	// -1.256 ns with TNS -2.820, so two or three paths. m1_tgp is dual-clock
	// and its core runs on clk_3d, deliberately at 2x clk_cpu to give the
	// coprocessor two cycles per CPU cycle, so raising clk_3d clocks the TGP
	// faster too and its state machine is now the ceiling.
	//
	// The TGP's in-core ceiling is therefore between 53.333, which closes with
	// +1.166 ns, and 57.143, which does not. Going higher means shortening that
	// state transition first. m1_geo_walk is the 3D side's own next limit at
	// 59.36, and m1_raster_fill's 58.84 after that.
	//
	// EVERY OUTPUT IS AN INTEGER DIVISION OF THE SAME 800 MHz VCO, which is what
	// makes the ratios exact rather than approximate:
	//
	//     800/10 = 80.000    clk_sys and the SDRAM pin
	//     800/17 = 47.059    clk_3d
	//     800/34 = 23.529    clk_cpu, an exact half of clk_3d
	//
	// This is why 23.000 was rejected earlier as "not a legal PLL output": with
	// 80 MHz fixed, the VCO is 800 and 800/23 is not an integer. 800/34 is the
	// smallest step at or above 23.
	output wire outclk_3,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("80.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("33.333333 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("80.000000 MHz"),
		.phase_shift2("6250 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("66.666667 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

