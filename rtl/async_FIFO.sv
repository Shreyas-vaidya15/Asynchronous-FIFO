module async_FIFO
(
    input logic clk_write_side,
    input logic clk_read_side,
    input logic reset_n_write_side,
    input logic reset_n_read_side,
    input logic write_en,
    input logic read_en,
    input logic [7:0] write_data,
    output logic [7:0] read_data,
    output logic full,
    output logic empty
);

logic [3:0] write_ptr;

logic [3:0] gray_write_ptr;
logic [3:0] gray_write_ptr_ff1;
logic [3:0] gray_write_ptr_ff2;
logic [3:0] gray_write_ptr_reg;

logic do_write;


logic [3:0] read_ptr;

logic [3:0] gray_read_ptr;
logic [3:0] gray_read_ptr_ff1;
logic [3:0] gray_read_ptr_ff2;
logic [3:0] gray_read_ptr_reg;

logic do_read;

logic [7:0] mem [0:7];

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

assign full  = (gray_write_ptr[3:2] == ~gray_read_ptr_ff2[3:2]) && (gray_write_ptr[1:0] == gray_read_ptr_ff2[1:0]); 
assign empty = (gray_write_ptr_ff2 == gray_read_ptr); 

assign do_write = write_en && ~full;
assign do_read  = read_en && ~empty;

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
        mem[write_ptr[2:0]] <= write_data;
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
        read_data <= mem[read_ptr[2:0]];
    end

end

end

endmodule