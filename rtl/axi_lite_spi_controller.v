module axi_lite_spi_controller (
    // --- Global Signals ---
    input  wire        s_axi_aclk,     // System Clock (AXI Clock)
    input  wire        s_axi_aresetn,  // Active-low synchronous reset
    
    // --- AXI-Lite Write Address Channel ---
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    
    // --- AXI-Lite Write Data Channel ---
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,    // Byte write strobes
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    
    // --- AXI-Lite Write Response Channel ---
    output reg  [1:0]  s_axi_bresp,    // 2'b00 = OKAY
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    
    // --- AXI-Lite Read Address Channel ---
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    
    // --- AXI-Lite Read Data Channel ---
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,    // 2'b00 = OKAY
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,
    
    // --- Physical SPI Interface to Flash Chip ---
    output wire        sck,
    output wire        cs_n,
    output wire        mosi,
    input  wire        miso
);

    // --- Internal Register Declarations (Register Map) ---
    // Offset 0x00: Control Register (Bit 0 = Start, Bit 1 = Write Mode)
    reg [31:0] reg_control; 
    // Offset 0x08: Target Address Register (24-bit physical SPI address)
    reg [31:0] reg_addr;
    // Offset 0x0C: Write Data Register (Lower 8 bits used for data to write)
    reg [31:0] reg_data_w;
    
    // Read-only logic inputs mapped to registers:
    // Offset 0x04: Status Register (Bit 0 = Controller Busy, Bit 1 = Transaction Done)
    wire [31:0] reg_status;
    // Offset 0x10: Read Data Register (Lower 8 bits contain read data)
    wire [31:0] reg_data_r;

    // --- Wire up SPI Engine Control Signals ---
    wire        spi_start;
    wire        spi_write_mode;
    wire [23:0] spi_addr;
    wire [7:0]  spi_data_in;
    wire [7:0]  spi_data_out;
    wire        spi_busy;
    wire        spi_done;

    // Map registers to internal SPI core inputs
    // We treat the start signal as a auto-clearing "pulse". When the CPU writes 1 to Bit 0,
    // we pulse the SPI start, then clear it so it doesn't trigger repeatedly.
    assign spi_start      = reg_control[0];
    assign spi_write_mode = reg_control[1];
    assign spi_addr       = reg_addr[23:0];
    assign spi_data_in   = reg_data_w[7:0];

    // Map SPI core outputs to read-only register wires
    assign reg_status     = {30'b0, spi_done, spi_busy};
    assign reg_data_r     = {24'b0, spi_data_out};

    // Instantiate your physical SPI engine
    spi_flash_controller spi_core_inst (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .start(spi_start),
        .write_mode(spi_write_mode),
        .addr(spi_addr),
        .data_in(spi_data_in),
        .data_out(spi_data_out),
        .busy(spi_busy),
        .done(spi_done),
        .sck(sck),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso)
    );

    // --- AXI-Lite Write Channels (CPU writing to controller registers) ---
    reg [31:0] write_addr;
    reg        write_addr_valid;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_awready    <= 1'b0;
            s_axi_wready     <= 1'b0;
            s_axi_bvalid     <= 1'b0;
            s_axi_bresp      <= 2'b00;
            reg_control      <= 32'h0;
            reg_addr         <= 32'h0;
            reg_data_w       <= 32'h0;
            write_addr_valid <= 1'b0;
        end else begin
            // Pulse cleaning: Automatically clear the SPI start bit after 1 cycle
            if (reg_control[0]) begin
                reg_control[0] <= 1'b0;
            end

            // 1. Handshake Write Address
            if (s_axi_awvalid && !s_axi_awready) begin
                s_axi_awready    <= 1'b1;
                write_addr       <= s_axi_awaddr;
                write_addr_valid <= 1'b1;
            end else begin
                s_axi_awready    <= 1'b0;
            end

            // 2. Handshake Write Data
            if (s_axi_wvalid && !s_axi_wready && write_addr_valid) begin
                s_axi_wready     <= 1'b1;
                write_addr_valid <= 1'b0; // Consumed

                // Register decoding
                case (write_addr[7:0]) // Decode based on lower 8 bits of register offset
                    8'h00: reg_control <= s_axi_wdata;
                    8'h08: reg_addr    <= s_axi_wdata;
                    8'h0C: reg_data_w  <= s_axi_wdata;
                    default: ; // Offset 0x04 (Status) and 0x10 (Data Read) are Read-Only!
                endcase
            end else begin
                s_axi_wready     <= 1'b0;
            end

            // 3. Handle Write Response
            if (s_axi_wready && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00; // Success/OKAY response
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // --- AXI-Lite Read Channels (CPU reading from controller registers) ---
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'h0;
        end else begin
            // 1. Handshake Read Address
            if (s_axi_arvalid && !s_axi_arready) begin
                s_axi_arready <= 1'b1;
                
                // Read Register decoding
                case (s_axi_araddr[7:0])
                    8'h00: s_axi_rdata <= reg_control;
                    8'h04: s_axi_rdata <= reg_status;
                    8'h08: s_axi_rdata <= reg_addr;
                    8'h0C: s_axi_rdata <= reg_data_w;
                    8'h10: s_axi_rdata <= reg_data_r;
                    default: s_axi_rdata <= 32'hDEADBEEF; // Invalid address
                endcase
            end else begin
                s_axi_arready <= 1'b0;
            end

            // 2. Handshake Read Data & Response
            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00; // Success/OKAY response
            end else if (s_axi_rready && s_axi_rvalid) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule