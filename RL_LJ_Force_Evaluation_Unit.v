/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Module: RL_LJ_Force_Evaluation_Unit.v
//
//	Function: Evaluate the LJ force of given datasets using 1st order interpolation (interpolation index is generated in Matlab (under Ethan_GoldenModel/Matlab_Interpolation))
// 			Including a set of Filters and a single Force evaluation pipeline
//				The module connected the Filter_Bank and Force_Evaluation_Pipeline together for easy implementation
//				The module also contains the delay register chain to pass the particle ID from r2_compute output along with the force output
//
//	Used by:
//				TBD
//
// Dependency:
// 			RL_LJ_Evaluate_Pairs_1st_Order.v
//				Filter_Bank.v
//					- Filter_Logic.v
//						-- r2_compute.v
//						-- Filter_Buffer.v
//					- Filter_Arbiter.v
//
// Latency:
//				r2_compute: 									17 cycles
//				RL_LJ_Pipeline_1st_Order: 					14 cycles
//				Filter_Arbiter:								0 cycle
//
// Created by: Chen Yang 10/15/18
//
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module RL_LJ_Force_Evaluation_Unit
#(
	parameter DATA_WIDTH 					= 32,
	parameter PARTICLE_ID_WIDTH			= 20,									// # of bit used to represent particle ID, 9*9*7 cells, each 4-bit, each cell have max of 200 particles, 8-bit
	// Filter parameters
	parameter NUM_FILTER						= 4,	// 8
	parameter ARBITER_MSB 					= 8,	//128								// 2^(NUM_FILTER-1)
	parameter FILTER_BUFFER_DEPTH 		= 32,
	parameter FILTER_BUFFER_ADDR_WIDTH	= 5,
	parameter CUTOFF_2 						= 32'h43100000,						// (12^2=144 in IEEE floating point)
	// Force Evaluation parameters
	parameter SEGMENT_NUM					= 14,
	parameter SEGMENT_WIDTH					= 4,
	parameter BIN_NUM							= 256,
	parameter BIN_WIDTH						= 8,
	parameter LOOKUP_NUM						= SEGMENT_NUM * BIN_NUM,			// SEGMENT_NUM * BIN_NUM
	parameter LOOKUP_ADDR_WIDTH			= SEGMENT_WIDTH + BIN_WIDTH		// log LOOKUP_NUM / log 2
)
(
	input clk,
	input rst,
	input [NUM_FILTER-1:0] input_valid,
	input [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] ref_particle_id,
	input [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] neighbor_particle_id,
	input [NUM_FILTER*DATA_WIDTH-1:0] refx,
	input [NUM_FILTER*DATA_WIDTH-1:0] refy,
	input [NUM_FILTER*DATA_WIDTH-1:0] refz,
	input [NUM_FILTER*DATA_WIDTH-1:0] neighborx,
	input [NUM_FILTER*DATA_WIDTH-1:0] neighbory,
	input [NUM_FILTER*DATA_WIDTH-1:0] neighborz,
	output [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] ref_particle_id_out,
	output [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_out,
	output [DATA_WIDTH-1:0] LJ_Force_X,
	output [DATA_WIDTH-1:0] LJ_Force_Y,
	output [DATA_WIDTH-1:0] LJ_Force_Z,
	output forceoutput_valid,
	
	output [NUM_FILTER-1:0] back_pressure_to_input			// If one of the FIFO is full, then set the back_pressure flag to stop more incoming particle pairs
);

	// Assign parameters for A, B, QQ (currently not used)
	wire [DATA_WIDTH-1:0] p_a;
	wire [DATA_WIDTH-1:0] p_b;
	wire [DATA_WIDTH-1:0] p_qq;
	assign p_a  = 32'h40000000;				// p_a = 2, in IEEE floating point format
	assign p_b  = 32'h40800000;				// p_b = 4, in IEEE floating point format
	assign p_qq = 32'h41000000;				// p_qq = 8, in IEEE floating point format

	// Wires connect Filter_Bank and RL_LJ_Evaluate_Pairs_1st_Order
	wire [DATA_WIDTH-1:0] r2;
	wire [DATA_WIDTH-1:0] dx;
	wire [DATA_WIDTH-1:0] dy;
	wire [DATA_WIDTH-1:0] dz;
	wire r2_valid;
	
	// Delay registers for particle IDs from r2_compute to force output
	wire [PARTICLE_ID_WIDTH-1:0] r2_compute_out_ref_particle_id;
	wire [PARTICLE_ID_WIDTH-1:0] r2_compute_out_neighbor_particle_id;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg0;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg1;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg2;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg3;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg4;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg5;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg6;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg7;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg8;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg9;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg10;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg11;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_reg12;
	reg [PARTICLE_ID_WIDTH-1:0] ref_particle_id_delayed;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg0;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg1;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg2;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg3;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg4;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg5;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg6;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg7;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg8;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg9;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg10;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg11;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_reg12;
	reg [PARTICLE_ID_WIDTH-1:0] neighbor_particle_id_delayed;
	// Assign output port
	assign ref_particle_id_out = ref_particle_id_delayed;
	assign neighbor_particle_id_out = neighbor_particle_id_delayed;
	// Delay register
	always@(posedge clk)
		begin
		if(rst)
			begin
			ref_particle_id_reg0 <= 0;
			ref_particle_id_reg1 <= 0;
			ref_particle_id_reg2 <= 0;
			ref_particle_id_reg3 <= 0;
			ref_particle_id_reg4 <= 0;
			ref_particle_id_reg5 <= 0;
			ref_particle_id_reg6 <= 0;
			ref_particle_id_reg7 <= 0;
			ref_particle_id_reg8 <= 0;
			ref_particle_id_reg9 <= 0;
			ref_particle_id_reg10 <= 0;
			ref_particle_id_reg11 <= 0;
			ref_particle_id_reg12 <= 0;
			ref_particle_id_delayed <= 0;
			neighbor_particle_id_reg0 <= 0;
			neighbor_particle_id_reg1 <= 0;
			neighbor_particle_id_reg2 <= 0;
			neighbor_particle_id_reg3 <= 0;
			neighbor_particle_id_reg4 <= 0;
			neighbor_particle_id_reg5 <= 0;
			neighbor_particle_id_reg6 <= 0;
			neighbor_particle_id_reg7 <= 0;
			neighbor_particle_id_reg8 <= 0;
			neighbor_particle_id_reg9 <= 0;
			neighbor_particle_id_reg10 <= 0;
			neighbor_particle_id_reg11 <= 0;
			neighbor_particle_id_reg12 <= 0;
			neighbor_particle_id_delayed <= 0;
			end
		else
			begin
			ref_particle_id_reg0 <= r2_compute_out_ref_particle_id;
			ref_particle_id_reg1 <= ref_particle_id_reg0;
			ref_particle_id_reg2 <= ref_particle_id_reg1;
			ref_particle_id_reg3 <= ref_particle_id_reg2;
			ref_particle_id_reg4 <= ref_particle_id_reg3;
			ref_particle_id_reg5 <= ref_particle_id_reg4;
			ref_particle_id_reg6 <= ref_particle_id_reg5;
			ref_particle_id_reg7 <= ref_particle_id_reg6;
			ref_particle_id_reg8 <= ref_particle_id_reg7;
			ref_particle_id_reg9 <= ref_particle_id_reg8;
			ref_particle_id_reg10 <= ref_particle_id_reg9;
			ref_particle_id_reg11 <= ref_particle_id_reg10;
			ref_particle_id_reg12 <= ref_particle_id_reg11;
			ref_particle_id_delayed <= ref_particle_id_reg12;
			neighbor_particle_id_reg0 <= r2_compute_out_neighbor_particle_id;
			neighbor_particle_id_reg1 <= neighbor_particle_id_reg0;
			neighbor_particle_id_reg2 <= neighbor_particle_id_reg1;
			neighbor_particle_id_reg3 <= neighbor_particle_id_reg2;
			neighbor_particle_id_reg4 <= neighbor_particle_id_reg3;
			neighbor_particle_id_reg5 <= neighbor_particle_id_reg4;
			neighbor_particle_id_reg6 <= neighbor_particle_id_reg5;
			neighbor_particle_id_reg7 <= neighbor_particle_id_reg6;
			neighbor_particle_id_reg8 <= neighbor_particle_id_reg7;
			neighbor_particle_id_reg9 <= neighbor_particle_id_reg8;
			neighbor_particle_id_reg10 <= neighbor_particle_id_reg9;
			neighbor_particle_id_reg11 <= neighbor_particle_id_reg10;
			neighbor_particle_id_reg12 <= neighbor_particle_id_reg11;
			neighbor_particle_id_delayed <= neighbor_particle_id_reg12;
			end
		end

	// Filters
	Filter_Bank
	#(
		.DATA_WIDTH(DATA_WIDTH),
		.NUM_FILTER(NUM_FILTER),
		.ARBITER_MSB(ARBITER_MSB),											// 2^(NUM_FILTER-1)
		.PARTICLE_ID_WIDTH(PARTICLE_ID_WIDTH),
		.FILTER_BUFFER_DEPTH(FILTER_BUFFER_DEPTH),
		.FILTER_BUFFER_ADDR_WIDTH(FILTER_BUFFER_ADDR_WIDTH),
		.CUTOFF_2(CUTOFF_2)													// (12^2=144 in IEEE floating point)
	)
	Filter_Bank
	(
		.clk(clk),
		.rst(rst),
		.input_valid(input_valid),
		.ref_particle_id(ref_particle_id),
		.neighbor_particle_id(neighbor_particle_id),
		.refx(refx),
		.refy(refy),
		.refz(refz),
		.neighborx(neighborx),
		.neighbory(neighbory),
		.neighborz(neighborz),
		.ref_particle_id_out(r2_compute_out_ref_particle_id),
		.neighbor_particle_id_out(r2_compute_out_neighbor_particle_id),
		.r2(r2),
		.dx(dx),
		.dy(dy),
		.dz(dz),
		.out_valid(r2_valid),
		.back_pressure_to_input(back_pressure_to_input)						// If one of the FIFO is full, then set the back_pressure flag to stop more incoming particle pairs
	);

	// Evaluate Pair-wise LJ forces
	// Latency 14 cycles
	RL_LJ_Evaluate_Pairs_1st_Order #(
		.DATA_WIDTH(DATA_WIDTH),
		.SEGMENT_NUM(SEGMENT_NUM),
		.SEGMENT_WIDTH(SEGMENT_WIDTH),
		.BIN_WIDTH(BIN_WIDTH),
		.BIN_NUM(BIN_NUM),
		.CUTOFF_2(CUTOFF_2),
		.LOOKUP_NUM(LOOKUP_NUM),
		.LOOKUP_ADDR_WIDTH(LOOKUP_ADDR_WIDTH)
	)
	RL_LJ_Evaluate_Pairs_1st_Order(
		.clk(clk),
		.rst(rst),
		.r2_valid(r2_valid),
		.r2(r2),
		.dx(dx),
		.dy(dy),
		.dz(dz),
		.p_a(p_a),
		.p_b(p_b),
		.p_qq(p_qq),
		.LJ_Force_X(LJ_Force_X),
		.LJ_Force_Y(LJ_Force_Y),
		.LJ_Force_Z(LJ_Force_Z),
		.LJ_force_valid(forceoutput_valid)
	);



endmodule