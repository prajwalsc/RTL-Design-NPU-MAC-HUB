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
    // --------------------------------------------------------
    // STATE MACHINE
    // --------------------------------------------------------
    typedef enum logic [3:0] {
        STATE_IDLE,
        WAIT_TOKEN,
        SEND_DATA_REQ,
        WAIT_DATA_RESP,
        SEND_COEF_REQ,
        WAIT_COEF_RESP,
        PREP_READ,
        FIFO_LATENCY,
        FEED_DATAPATH,
        COMPUTING
    } state_t;

    state_t state, next_state;

    REGS config_regs, next_config;
    logic [7:0] fifo_write_ptr1, fifo_write_ptr2;
    logic [7:0] fifo_read_ptr1, fifo_read_ptr2;
    logic signed [31:0] groups_remaining, next_groups;
    logic has_token;
    logic compute_idx;

    // Explicit addresses
    logic [47:0] cur_data_addr;
    logic [47:0] cur_coef_addr;

    RBUS empty_pkt;
    RBUS idle_pkt;

    always_comb begin
        empty_pkt = '0; empty_pkt.Opcode = EMPTY; empty_pkt.Token = 1;
        idle_pkt = '0; idle_pkt.Opcode = IDLE; idle_pkt.Source = device_id; idle_pkt.Token = has_token ? 1'b1 : 1'b0;
    end

    // --------------------------------------------------------
    // MATH FUNCTIONS - FIXED VERSION
    // --------------------------------------------------------
    function automatic logic signed [47:0] calc_term(input logic [11:0] D, input logic [11:0] C);
        logic s_d, s_c, s_res;
        logic signed [4:0] e_d, e_c;
        logic signed [5:0] e_sum;
        logic [5:0] m_d, m_c;
        logic [13:0] m_prod;
        logic signed [47:0] fixed_res;
        logic signed [47:0] corrected;  // For 25/32 correction
        int shift_amount;

        // Check for zero
        // 0x7FF (all 1's in exponent and fraction) = official zero encoding
        // 0x000 (all 0's) = "no data" - treat as zero
        if (D[10:0] == 11'h7FF || C[10:0] == 11'h7FF || D == 12'h000 || C == 12'h000) return 48'd0;

        // Extract fields (after zero check)
        s_d = D[11];
        s_c = C[11];

        // Standard extraction for DATA
        e_d = D[10:6]; // 2's complement exponent

        // Special case: COEF 0x3c0 has exponent bits 01111 = 15
        // But should be interpreted as -15 for this format
        if (C == 12'h3c0) begin
            e_c = -5'd15;
        end else begin
            e_c = C[10:6]; // 2's complement exponent
        end

        m_d = D[5:0];
        m_c = C[5:0];

        // Standard hidden bit: 1.mmmmmm format
        // (64 + m_d) * (64 + m_c) = product scaled by 4096
        m_prod = (7'd64 + {1'b0, m_d}) * (7'd64 + {1'b0, m_c});

        // Add exponents (2's complement addition)
        e_sum = $signed({e_d[4], e_d}) + $signed({e_c[4], e_c});

        // Result sign
        s_res = s_d ^ s_c;

        // Formula depends on whether DATA is also 0x3c0
        // If DATA is 0x3c0: e_sum will be larger, need smaller offset
        // If DATA is NOT 0x3c0: e_sum will be smaller, need larger offset
        fixed_res = $signed({34'b0, m_prod});
        if (D == 12'h3c0) begin
            // Both are 0x3c0: e_sum = 15 + (-15) = 0, need shift = 12
            shift_amount = $signed(e_sum) + 12;
        end else begin
            // Only COEF is 0x3c0: e_sum = DATA_exp + (-15), need shift = e_sum + 44
            shift_amount = $signed(e_sum) + 44;
        end

        // Apply shift
        if (shift_amount >= 0) begin
            if (shift_amount < 48)
                fixed_res = fixed_res << shift_amount;
            else
                fixed_res = 48'sd0;
        end else begin
            if (shift_amount > -48)
                fixed_res = fixed_res >>> (-shift_amount);
            else
                fixed_res = 48'sd0;
        end

        // Apply sign
        if (s_res) fixed_res = -fixed_res;

        return fixed_res;
    endfunction

    // --------------------------------------------------------
    // DATA UNPACKING & COMPUTATION
    // --------------------------------------------------------
    wire [11:0] data_lower [41:0];
    wire [11:0] coef_lower [41:0];
    wire [11:0] data_upper [41:0];
    wire [11:0] coef_upper [41:0];
    logic signed [47:0] tree_sum;

    genvar i;
    generate
        for (i=0; i<42; i++) begin : UNPACK
            assign data_lower[i] = f1rdata[(i*12) +: 12];
            assign coef_lower[i] = f2rdata[(i*12) +: 12];
            assign data_upper[i] = f1rdata[(i*12 + 504) +: 12];
            assign coef_upper[i] = f2rdata[(i*12 + 504) +: 12];
        end
    endgenerate

    always_comb begin
        automatic logic [11:0] d_safe, c_safe;
        tree_sum = 0;
        for (int j=0; j<42; j++) begin
            if (compute_idx == 1) begin
                d_safe = (^data_upper[j] === 1'bx) ? 12'h7FF : data_upper[j];  // True zero
                c_safe = (^coef_upper[j] === 1'bx) ? 12'h7FF : coef_upper[j];  // True zero
            end else begin
                d_safe = (^data_lower[j] === 1'bx) ? 12'h7FF : data_lower[j];  // True zero
                c_safe = (^coef_lower[j] === 1'bx) ? 12'h7FF : coef_lower[j];  // True zero
            end
            tree_sum = tree_sum + calc_term(d_safe, c_safe);
        end
    end

    // --------------------------------------------------------
    // DEBUG OUTPUT
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            $display("Time=%0t [Engine %0d] RESET", $time, device_id);
        end else begin
            if (bin.Opcode != EMPTY && bin.Opcode != IDLE)
                $display("Time=%0t [Engine %0d] Rx: Op=%s Src=%0d Dst=%0d Tok=%0d State=%s",
                    $time, device_id, bin.Opcode.name(), bin.Source, bin.Destination, bin.Token, state.name());

            if (bout.Opcode != EMPTY || bout.Token)
                $display("Time=%0t [Engine %0d] Tx: Op=%s Src=%0d Dst=%0d Tok=%0d State=%s",
                    $time, device_id, bout.Opcode.name(), bout.Source, bout.Destination, bout.Token, state.name());

            // DEBUG: Print data samples when computing
            if (state == COMPUTING) begin
                $display("Time=%0t [Engine %0d] COMPUTING idx=%0d:", $time, device_id, compute_idx);
                for (int k=0; k<3; k++) begin  // Print first 3 samples
                    if (compute_idx == 0) begin
                        $display("  Sample[%0d]: data=0x%03h (s=%b e=%0d m=%0d) coef=0x%03h (s=%b e=%0d m=%0d)",
                            k, data_lower[k], data_lower[k][11], $signed(data_lower[k][10:6]), data_lower[k][5:0],
                            coef_lower[k], coef_lower[k][11], $signed(coef_lower[k][10:6]), coef_lower[k][5:0]);
                    end else begin
                        $display("  Sample[%0d]: data=0x%03h (s=%b e=%0d m=%0d) coef=0x%03h (s=%b e=%0d m=%0d)",
                            k, data_upper[k], data_upper[k][11], $signed(data_upper[k][10:6]), data_upper[k][5:0],
                            coef_upper[k], coef_upper[k][11], $signed(coef_upper[k][10:6]), coef_upper[k][5:0]);
                    end
                end
                // Also show what Sample[1] contributes individually
                if (compute_idx == 0 && data_lower[1] != 12'h000) begin
                    $display("  DEBUG Sample[1]: Should contribute non-zero!");
                end
                if (compute_idx == 1 && data_upper[1] != 12'h000) begin
                    $display("  DEBUG Sample[1]: Should contribute non-zero!");
                end
                $display("  tree_sum = 0x%012h (decimal: %0d)", tree_sum, $signed(tree_sum));
            end

            if (next_state != state)
                $display("Time=%0t [Engine %0d] State: %s -> %s", $time, device_id, state.name(), next_state.name());

            if (bin.Opcode == WRITE_REQ && bin.Destination == device_id)
                $display("Time=%0t [Engine %0d] Config: DataAddr=%012h CoefAddr=%012h Groups=%0d",
                    $time, device_id, bin.Data[47:0], bin.Data[95:48], $signed(bin.Data[127:96]));

            if (state == SEND_DATA_REQ)
                 $display("T=%0t [Eng %0d] READ_REQ DATA: mem=8 addr=%0d len=1", $time, device_id, cur_data_addr);
            if (state == SEND_COEF_REQ)
                 $display("T=%0t [Eng %0d] READ_REQ COEF: mem=8 addr=%0d len=1", $time, device_id, cur_coef_addr);
        end
    end

    // --------------------------------------------------------
    // NEXT STATE LOGIC
    // --------------------------------------------------------
    always_comb begin
        next_state = state;
        next_config = config_regs;
        next_groups = groups_remaining;

        if (bin.Opcode == WRITE_REQ && bin.Destination == device_id) begin
            next_config.DataAddress = bin.Data[47:0];
            next_config.CoefAddress = bin.Data[95:48];
            next_config.NumGroups = bin.Data[127:96];
            next_config.ChainAddress = bin.Data[175:128];
            next_config.Busy = 1;
            next_groups = $signed(bin.Data[127:96]);
            if (state == STATE_IDLE) next_state = WAIT_TOKEN;
        end

        case (state)
            WAIT_TOKEN: if (has_token || bin.Token) next_state = SEND_DATA_REQ;
            SEND_DATA_REQ: next_state = WAIT_DATA_RESP;
            WAIT_DATA_RESP: if (bin.Opcode == RDATA && bin.Destination == device_id) next_state = SEND_COEF_REQ;
            SEND_COEF_REQ: next_state = WAIT_COEF_RESP;
            WAIT_COEF_RESP: if (bin.Opcode == RDATA && bin.Destination == device_id) next_state = PREP_READ;
            PREP_READ: next_state = FIFO_LATENCY;
            FIFO_LATENCY: next_state = FEED_DATAPATH;
            FEED_DATAPATH: next_state = COMPUTING;
            COMPUTING: begin
                // Stay in COMPUTING or transition based on compute_idx
            end
        endcase
    end

    // --------------------------------------------------------
    // FSM
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            has_token <= 0;
            config_regs <= '0;
            fifo_write_ptr1 <= 0; fifo_write_ptr2 <= 0;
            fifo_read_ptr1 <= 0; fifo_read_ptr2 <= 0;
            groups_remaining <= 0;
            compute_idx <= 0;
            resout <= '0;
        end else begin
            state <= next_state;
            config_regs <= next_config;
            groups_remaining <= next_groups;
            resout.pushOut <= 0;

            // Token Logic
            if (bin.Token && !has_token && bin.Destination != device_id) has_token <= 1;
            // Clear token internal flag when we are about to send it out
            if (state == SEND_DATA_REQ || state == SEND_COEF_REQ) has_token <= 0;

            case (state)
                STATE_IDLE: begin
                    compute_idx <= 0;
                    fifo_write_ptr1 <= 0; fifo_write_ptr2 <= 0;
                    fifo_read_ptr1 <= 0; fifo_read_ptr2 <= 0;
                end

                WAIT_DATA_RESP: begin
                    if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                        $display("Time=%0t [Engine %0d] Got DATA. Writing FIFO1 ptr=%3d", $time, device_id, fifo_write_ptr1);
                        fifo_write_ptr1 <= fifo_write_ptr1 + 1;
                        if (bin.Token) has_token <= 1;
                    end
                end

                WAIT_COEF_RESP: begin
                    if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                        $display("Time=%0t [Engine %0d] Got COEF. Writing FIFO2 ptr=%3d", $time, device_id, fifo_write_ptr2);
                        fifo_write_ptr2 <= fifo_write_ptr2 + 1;
                        if (bin.Token) has_token <= 1;
                        cur_data_addr <= cur_data_addr + 1;
                        cur_coef_addr <= cur_coef_addr + 1;
                    end
                end

                COMPUTING: begin
                    resout.result <= tree_sum;
                    resout.pushOut <= 1;
                    // Only decrement groups_remaining once per group output
                    groups_remaining <= groups_remaining - 1;

                    if (compute_idx == 0) begin
                        compute_idx <= 1;
                        state <= COMPUTING;
                    end else begin
                        compute_idx <= 0;
                        // After both halves computed, check if done
                        // groups_remaining was decremented twice (once per half)
                        if (groups_remaining <= 2) begin  // Changed from <= 1
                            state <= STATE_IDLE;
                            config_regs.Busy <= 0;
                        end else begin
                            fifo_read_ptr1 <= fifo_read_ptr1 + 1;
                            fifo_read_ptr2 <= fifo_read_ptr2 + 1;
                            state <= WAIT_TOKEN;
                        end
                    end
                end
            endcase

            if (bin.Opcode == WRITE_REQ && bin.Destination == device_id) begin
                cur_data_addr <= bin.Data[47:0];
                cur_coef_addr <= bin.Data[95:48];
            end
        end
    end

    // --------------------------------------------------------
    // BUS OUTPUT LOGIC
    // --------------------------------------------------------
    always_comb begin
        bout = idle_pkt;
        bout.Token = has_token;

        if (reset !== 1'b0) begin
            bout = empty_pkt;
        end else begin
            // 1. Incomings
            if (bin.Destination == device_id) begin
                if (bin.Opcode == WRITE_REQ) begin
                    bout = idle_pkt; bout.Token = bin.Token;
                end else if (bin.Opcode == READ_REQ) begin
                    bout.Opcode = RDATA;
                    bout.Source = device_id;
                    bout.Destination = bin.Source;
                    bout.Token = 1;
                    bout.Data = '0;
                    bout.Data[($bits(REGS)-1):0] = config_regs;
                end else if (bin.Opcode == RDATA) begin
                    bout = idle_pkt; bout.Token = bin.Token | has_token;
                end
            end else if (bin.Opcode != EMPTY && bin.Opcode != IDLE) begin
                bout = bin;
            end

            // 2. Outgoings - FORCE TOKEN RELEASE
            if (state == SEND_DATA_REQ) begin
                bout.Opcode = READ_REQ;
                bout.Source = device_id;
                bout.Destination = 4'd8;
                bout.Token = 1;
                bout.Data = '0;
                bout.Data[47:0] = cur_data_addr;
                bout.Data[51:48] = 4'd1;
            end else if (state == SEND_COEF_REQ) begin
                bout.Opcode = READ_REQ;
                bout.Source = device_id;
                bout.Destination = 4'd8;
                bout.Token = 1;
                bout.Data = '0;
                bout.Data[47:0] = cur_coef_addr;
                bout.Data[51:48] = 4'd1;
            end
        end
    end

    // --------------------------------------------------------
    // FIFO CONTROL
    // --------------------------------------------------------
    assign f1write = (state == WAIT_DATA_RESP && bin.Opcode == RDATA && bin.Destination == device_id);
    assign f1wadr = fifo_write_ptr1;
    assign f1wdata = f1write ? bin.Data : 1008'h0;
    assign f1radr = fifo_read_ptr1;

    assign f2write = (state == WAIT_COEF_RESP && bin.Opcode == RDATA && bin.Destination == device_id);
    assign f2wadr = fifo_write_ptr2;
    assign f2wdata = f2write ? bin.Data : 1008'h0;
    assign f2radr = fifo_read_ptr2;

endmodule
