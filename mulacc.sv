module mulacc(
    input logic clk, reset,
    // Ring Bus Interface
    input RBUS bin,
    output RBUS bout,
    // Result Interface
    output RESULT resout,
    // FIFO 1 Interface (Data)
    output FifoAddr f1wadr, output FifoData f1wdata, output logic f1write,
    output FifoAddr f1radr, input FifoData f1rdata,
    // FIFO 2 Interface (Coefficients)
    output FifoAddr f2wadr, output FifoData f2wdata, output logic f2write,
    output FifoAddr f2radr, input FifoData f2rdata,
    // Config
    input logic [3:0] device_id
);

    // ----------------------------------------------------------------
    // 1. DECLARATIONS (Moved to Top for Safety)
    // ----------------------------------------------------------------
    
    // State Machine
    typedef enum logic [2:0] {S_IDLE, S_WAIT_RAM, S_CALC_LOWER, S_CALC_UPPER, S_DONE} state_t;
    state_t state;
    
    // Configuration Registers
    logic [47:0] cfg_data_addr;
    logic [47:0] cfg_coef_addr;
    logic signed [31:0] cfg_num_groups;
    logic cfg_busy;

    // Runtime Control
    logic signed [31:0] groups_left;
    logic [7:0] read_ptr1, read_ptr2;
    logic trigger_start;
    
    // Data Registers (Pipeline storage)
    logic [1007:0] data_reg;
    logic [1007:0] coef_reg;
    
    // Lane Storage - Declared as WIRE for continuous assignment
    wire [11:0] data_lower [41:0];
    wire [11:0] coef_lower [41:0];
    wire [11:0] data_upper [41:0];
    wire [11:0] coef_upper [41:0];
    
    // Adder Tree Signals
    logic signed [47:0] tree_sum; 
    logic [11:0] tree_d [41:0];
    logic [11:0] tree_c [41:0];

    // Bus Signals
    RBUS empty_pkt;
    RBUS token_pkt;

    // ----------------------------------------------------------------
    // 2. MATH FUNCTION (Spec v0.4)
    // ----------------------------------------------------------------
    function automatic logic signed [47:0] calc_term(input logic [11:0] D, input logic [11:0] C);
        logic s_d, s_c, s_res;
        logic signed [4:0] e_d, e_c;
        logic signed [5:0] e_sum;
        logic [5:0] m_d, m_c;
        logic [13:0] m_prod; 
        logic signed [47:0] fixed_res;
        
        // Spec: True Zero is all 1s (0xFFF)
        if (D[10:0] == 11'h7FF || C[10:0] == 11'h7FF) return 48'd0;
        
        s_d = D[11]; s_c = C[11];
        e_d = D[10:6]; e_c = C[10:6]; // 2's Comp
        m_d = D[5:0]; m_c = C[5:0];

        // Implicit 1.0
        m_prod = {1'b1, m_d} * {1'b1, m_c}; 
        
        e_sum = e_d + e_c;
        s_res = s_d ^ s_c;
        
        // Align to 24.24
        fixed_res = {34'b0, m_prod}; 
        
        if (e_sum >= -12) fixed_res = fixed_res << (12 + e_sum);
        else              fixed_res = fixed_res >> (-(12 + e_sum));
        
        if (s_res) fixed_res = -fixed_res;
        
        return fixed_res;
    endfunction

    // ----------------------------------------------------------------
    // 3. BUS INTERFACE
    // ----------------------------------------------------------------
    always_comb begin
        empty_pkt = '0;
        empty_pkt.Opcode = EMPTY;
        empty_pkt.Token = 0;
        token_pkt = '0;
        token_pkt.Opcode = TOKEN_ONLY;
        token_pkt.Token = 1;
    end

    // Trigger: Combinational detect of Write Packet
    assign trigger_start = (bin.Opcode == WRITE_REQ && bin.Destination == device_id);

    always_comb begin
        if (reset !== 1'b0) bout = empty_pkt;
        else begin
            bout = bin; 
            if (bin.Destination == device_id && bin.Opcode != EMPTY && bin.Opcode != IDLE) begin
                if (bin.Opcode == READ_REQ) begin
                    // Respond to Polling
                    bout.Opcode = RDATA;
                    bout.Token = 1; 
                    bout.Source = device_id;
                    bout.Destination = bin.Source;
                    bout.Data = '0;
                    bout.Data[47:0] = cfg_data_addr;
                    bout.Data[95:48] = cfg_coef_addr;
                    bout.Data[127:96] = cfg_num_groups;
                    bout.Data[176] = cfg_busy;
                end else begin
                    // Consume Write & Release Token
                    if (bin.Token) bout = token_pkt; 
                    else bout = empty_pkt;
                end
            end
        end
    end

    // Configuration Capture
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            cfg_data_addr <= 0;
            cfg_coef_addr <= 0;
            cfg_num_groups <= 0;
            cfg_busy <= 0;
        end else begin
            if (trigger_start) begin
                cfg_data_addr <= bin.Data[47:0];
                cfg_coef_addr <= bin.Data[95:48];
                cfg_num_groups <= bin.Data[127:96];
                cfg_busy <= 1; 
            end else if (state == S_DONE) begin
                cfg_busy <= 0; 
            end
        end
    end

    // ----------------------------------------------------------------
    // 4. DATAPATH: 42-LANE ADDER TREE
    // ----------------------------------------------------------------
    assign f1write = 0; assign f1wadr = 0; assign f1wdata = 0;
    assign f2write = 0; assign f2wadr = 0; assign f2wdata = 0;

    // Address Output Logic (Instant Start Mux)
    always_comb begin
        if (state == S_IDLE && trigger_start) begin
            f1radr = bin.Data[7:0];
            f2radr = bin.Data[55:48];
        end else begin
            f1radr = read_ptr1;
            f2radr = read_ptr2;
        end
    end

    // Unpacking (Generates to Wires)
    genvar i;
    generate
        for (i=0; i<42; i++) begin : UNPACK
            assign data_lower[i] = f1rdata[(i*12) +: 12];
            assign coef_lower[i] = f2rdata[(i*12) +: 12];
            assign data_upper[i] = f1rdata[(i*12 + 504) +: 12];
            assign coef_upper[i] = f2rdata[(i*12 + 504) +: 12];
        end
    endgenerate

    // Adder Tree Input Mux
    always_comb begin
        if (state == S_CALC_UPPER) begin
            // Use Registered Data
            for (int k=0; k<42; k++) begin
                tree_d[k] = data_reg[504 + k*12 +: 12];
                tree_c[k] = coef_reg[504 + k*12 +: 12];
            end
        end else begin
            // Use Live Data (S_CALC_LOWER)
            for (int k=0; k<42; k++) begin
                tree_d[k] = f1rdata[k*12 +: 12];
                tree_c[k] = f2rdata[k*12 +: 12];
            end
        end
    end

    // Summation Loop (WITH SANITIZATION)
    always_comb begin
        tree_sum = 0;
        for (int j=0; j<42; j++) begin
            logic [11:0] d_safe, c_safe;
            
            // --- SANITIZATION ---
            // Force X to True Zero (0xFFF) to prevent corrupted results
            if (^tree_d[j] === 1'bx) d_safe = 12'h7FF;
            else d_safe = tree_d[j];
            
            if (^tree_c[j] === 1'bx) c_safe = 12'h7FF;
            else c_safe = tree_c[j];
            
            tree_sum = tree_sum + calc_term(d_safe, c_safe);
        end
    end

    // ----------------------------------------------------------------
    // 5. CONTROL LOGIC
    // ----------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            read_ptr1 <= 0; read_ptr2 <= 0;
            resout <= '0;
            groups_left <= 0;
            data_reg <= 0; coef_reg <= 0;
        end else begin
            resout.pushOut <= 0; 

            // INSTANT START
            if (state == S_IDLE && trigger_start) begin
                // Latch pointers for next cycle
                read_ptr1 <= bin.Data[7:0] + 1;
                read_ptr2 <= bin.Data[55:48] + 1;
                groups_left <= bin.Data[127:96];
                
                if (bin.Data[127:96] > 0) state <= S_WAIT_RAM;
                else state <= S_DONE;
            end 
            else case (state)
                S_IDLE: begin
                    if (cfg_busy) begin
                        read_ptr1 <= cfg_data_addr[7:0];
                        read_ptr2 <= cfg_coef_addr[7:0];
                        groups_left <= cfg_num_groups;
                        state <= S_WAIT_RAM;
                    end
                end

                S_WAIT_RAM: begin
                    // Wait for RAM. Address 0 was issued in prev cycle.
                    // Prefetch Addr 1 if needed
                    if (groups_left > 2) begin
                        read_ptr1 <= read_ptr1 + 1;
                        read_ptr2 <= read_ptr2 + 1;
                    end
                    state <= S_CALC_LOWER;
                end

                S_CALC_LOWER: begin
                    // Data Valid. Capture for Upper phase.
                    data_reg <= f1rdata;
                    coef_reg <= f2rdata;
                    
                    // Output Lower Result
                    resout.result <= tree_sum;
                    resout.pushOut <= 1;
                    groups_left <= groups_left - 1;
                    
                    if (groups_left > 1) state <= S_CALC_UPPER;
                    else state <= S_DONE;
                end

                S_CALC_UPPER: begin
                    // Output Upper Result
                    resout.result <= tree_sum;
                    resout.pushOut <= 1;
                    groups_left <= groups_left - 1;
                    
                    if (groups_left > 1) begin
                        // Wait for next word
                        if (groups_left > 2) begin
                             read_ptr1 <= read_ptr1 + 1;
                             read_ptr2 <= read_ptr2 + 1;
                        end
                        state <= S_WAIT_RAM; 
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
