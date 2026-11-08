module async_FIFO
#
(
    parameter int DATA_WIDTH = 32,
    parameter int MEM_DEPTH = 32,
    parameter int ALMOST_EMPTY = MEM_DEPTH / 4,
    parameter int ALMOST_FULL = MEM_DEPTH - MEM_DEPTH / 4
)

(
    input logic clk_write_side,
    input logic clk_read_side,
    input logic reset_n_write_side,
    input logic reset_n_read_side,
    input logic write_en,
    input logic read_en,
    input logic [DATA_WIDTH - 1:0] write_data,
    output logic [DATA_WIDTH - 1:0] read_data,
    output logic full,
    output logic almost_full,
    output logic empty,
    output logic almost_empty,
    output logic overflow,
    output logic underflow
);
localparam int ADDRESS_WIDTH = $clog2(MEM_DEPTH);

localparam int FULL_LOW_MSB = (ADDRESS_WIDTH > 1) ? ADDRESS_WIDTH - 2 : 0;

// synthesis translate_off
initial begin
    if (MEM_DEPTH < 4 || (MEM_DEPTH & (MEM_DEPTH - 1)) != 0) begin
        $error("MEM_DEPTH must be a power of 2 and >= 4, got %0d", MEM_DEPTH);
        $finish;
    end
    if (ALMOST_EMPTY < 1 || ALMOST_FULL >= MEM_DEPTH || ALMOST_EMPTY >= ALMOST_FULL) begin
        $error("Bad thresholds: ALMOST_EMPTY=%0d ALMOST_FULL=%0d MEM_DEPTH=%0d",
               ALMOST_EMPTY, ALMOST_FULL, MEM_DEPTH);
        $finish;
    end
end

// synthesis translate_on
logic [ADDRESS_WIDTH:0] write_ptr;

logic [ADDRESS_WIDTH:0] gray_write_ptr;
logic [ADDRESS_WIDTH:0] gray_write_ptr_ff1;
logic [ADDRESS_WIDTH:0] gray_write_ptr_ff2;
logic [ADDRESS_WIDTH:0] gray_write_ptr_reg;

logic do_write;


logic [ADDRESS_WIDTH:0] read_ptr;

logic [ADDRESS_WIDTH:0] gray_read_ptr;
logic [ADDRESS_WIDTH:0] gray_read_ptr_ff1;
logic [ADDRESS_WIDTH:0] gray_read_ptr_ff2;
logic [ADDRESS_WIDTH:0] gray_read_ptr_reg;

logic do_read;

logic [ADDRESS_WIDTH:0] difference_full;
logic [ADDRESS_WIDTH:0] difference_empty;

logic [ADDRESS_WIDTH:0] read_ptr_sync_bin;
logic [ADDRESS_WIDTH:0] write_ptr_sync_bin;

logic [DATA_WIDTH - 1:0] mem [0:MEM_DEPTH - 1];

assign gray_write_ptr = write_ptr ^ (write_ptr >> 1'b1);
assign gray_read_ptr  = read_ptr  ^ (read_ptr  >> 1'b1);

always_ff @(posedge clk_write_side or negedge reset_n_write_side)
begin
    if(!reset_n_write_side)
    begin
        gray_write_ptr_reg <= '0;
    end

    else
    begin
        gray_write_ptr_reg <= gray_write_ptr;
    end
end

always_ff @(posedge clk_read_side or negedge reset_n_read_side)
begin
    if(!reset_n_read_side)
    begin
        gray_read_ptr_reg <= '0;
    end

    else
    begin
        gray_read_ptr_reg <= gray_read_ptr;
    end
end

always_ff @(posedge clk_read_side or negedge reset_n_read_side)
begin
    if(!reset_n_read_side)
    begin
        gray_write_ptr_ff1 <= '0;
        gray_write_ptr_ff2 <= '0;
    end

    else
    begin
        gray_write_ptr_ff1 <= gray_write_ptr_reg;
        gray_write_ptr_ff2 <= gray_write_ptr_ff1;
    end

end

always_ff @(posedge clk_write_side or negedge reset_n_write_side)
begin
    if(!reset_n_write_side)
    begin
        gray_read_ptr_ff1 <= '0;
        gray_read_ptr_ff2 <= '0;
    end

    else
    begin
        gray_read_ptr_ff1 <= gray_read_ptr_reg;
        gray_read_ptr_ff2 <= gray_read_ptr_ff1; 
    end

end

assign full  = (gray_write_ptr[ADDRESS_WIDTH:ADDRESS_WIDTH - 1] == ~gray_read_ptr_ff2[ADDRESS_WIDTH:ADDRESS_WIDTH - 1]) 
               && (gray_write_ptr[FULL_LOW_MSB:0] == gray_read_ptr_ff2[FULL_LOW_MSB:0]);
assign empty = (gray_write_ptr_ff2 == gray_read_ptr); 

assign difference_full  = write_ptr - read_ptr_sync_bin;
assign difference_empty = write_ptr_sync_bin - read_ptr;

assign almost_full  = (~full && difference_full >= ALMOST_FULL);
assign almost_empty = (~empty && difference_empty <= ALMOST_EMPTY);

assign overflow   = (full && write_en);
assign underflow = (empty && read_en);

assign do_write = write_en && ~full;
assign do_read  = read_en && ~empty;

always_comb
begin
    for (int i = 0; i <= ADDRESS_WIDTH; i++)
    begin
        read_ptr_sync_bin[i]  = ^(gray_read_ptr_ff2  >> i);
        write_ptr_sync_bin[i] = ^(gray_write_ptr_ff2 >> i);
    end
end

always_ff @(posedge clk_write_side or negedge reset_n_write_side)
begin
    if(!reset_n_write_side)
    begin
        write_ptr <= '0;
    end

    else
    begin
        if(do_write)
        begin
            write_ptr <= write_ptr + 1'b1;
        end
    end
end

always_ff @(posedge clk_write_side)
begin
    if(do_write)
    begin
        mem[write_ptr[ADDRESS_WIDTH - 1:0]] <= write_data;
    end
end

always_ff @(posedge clk_read_side or negedge reset_n_read_side)
begin

if(!reset_n_read_side)
begin
    read_ptr <= '0;
    read_data <= '0;
end

else
begin

    if(do_read)
    begin
        read_ptr <= read_ptr + 1'b1;
        read_data <= mem[read_ptr[ADDRESS_WIDTH - 1:0]];
    end

end

end

endmodule