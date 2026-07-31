module spi_flash_controller (
    input  wire        clk,         // System Clock (e.g., 50MHz)
    input  wire        rst_n,       // Active-low asynchronous reset
    
    // User Interface
    input  wire        start,       // Pulse high to start a transaction
    input  wire        write_mode,  // 0 = Read, 1 = Write
    input  wire [23:0] addr,        // 24-bit memory address
    input  wire [7:0]  data_in,     // 8-bit data to write (used if write_mode = 1)
    output reg  [7:0]  data_out,    // 8-bit data read (used if write_mode = 0)
    output reg         busy,        // High when busy
    output reg         done,        // Pulled high for 1 cycle when transaction completes
    
    // Physical SPI Interface to Flash Chip
    output reg         sck,
    output reg         cs_n,
    output reg         mosi,
    input  wire        miso
);

    // --- State Machine States ---
    localparam IDLE         = 4'd0;
    // Read Path States
    localparam SEND_CMD     = 4'd1;  // Send 0x03 (Read)
    localparam SEND_ADDR    = 4'd2;  // Send 24-bit address
    localparam READ_DATA    = 4'd3;  // Shift in 8-bit data
    // Write Path States
    localparam SEND_WREN    = 4'd4;  // Send 0x06 (Write Enable Command)
    localparam WREN_LATCH   = 4'd5;  // Toggle CS_n high to latch write enable
    localparam SEND_PP      = 4'd6;  // Send 0x02 (Page Program Command) + Address
    localparam WRITE_DATA   = 4'd7;  // Shift out 8-bit data
    // Common Finish State
    localparam FINISH       = 4'd8;

    reg [3:0]  state;
    
    // --- Clock Divider (SCK Generator) ---
    // Dividing 50MHz clock by 4 to get 12.5MHz SPI SCK
    reg [1:0] clk_div;
    wire      sck_tick;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clk_div <= 2'b0;
        else
            clk_div <= clk_div + 1'b1;
    end
    assign sck_tick = (clk_div == 2'b11);

    // --- Internal Shift & Counter Registers ---
    reg [31:0] shift_reg; 
    reg [5:0]  bit_counter;
    reg [7:0]  saved_write_data;

    // --- FSM Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            cs_n             <= 1'b1;
            mosi             <= 1'b0;
            sck              <= 1'b0;
            busy             <= 1'b0;
            done             <= 1'b0;
            data_out         <= 8'h00;
            bit_counter      <= 6'd0;
            shift_reg        <= 32'h0;
            saved_write_data <= 8'h00;
        end else begin
            done <= 1'b0; // Default pulse
            
            case (state)
                IDLE: begin
                    cs_n <= 1'b1;
                    sck  <= 1'b0;
                    busy <= 1'b0;
                    mosi <= 1'b0;
                    if (start) begin
                        busy             <= 1'b1;
                        saved_write_data <= data_in; // Latch write data immediately
                        
                        if (write_mode) begin
                            // Step 1: Must send Write Enable (0x06) command first
                            cs_n        <= 1'b0;
                            shift_reg   <= {24'h0, 8'h06}; // Align command to lower 8-bits
                            bit_counter <= 6'd7; 
                            state       <= SEND_WREN;
                        end else begin
                            // Standard Read Setup
                            cs_n        <= 1'b0;
                            shift_reg   <= {8'h03, addr}; 
                            bit_counter <= 6'd31; // 8-bit cmd + 24-bit addr
                            state       <= SEND_CMD;
                        end
                    end
                end

                // --- WRITE ENABLE (WREN) COMMAND SEQUENCE ---
                SEND_WREN: begin
                    if (sck_tick) begin
                        if (sck == 1'b0) begin
                            mosi <= shift_reg[bit_counter];
                            sck  <= 1'b1;
                        end else begin
                            sck  <= 1'b0;
                            if (bit_counter == 0) begin
                                state <= WREN_LATCH;
                            end else begin
                                bit_counter <= bit_counter - 1'b1;
                            end
                        end
                    end
                end

                WREN_LATCH: begin
                    // Pull CS_n high for at least 1-2 SCK periods to commit WREN internally
                    cs_n <= 1'b1;
                    mosi <= 1'b0;
                    if (sck_tick) begin
                        // Setup Page Program: Command 0x02 + Address
                        cs_n        <= 1'b0; // Pull CS_n low again to start writing
                        shift_reg   <= {8'h02, addr};
                        bit_counter <= 6'd31; 
                        state       <= SEND_PP;
                    end
                end

                // --- SEND PAGE PROGRAM (PP) & ADDRESS ---
                SEND_PP: begin
                    if (sck_tick) begin
                        if (sck == 1'b0) begin
                            mosi <= shift_reg[bit_counter];
                            sck  <= 1'b1;
                        end else begin
                            sck  <= 1'b0;
                            if (bit_counter == 0) begin
                                // After sending 0x02 command + 24-bit address, send write data
                                shift_reg   <= {24'h0, saved_write_data};
                                bit_counter <= 6'd7;
                                state       <= WRITE_DATA;
                            end else begin
                                bit_counter <= bit_counter - 1'b1;
                            end
                        end
                    end
                end

                // --- WRITE THE DATA BYTE ---
                WRITE_DATA: begin
                    if (sck_tick) begin
                        if (sck == 1'b0) begin
                            mosi <= shift_reg[bit_counter];
                            sck  <= 1'b1;
                        end else begin
                            sck  <= 1'b0;
                            if (bit_counter == 0) begin
                                state <= FINISH;
                            end else begin
                                bit_counter <= bit_counter - 1'b1;
                            end
                        end
                    end
                end

                // --- STANDARD READ COMMAND & ADDRESS SEQUENCE ---
                SEND_CMD, SEND_ADDR: begin
                    if (sck_tick) begin
                        if (sck == 1'b0) begin
                            mosi <= shift_reg[bit_counter];
                            sck  <= 1'b1;
                        end else begin
                            sck  <= 1'b0;
                            if (bit_counter == 0) begin
                                state       <= READ_DATA;
                                bit_counter <= 6'd7;
                            end else begin
                                bit_counter <= bit_counter - 1'b1;
                            end
                        end
                    end
                end

                // --- READ DATA BYTE ---
                READ_DATA: begin
                    if (sck_tick) begin
                        if (sck == 1'b0) begin
                            sck <= 1'b1;
                            shift_reg[bit_counter] <= miso;
                        end else begin
                            sck <= 1'b0;
                            if (bit_counter == 0) begin
                                state <= FINISH;
                            end else begin
                                bit_counter <= bit_counter - 1'b1;
                            end
                        end
                    end
                end

                // --- TERMINATE TRANSACTION ---
                FINISH: begin
                    cs_n     <= 1'b1; // De-assert to stop Flash chip
                    mosi     <= 1'b0;
                    data_out <= shift_reg[7:0]; // Will contain read data if read_mode was 0
                    done     <= 1'b1;
                    busy     <= 1'b0;
                    state    <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule