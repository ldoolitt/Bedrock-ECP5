`timescale 1ns / 1ns
// Cascaded Differentiator and post-filter
//  also includes a barrel shifter to adjust scale to compensate
//  for changing decimation intervals
module ccfilt #(
	parameter dw=32,  // data width of mon_chan output:
		// should be CIC input data width (18),
		// plus 2 * log2(max sample period)
	parameter outw=20,  // output data width
		// comments below assume outw == 20
		// outw must be 20 if using half-band filter
	parameter shift_wi=4,
	parameter shift_base=0,
	parameter dsr_len = 12,  // expected length of strobe pattern
	parameter use_hb = 1,  // compile-time conditional half-band code
	parameter use_delay = 0  // match pipeline length with use_hb case
) (
	input clk,
	// unprocessed double-integrator output
	input [dw-1:0] sr_in,
	input sr_valid,

	// semi-static configuration
	input [shift_wi-1:0] shift,  // controls scaling of result

	// filtered and scaled result, ready for storage
	output signed [outw-1:0] result,
	input reset,
	output strobe
);

// Two stages of differentiator
wire valid2;
wire signed [dw-1:0] d2;
doublediff #(.dw(dw), .dsr_len(dsr_len)) diff(.clk(clk),
	.d_in(sr_in), .g_in(sr_valid), .d_out(d2), .g_out(valid2));

// Reduce bit width for entry to half-band filter
// First get 21 bits, then see below
reg signed [outw:0] d3=0;
reg ovf=0;
`define UNIFORM(x) ((~|(x)) | &(x))  // All 0's or all 1's
// Lowest supported filter is R=4 (for which we set shift=0), and N=2 always.
// Input to CIC is 18 bits, so maximum 22 bits come out.
// Check for overflow is a simulation-only feature to check for bugs.

// Invent some extra bits, just so the case statement is all legal Verilog,
// even if dw is less than 36.
// This construction should not result in any actual extra hardware.
localparam dwmax = outw+16+shift_base;
wire signed [dwmax:0] d2e = {{dwmax+1-dw{d2[dw-1]}},d2};
wire [shift_wi:0] full_shift = shift + shift_base;
wire [dwmax:0] d2es = d2e >>> full_shift;
always @(posedge clk) begin
	d3 <= d2es;
	ovf <= ~ `UNIFORM(d2es[dwmax:outw]);
end
reg valid3=0;
always @(posedge clk) valid3 <= valid2;

`ifdef SIMULATE
reg [3:0] ch_id=0;
reg signed [dw-1:0] d2_prev;
wire print_overflow = ovf & valid3;
always @(posedge clk) begin
	ch_id <= valid3 ? (ch_id+1) : 0;
	d2_prev <= d2;
end
always @(negedge clk) if (print_overflow) $display("overflow %d %x %x %d %d", shift, d2_prev, d3, ch_id, $time);
`endif

// Universal definition; note: old and new are msb numbers, not bit widths.
`define SAT(x,old,new) ((~|x[old:new] | &x[old:new]) ? x[new:0] : {x[old],{new{~x[old]}}})

// Factor of two scaling of output by virtue of the LO table construction.
// When properly set up, saturation will only occur with pathological LO choices and/or ADC clipping.
reg signed [outw-1:0] d4=0;
reg valid4=0;
always @(posedge clk) begin
	d4 <= `SAT(d3, outw, outw-1);
	valid4 <= valid3;
end

// Instantiate half-band filter .. or not
wire [outw-1:0] d5;
wire valid5;
reg [4-1:0] delay_v45=0;   // seems half_filter take 4 cycles?
reg [outw*4-1:0] delay_d45=0;
generate
if (use_hb) begin: g_use_hb
	half_filt #(.len(dsr_len))
		hb(.clk(clk), .ind(d4), .ing(valid4), .outd(d5), .outg(valid5), .reset(reset));
end
else if (use_delay) begin: g_use_delay
	always@(posedge clk) begin
		delay_v45 <= {delay_v45[4-2:0],valid4};
		delay_d45 <= {delay_d45[outw*(4-1)-1:0],d4};

	end
	assign d5 = delay_d45[outw*4-1:outw*(4-1)];
	assign valid5 = delay_v45[4-1];
end
else begin: g_use_short
	assign d5 = d4;
	assign valid5 = valid4;
end
endgenerate

assign strobe=valid5;
assign result=d5;
endmodule
