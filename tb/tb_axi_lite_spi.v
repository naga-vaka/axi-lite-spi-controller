`timescale 1ns / 1ps

module tb_axi_lite_spi();

    // Clock & Reset Signals
    reg clk;
    reg rst_n;

    // AXI-Lite Interface Signals
    reg  [31:0] s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;

    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;

    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;

    reg  [31:0] s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;

    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // SPI Signals
    wire sck;
    wire cs_n;
    wire mosi;
    reg  miso;

    // Instantiate Top-Level AXI-Lite SPI Controller (DUT)
    axi_lite_spi_controller dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .sck(sck),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso)
    );

    // 50 MHz Clock Generation (Period = 20ns)
    always #10 clk = ~clk;

    // --- Task: AXI-Lite Write ---
    task axi_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        s_axi_awaddr  <= addr;
        s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data;
        s_axi_wstrb   <= 4'b1111;
        s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;

        // Wait until BOTH address and data have been accepted
        fork
            begin
                wait (s_axi_awready && s_axi_awvalid);
                @(posedge clk);
                s_axi_awvalid <= 1'b0;
            end
            begin
                wait (s_axi_wready && s_axi_wvalid);
                @(posedge clk);
                s_axi_wvalid <= 1'b0;
            end
        join

        // Wait for write response handshake
        wait (s_axi_bvalid);
        @(posedge clk);
        s_axi_bready <= 1'b0;
    end
endtask

    // --- Task: AXI-Lite Read ---
    task axi_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(posedge clk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            wait (s_axi_arready);
            @(posedge clk);
            s_axi_arvalid <= 1'b0;

            wait (s_axi_rvalid);
            rdata = s_axi_rdata;
            @(posedge clk);
            s_axi_rready  <= 1'b0;
        end
    endtask

    // --- Behavioral Simulation of Flash Memory Response on MISO ---
    reg [7:0] test_data = 8'hA5; // Data returned on SPI read
    integer bit_idx = 7;

    always @(posedge sck or posedge cs_n) begin
        if (cs_n) begin
            bit_idx <= 7;
            miso    <= 1'b0;
        end else begin
            // Drive MISO on falling edge or sampling setup
            miso    <= test_data[bit_idx];
            if (bit_idx > 0)
                bit_idx <= bit_idx - 1;
            else
                bit_idx <= 7;
        end
    end

    // --- Main Test Stimulus ---
    reg [31:0] read_val;

  initial begin
        // Initialize Signals
        clk           = 0;
        rst_n         = 0;
        s_axi_awaddr  = 0;
        s_axi_awvalid = 0;
        s_axi_wdata   = 0;
        s_axi_wstrb   = 0;
        s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;
        miso          = 0;

        // Reset Pulse
        #40;
        rst_n = 1;
        #40;

        $display("--- Step 1: Write Target Address (0x123456) to ADDR Register (0x08) ---");
        axi_write(32'h08, 32'h00123456);

        $display("--- Step 2: Configure Read Mode (0) and Trigger Start (1) via CTRL Register (0x00) ---");
        axi_write(32'h00, 32'h00000001); // Bit 0 = Start, Bit 1 = Read (0)

        $display("--- Step 3: Wait / Poll Status Register until SPI is Done ---");
        read_val = 32'h00000001;
        // Poll Bit 0 (Busy) until it becomes 0
        while (read_val[0] == 1'b1) begin
            #200;
            axi_read(32'h04, read_val);
            $display("Polling STATUS Reg: 0x%h", read_val);
        end

        // Extra short delay to allow FINISH state to latch data_out
        #200;

        $display("--- Step 4: Read Received SPI Data Register (0x10) via AXI ---");
        axi_read(32'h10, read_val);
        $display("DATA_R Reg Value: 0x%h (Expected: 0xA5)", read_val);

        if (read_val[7:0] == 8'hA5)
            $display(">>> TEST PASSED: AXI-Lite SPI Read Successful! <<<");
        else
            $display(">>> TEST FAILED: Mismatch in Read Data <<<");

        $finish;
    end

endmodule