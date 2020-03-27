`timescale 1ns / 1ns
// SSB stands for Single Side Band.
// https://en.wikipedia.org/wiki/Single-sideband_modulation
// (Almost) pin compatible with second_if_out,
// but this one relies on interpolators (afterburner) to up-sample the output
// data to DDR so it can drive a double-frequency DAC.
//
// By appropriately setting a parameter this module can either output I and Q
// or a single drive signal.
//
// Directly uses the provided LO (cosa,sina), thus output IF will be determined by
// the LO frequency

module ssb_out #(
	parameter [15:0] AFTB_COEFF = 18646, // Coefficient to correct for the linear interpolation between
				             // two consecutive samples; see afterburner.v for details.
				             // Example based on FNAL test:
				             // 1313 MHz LO as timebase / 16 to get 82.0625 MHz ADC clk
				             // IF is 13 MHz, 16/101 = 0.1584 of ADC clk
				             // coeff = ceil(32768*0.5*sec(2*pi*16/101/2))
	parameter IQ_OUT =1 // 0 - Single output; One DAC DDR output
			    // 1 - IQ output; Two DAC DDR outputs
) (
	input clk,
	input [1:0] div_state,      // div_state [0] I-Q signal
	input signed [17:0] drive,  // Baseband interleaved I-Q
	input enable,               // Set output on enable else 0
	// local oscillator
	input signed [17:0] cosa,
	input signed [17:0] sina,
	// DDR on both DACs
	output signed [15:0] dac1_out0,
	output signed [15:0] dac1_out1,
	output signed [15:0] dac2_out0, // Pair is unused when IQ_OUT=0
	output signed [15:0] dac2_out1
);

wire iq = div_state[0];

// Bring input I and Q to full data rate
wire signed [16:0] drive_i, drive_q;
fiq_interp interp(.clk(clk),
	.a_data(drive[17:2]), .a_gate(1'b1), .a_trig(iq),
	.i_data(drive_i), .q_data(drive_q));

wire signed [15:0] out1, out2;

// SSB modulation scheme (Hartley modulator) using dot-product for LSB selection:
// (I, Q) . (cos(wLO*t), sin(wLO*t)) = I*cos(wLO*t) + Q*cos(wLO*t)

// Second (optional) dot-product done against 90deg-rotated drive IQ to obtain quadrature component

// In-phase portion of SSB drive signal
flevel_set level1(.clk(clk),
	.cosd(cosa), .sind(sina),
	.i_data(drive_i), .i_gate(1'b1), .i_trig(1'b1),
	.q_data(drive_q), .q_gate(1'b1), .q_trig(1'b1),
	.o_data(out1));

wire signed [15:0] outk1 = enable ? out1 : 0;

wire [15:0] dac1_ob0, dac1_ob1;  // offset binary outputs from afterburner
afterburner afterburner1(.clk(clk),
	.data({outk1,1'b0}), .coeff(AFTB_COEFF),
	.data_out0(dac1_ob0), .data_out1(dac1_ob1));

assign dac1_out0 = {~dac1_ob0[15], dac1_ob0[14:0]};
assign dac1_out1 = {~dac1_ob1[15], dac1_ob1[14:0]};

generate if (IQ_OUT) begin : G_IQ_DRIVE

// Quadrature portion of SSB drive signal
flevel_set level2(.clk(clk),
	.cosd(cosa), .sind(sina),
	.i_data(drive_q), .i_gate(1'b1), .i_trig(1'b1),
	.q_data(~drive_i), .q_gate(1'b1), .q_trig(1'b1),
	.o_data(out2));

wire signed [15:0] outk2 = enable ? out2 : 0;


wire [15:0] dac2_ob0, dac2_ob1;  // offset binary outputs from afterburner
afterburner afterburner2(.clk(clk),
	.data({outk2,1'b0}), .coeff(AFTB_COEFF),
	.data_out0(dac2_ob0), .data_out1(dac2_ob1));

assign dac2_out0 = {~dac2_ob0[15], dac2_ob0[14:0]};
assign dac2_out1 = {~dac2_ob1[15], dac2_ob1[14:0]};

end endgenerate

// afterburner returns offset-binary DAC words, but this module uses signed
// (twos-complement) for its output.  Thus the conversions above.
endmodule
