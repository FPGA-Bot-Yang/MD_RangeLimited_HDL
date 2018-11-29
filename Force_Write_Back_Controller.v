/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Module: Force_Write_Back_Controller.v
//
//	Function: 
//				Receive input from Force_Evaluation_Unit (both reference output and neighbor output), each cell has a independent controller module
//				Perform FORCE ACCUMULATION and WRITE BACK
//				Works on top of force_cache.v
//				If this is the home cell, then receive input from reference particle partial force output (when the neighbor particle is from homecell, then it's discarded since it will be evaluated one more time)
//				If this is a neighbor cell, then receive input from neighbor particle partial force output. (All cells taking input from the same evaluation unit output port, if this is the designated cell, then process; otherwise, discard)
//
// Special Attention:
//				The accumulation operation is inherently dependent on previous calculated result
//				If the new incoming forces requires to accumulate to a particle that is currently being processed in the pipeline, then need to push this new incoming force into a FIFO, until the accumulated force is write back into the force cache
//				Whenever the incoming force is not valid or not targeting this cell, look into the FIFO and process the previously buffered data
//				!!!!Future improvements: currently using a FIFO to buffer the data, if 2 consequtive values requires to accumulate to same particle, then the 2nd value will be hold for a full processing time (7-1=6 cycles), while the data comes after may be able to be processed but cannot be fetched out of the FIFO (head-of-the-line blocking).
//				!!!!Comment on the proposed improvements: this may not be a big issue, since: if the next to come value targeting different particle, then it will be processed immediately; if targeting the same particle: need to buffer it anyway.
//
// Input Buffer handling:
//				Since there is a one cycle delay between read request is assigned and the data is read out from FIFO, by the time system realize it need data from FIFO instead of using the input, it's already late to assign the read request signal.
//				To address this, there are 2 possible solutions: (choose Sol 2)
//				Sol 1: Each cycle the system always readout a data from FIFO as long as it's not empty, thus we always have a data ready on the output port of FIFO
//					Case 1: If the FIFO output is selected, while input is valid but not being used due to data dependency, then write back the input data;
//					Case 2: If the FIFO output is selected, while input is invalid, then write back nothing;
//					Case 3: If the FIFO output is not being used, while input is not valid, then write back the FIFO output;
//					Case 4: If the FIFO output is not being used, while the valid input is not being used either, we have 2 data need to write to FIFO, how to address this???????
//				Sol 2: Add one cycle delay to the data path: data selection phase to conpensate for the delay of reading out data from FIFO.
//
// Data Organization:
//				in_partial_force: {Force_Z, Force_Y, Force_X}
//				Force_Cache_Input_Buffer: {particle_id[CELL_ADDR_WIDTH-1:0], Force_Z, Force_Y, Force_X}
//
// Format:
//				particle_id [PARTICLE_ID_WIDTH-1:0]:  {cell_x, cell_y, cell_z, particle_in_cell_rd_addr}
//				ref_particle_position [3*DATA_WIDTH-1:0]: {refz, refy, refx}
//				neighbor_particle_position [3*DATA_WIDTH-1:0]: {neighborz, neighbory, neighborx}
//				LJ_Force [3*DATA_WIDTH-1:0]: {LJ_Force_Z, LJ_Force_Y, LJ_Force_X}
//
// Timing:
//				7 cycles: From the input of a valid result targeting this cell, till the accumulated value is successfully written into the force cache
//				Cycle 1: register input & read from input FIFO;
//				Cycle 2: select from input or input FIFO;
//				Cycle 3: read out current force;
//				Cycle 4-6: accumulation;
//				Cycle 7: write back force
//
// Used by:
//				RL_LJ_Top.v
//
// Dependency:
//				force_cache.v
//				FP_ADD.v (latency 3)
//
// Testbench:
//				RL_LJ_Top_tb.v
//
// To do:
//				0, Implement a buffer when there are more than 1 force evaluation units working at the same time. Cause each module may receive partial force from different evaluation units at the same time
//
// Created by:
//				Chen Yang 11/20/2018
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module Force_Write_Back_Controller
#(
	parameter DATA_WIDTH 					= 32,											// Data width of a single force value, 32-bit
	// Cell id this unit related to
	parameter CELL_X							= 2,
	parameter CELL_Y							= 2,
	parameter CELL_Z							= 2,
	// Force cache input buffer
	parameter FORCE_CACHE_BUFFER_DEPTH	= 16,
	parameter FORCE_CACHE_BUFFER_ADDR_WIDTH = 4,										// log(FORCE_CACHE_BUFFER_DEPTH) / log 2
	// Dataset defined parameters
	parameter CELL_ID_WIDTH					= 4,
	parameter MAX_CELL_PARTICLE_NUM		= 290,										// The maximum # of particles can be in a cell
	parameter CELL_ADDR_WIDTH				= 9,											// log(MAX_CELL_PARTICLE_NUM)
	parameter PARTICLE_ID_WIDTH			= CELL_ID_WIDTH*3+CELL_ADDR_WIDTH	// # of bit used to represent particle ID, 9*9*7 cells, each 4-bit, each cell have max of 220 particles, 8-bit
)
(
	input  clk,
	input  rst,
	// Cache input force
	input  in_partial_force_valid,
	input  [PARTICLE_ID_WIDTH-1:0] in_particle_id,
	input  [3*DATA_WIDTH-1:0] in_partial_force,
	// Cache output force
	input  in_read_data_request,																	// Enables read data from the force cache, if this signal is high, then no write operation is permitted
	input  [CELL_ADDR_WIDTH-1:0] in_cache_read_address,
	output reg [3*DATA_WIDTH-1:0] out_partial_force,
	output reg out_cache_readout_valid
);

	//// Registers recording the active particles that is currently being accumulated (6 stage -> Cycle 1: Determine the ID (either from input or input FIFO); Cycle 2: read out current force; Cycle 3-5: accumulation; Cycle 6: write back force)
	// If the new incoming forces requires to accumulate to a particle that is being processed in the pipeline, then need to push this new incoming force into a FIFO, until the accumulated force is write back into the force cache
	reg [CELL_ADDR_WIDTH-1:0] active_particle_id;
	reg [CELL_ADDR_WIDTH-1:0] active_particle_id_reg1;
	reg [CELL_ADDR_WIDTH-1:0] active_particle_id_reg2;
	reg [CELL_ADDR_WIDTH-1:0] active_particle_id_reg3;
	reg [CELL_ADDR_WIDTH-1:0] active_particle_id_reg4;
	reg [CELL_ADDR_WIDTH-1:0] active_particle_id_reg5;


	//// Signals derived from input
	// Extract the cell id from the incoming particle id
	wire [CELL_ID_WIDTH-1:0] particle_cell_x, particle_cell_y, particle_cell_z;
	assign {particle_cell_x, particle_cell_y, particle_cell_z} = in_particle_id[PARTICLE_ID_WIDTH-1:PARTICLE_ID_WIDTH-3*CELL_ID_WIDTH];
	// Extract the particle read address from the incoming partile id
	wire [CELL_ADDR_WIDTH-1:0] particle_id;
	assign particle_id = in_particle_id[CELL_ADDR_WIDTH-1:0];
	// Determine if the input is targeting this cell
	wire input_matching;
	assign input_matching = in_partial_force_valid && particle_cell_x == CELL_X && particle_cell_y == CELL_Y && particle_cell_z == CELL_Z;
	// Determine if the current input requires particle that is being processed
	wire particle_occupied;
	assign particle_occupied = (particle_id == active_particle_id) || (particle_id == active_particle_id_reg1) || (particle_id == active_particle_id_reg2) || (particle_id == active_particle_id_reg3) || (particle_id == active_particle_id_reg4) || (particle_id == active_particle_id_reg5);

	//// Signals connected to force_cache
	reg  [CELL_ADDR_WIDTH-1:0] cache_rd_address, cache_wr_address;
	wire  [3*DATA_WIDTH-1:0] cache_write_data;
	reg  cache_write_enable;
	wire [3*DATA_WIDTH-1:0] cache_readout_data;
	
	//// Signals connected to accumulator
	// The input to force accumulator
	reg [3*DATA_WIDTH-1:0] partial_force_to_accumulator;
	
	//// Delay registers
	// Conpensate for the 1 cycle delay of reading data out from cache
	reg delay_in_read_data_request;
	// Delay the write enable signal by 4 cycles: 1 cycle for assigning read address, 1 cycle for fetching data from cache, 2 cycles for waiting addition finish
	reg cache_write_enable_reg1;
	reg cache_write_enable_reg2;
	reg cache_write_enable_reg3;
	reg delay_cache_write_enable;
	// Delay the cache write address by 4 cycles: 1 cycle for assigning read address, 1 cycle for fetching data from cache, 2 cycles for waiting addition finish
	reg [CELL_ADDR_WIDTH-1:0] cache_wr_address_reg1;
	reg [CELL_ADDR_WIDTH-1:0] cache_wr_address_reg2;
	reg [CELL_ADDR_WIDTH-1:0] cache_wr_address_reg3;
	reg [CELL_ADDR_WIDTH-1:0] delay_cache_wr_address;
	// Delay the input particle information by one cycle to conpensating the one cycle delay to read from input FIFO
	reg [CELL_ADDR_WIDTH-1:0] delay_particle_id;
	reg [3*DATA_WIDTH-1:0] delay_in_partial_force;
	// Delay the control signal derived from the input information by one cycle
	reg delay_input_matching;
	reg delay_particle_occupied;
	reg delay_input_buffer_empty;
	// Delay the input to accumulator by one cycle to conpensate the one cycle delay to read previous data from force cache
	reg [3*DATA_WIDTH-1:0] delay_partial_force_to_accumulator;
	

	/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Input FIFO control logic
	// If the input is not valid or matching the cell, assign the the read enable if there are data inside FIFO
	//	If the input is valid, but the request data is in process, then write to FIFO
	/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//// Signals connected to force input buffer
	wire input_buffer_wr_en, input_buffer_rd_en;
	wire input_buffer_empty, input_buffer_full;
	wire [CELL_ADDR_WIDTH+3*DATA_WIDTH-1:0] input_buffer_readout_data;
	assign input_buffer_wr_en = (input_matching && particle_occupied) ? 1'b1 : 1'b0;
	assign input_buffer_rd_en = (~input_buffer_empty && (~input_matching || (input_matching && particle_occupied))) ? 1'b1 : 1'b0;
		
	
	/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Force Cache Controller
	// Since there is a 3 cycle latency for the adder, when there is a particle force being accumulated, while new forces for the same particle arrive, need to wait
	/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	always@(posedge clk)
		if(rst)
			begin
			// Delay registers
			// For assigning the read out valid
			delay_in_read_data_request <= 1'b0;
			// For conpensating the 4 cycles delay from write enable is assigned and accumulated value is calculated
			cache_write_enable_reg1 <= 1'b0;
			cache_write_enable_reg2 <= 1'b0;
			cache_write_enable_reg3 <= 1'b0;
			delay_cache_write_enable <= 1'b0;
			// For conpensating the 4 cycles delay from write address is generated and accumulated value is calculated
			cache_wr_address_reg1 <= {(CELL_ADDR_WIDTH){1'b0}};
			cache_wr_address_reg2 <= {(CELL_ADDR_WIDTH){1'b0}};
			cache_wr_address_reg3 <= {(CELL_ADDR_WIDTH){1'b0}};
			delay_cache_wr_address <= {(CELL_ADDR_WIDTH){1'b0}};
			// For conpensating the one cycle delay to read from input FIFO, delay the input particle information by one cycle
			delay_particle_id <= {(CELL_ADDR_WIDTH){1'b0}};
			delay_in_partial_force <= {(3*DATA_WIDTH){1'b0}};
			// For conpensating the one cycle delay to read from input FIFO, delay the control signal derived from the input information by one cycle
			delay_input_matching <= 1'b0;
			delay_particle_occupied <= 1'b0;
			delay_input_buffer_empty <= 1'b1;
			// For conpensating the one cycle delay of reading the previous value from force cache
			delay_partial_force_to_accumulator <= {(3*DATA_WIDTH){1'b1}};
			// For registering the active particles in the pipeline
			active_particle_id <= {(CELL_ADDR_WIDTH){1'b0}};
			active_particle_id_reg1 <= {(CELL_ADDR_WIDTH){1'b0}};
			active_particle_id_reg2 <= {(CELL_ADDR_WIDTH){1'b0}};
			active_particle_id_reg3 <= {(CELL_ADDR_WIDTH){1'b0}};
			active_particle_id_reg4 <= {(CELL_ADDR_WIDTH){1'b0}};
			active_particle_id_reg5 <= {(CELL_ADDR_WIDTH){1'b0}};
			
			// Read output ports
			out_partial_force <= {(3*DATA_WIDTH){1'b0}};
			out_cache_readout_valid <= 1'b0;
			// Cache control signals
			cache_rd_address <= {(CELL_ADDR_WIDTH){1'b0}};
			cache_wr_address <= {(CELL_ADDR_WIDTH){1'b0}};
//			cache_write_data <= {(3*DATA_WIDTH){1'b0}};
			cache_write_enable <= 1'b0;
			// Input to force accumulator
			partial_force_to_accumulator <= {(3*DATA_WIDTH){1'b0}};
			end
		else
			begin
			//// Delay registers
			// For assigning the read out valid
			delay_in_read_data_request <= in_read_data_request;
			// For conpensating the 3 cycles delay from write enable is assigned and accumulated value is calculated
			cache_write_enable_reg1 <= cache_write_enable;
			cache_write_enable_reg2 <= cache_write_enable_reg1;
			cache_write_enable_reg3 <= cache_write_enable_reg2;
			delay_cache_write_enable <= cache_write_enable_reg3;
			// For conpensating the 3 cycles delay from write address is generated and accumulated value is calculated
			cache_wr_address_reg1 <= cache_wr_address;
			cache_wr_address_reg2 <= cache_wr_address_reg1;
			cache_wr_address_reg3 <= cache_wr_address_reg2;
			delay_cache_wr_address <= cache_wr_address_reg3;
			/// For conpensating the one cycle delay to read from input FIFO, delay the input particle information by one cycle
			delay_particle_id <= particle_id;
			delay_in_partial_force <= in_partial_force;
			// For conpensating the one cycle delay to read from input FIFO, delay the control signal derived from the input information by one cycle
			delay_input_matching <= input_matching;
			delay_particle_occupied <= particle_occupied;
			delay_input_buffer_empty <= input_buffer_empty;
			// For conpensating the one cycle delay of reading the previous value from force cache
			delay_partial_force_to_accumulator <= partial_force_to_accumulator;
			// For registering the active particles in the pipeline
			active_particle_id_reg1 <= active_particle_id;
			active_particle_id_reg2 <= active_particle_id_reg1;
			active_particle_id_reg3 <= active_particle_id_reg2;
			active_particle_id_reg4 <= active_particle_id_reg3;
			active_particle_id_reg5 <= active_particle_id_reg4;
			
			//// Priority grant to read request (usually read enable need to keep low during force evaluation process)
			// if outside read request set, then no write activity is permitted
			if(in_read_data_request)
				begin
				// Active particle id for data dependence detection
				active_particle_id <= 0;
				// Read output ports
				out_partial_force <= cache_readout_data;
				out_cache_readout_valid <= delay_in_read_data_request;
				// Cache control signals
				cache_rd_address <= in_cache_read_address;
				cache_wr_address <= {(CELL_ADDR_WIDTH){1'b0}};
//				cache_write_data <= {(3*DATA_WIDTH){1'b0}};
				cache_write_enable <= 1'b0;
				// Input to force accumulator
				partial_force_to_accumulator <= {(3*DATA_WIDTH){1'b0}};
				end
			//// Accumulation and write into force memory
			else
				begin
				// During force accumulation period, output the data that is being written into the memory
				out_partial_force <= cache_write_data;
				out_cache_readout_valid <= 1'b0;
				// If the input is valid and not being processed, then process the input
				if(delay_input_matching && ~delay_particle_occupied)
					begin
					// Active particle id for data dependence detection
					active_particle_id <= delay_particle_id;
					// Cache control signal
					cache_rd_address <= delay_particle_id;
					cache_wr_address <= delay_particle_id;
					cache_write_enable <= 1'b1;
					// Input to force accumulator 
					partial_force_to_accumulator <= delay_in_partial_force;
					end
				// If the input is not valid, or the input is valid but requested particle is being processed, then process particle from the input buffer
				else if(~delay_input_buffer_empty && (~delay_input_matching || (delay_input_matching && delay_particle_occupied)))
					begin
					// Active particle id for data dependence detection
					active_particle_id <= input_buffer_readout_data[CELL_ADDR_WIDTH+3*DATA_WIDTH-1:3*DATA_WIDTH];
					// Cache control signal
					cache_rd_address <= input_buffer_readout_data[CELL_ADDR_WIDTH+3*DATA_WIDTH-1:3*DATA_WIDTH];
					cache_wr_address <= input_buffer_readout_data[CELL_ADDR_WIDTH+3*DATA_WIDTH-1:3*DATA_WIDTH];
					cache_write_enable <= 1'b1;
					// Input to force accumulator 
					partial_force_to_accumulator <= input_buffer_readout_data[3*DATA_WIDTH-1:0];
					end
				else
					begin
					// Active particle id for data dependence detection
					active_particle_id <= {(CELL_ADDR_WIDTH){1'b1}};
					// Cache control signal
					cache_rd_address <= {(CELL_ADDR_WIDTH){1'b0}};
					cache_wr_address <= {(CELL_ADDR_WIDTH){1'b0}};
					cache_write_enable <= 1'b0;
					// Input to force accumulator
					partial_force_to_accumulator <= {(3*DATA_WIDTH){1'b0}};
					end
				end
			end
	
	////////////////////////////////////////////////////////////////////////////////////////////////
	// Force Accumulator
	////////////////////////////////////////////////////////////////////////////////////////////////
	// Force_X Accumulator
	FP_ADD Force_X_Acc(
		.clk(clk),
		.ena(1'b1),
		.clr(1'b0),
		.ax(cache_readout_data[1*DATA_WIDTH-1:0*DATA_WIDTH]),
		.ay(delay_partial_force_to_accumulator[1*DATA_WIDTH-1:0*DATA_WIDTH]),
		.result(cache_write_data[1*DATA_WIDTH-1:0*DATA_WIDTH])
	);
	
	// Force_Y Accumulator
	FP_ADD Force_Y_Acc(
		.clk(clk),
		.ena(1'b1),
		.clr(1'b0),
		.ax(cache_readout_data[2*DATA_WIDTH-1:1*DATA_WIDTH]),
		.ay(delay_partial_force_to_accumulator[2*DATA_WIDTH-1:1*DATA_WIDTH]),
		.result(cache_write_data[2*DATA_WIDTH-1:1*DATA_WIDTH])
	);
	
	// Force_Z Accumulator
	FP_ADD Force_Z_Acc(
		.clk(clk),
		.ena(1'b1),
		.clr(1'b0),
		.ax(cache_readout_data[3*DATA_WIDTH-1:2*DATA_WIDTH]),
		.ay(delay_partial_force_to_accumulator[3*DATA_WIDTH-1:2*DATA_WIDTH]),
		.result(cache_write_data[3*DATA_WIDTH-1:2*DATA_WIDTH])
	);

	////////////////////////////////////////////////////////////////////////////////////////////////
	// Force Cache
	////////////////////////////////////////////////////////////////////////////////////////////////
	// Dual port ram
	force_cache
	#(
		.DATA_WIDTH(DATA_WIDTH*3),
		.PARTICLE_NUM(MAX_CELL_PARTICLE_NUM),
		.ADDR_WIDTH(CELL_ADDR_WIDTH)
	)
	force_cache
	(
		.clock(clk),
		.data(cache_write_data),
		.rdaddress(cache_rd_address),
		.wraddress(delay_cache_wr_address),
		.wren(delay_cache_write_enable),
		.q(cache_readout_data)
	);
	
	////////////////////////////////////////////////////////////////////////////////////////////////
	// Force Input Buffer
	// Handles data dependency
	////////////////////////////////////////////////////////////////////////////////////////////////
	Force_Cache_Input_Buffer
	#(
		.DATA_WIDTH(CELL_ADDR_WIDTH+3*DATA_WIDTH),								// hold particle ID and force value
		.BUFFER_DEPTH(FORCE_CACHE_BUFFER_DEPTH),
		.BUFFER_ADDR_WIDTH(FORCE_CACHE_BUFFER_ADDR_WIDTH)						// log(BUFFER_DEPTH) / log 2
	)
	Force_Cache_Input_Buffer
	(
		 .clock(clk),
		 .data({particle_id, in_partial_force}),
		 .rdreq(input_buffer_rd_en),
		 .wrreq(input_buffer_wr_en),
		 .empty(input_buffer_empty),
		 .full(input_buffer_full),
		 .q(input_buffer_readout_data),
		 .usedw()
	);

endmodule