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
    // 1. MATH FUNCTIONS
    // --------------------------------------------------------
    function automatic logic signed [47:0] calc_term(input logic [11:0] D, input logic [11:0] C);
        logic s_d, s_c, s_res;
        logic signed [4:0] e_d, e_c;
        logic signed [6:0] e_sum;
        logic [5:0] m_d, m_c;
        logic [13:0] m_prod;
        logic signed [47:0] fixed_res;
        int shift_amount;

        // Check for zero (all 1's in exponent and fraction)
        if (D[10:0] == 11'h7FF || C[10:0] == 11'h7FF) return 48'd0;

        s_d = D[11]; s_c = C[11];
        e_d = D[10:6]; e_c = C[10:6];
        m_d = D[5:0]; m_c = C[5:0];

        // Multiply mantissas with hidden 1: (1.mmmmmm) * (1.mmmmmm)
        // {1,6'b0} * {1,6'b0} = 7'd64 * 7'd64 = 14'd4096 = 14'b01_000000_000000
        // Product is 14 bits in 2.12 format (bits [13:12] integer, bits [11:0] fractional)
        m_prod = {1'b1, m_d} * {1'b1, m_c};

        // Add exponents (both in 2's complement)
        e_sum = $signed({e_d[4], e_d}) + $signed({e_c[4], e_c});

        // Determine sign
        s_res = s_d ^ s_c;

        // Place m_prod in lower bits of result
        fixed_res = $signed({34'b0, m_prod});

        // Target format: 24.24 (binary point after bit 24)
        // m_prod has binary point after bit 12 (positions [11:0] are fractional)
        // To align bit 12 of m_prod to bit 24 of result: shift left by 12
        // Then apply exponent adjustment: shift by e_sum
        // Total shift: 12 + e_sum
        shift_amount = 12 + $signed(e_sum);

        if (shift_amount >= 0) begin
            if (shift_amount < 48)
                fixed_res = fixed_res << shift_amount;
            else
                fixed_res = 48'sd0; // Overflow
        end else begin
            if (shift_amount > -48)
                fixed_res = fixed_res >>> (-shift_amount);
            else
                fixed_res = 48'sd0; // Underflow
        end

        // Apply sign
        if (s_res) fixed_res = -fixed_res;

        return fixed_res;
    endfunction

    // --------------------------------------------------------
    // 2. STATE & REGISTERS
    // --------------------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_PRIME, S_WAIT, S_RUN, S_DONE} state_t;
    state_t state;

    REGS config_regs;
    logic signed [31:0] feed_count;
    logic process_upper;
    logic signed [47:0] accumulator, tree_sum;
    logic [7:0] read_ptr1, read_ptr2;

    wire [11:0] data_lower [41:0];
    wire [11:0] coef_lower [41:0];
    wire [11:0] data_upper [41:0];
    wire [11:0] coef_upper [41:0];

    RBUS empty_pkt;
    always_comb begin
        empty_pkt = '0;
        empty_pkt.Opcode = EMPTY;
        empty_pkt.Token = 1;
    end

    // --------------------------------------------------------
    // 3. BUS INTERFACE - Simple forwarding with response generation
    // --------------------------------------------------------
    always_comb begin
        if (reset !== 1'b0) begin
            bout = empty_pkt;
        end else begin
            if (^bin.Opcode === 1'bx) begin
                bout = empty_pkt;
            end else begin
                // Default: forward the message unchanged
                bout = bin;

                // If message is for us, handle it
                if (bin.Destination == device_id && bin.Opcode != EMPTY && bin.Opcode != IDLE) begin
                    if (bin.Opcode == READ_REQ) begin
                        // Respond with our config registers
                        bout.Opcode = RDATA;
                        bout.Token = 1;
                        bout.Source = device_id;
                        bout.Destination = bin.Source;
                        bout.Data = '0;
                        bout.Data[($bits(REGS)-1):0] = config_regs;
                    end else begin
                        // WRITE_REQ or other - consume it, send empty
                        bout = empty_pkt;
                    end
                end
            end
        end
    end

    // Register updates
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            config_regs <= '0;
        end else begin
            if (bin.Opcode == WRITE_REQ && bin.Destination == device_id) begin
                config_regs <= bin.Data;
                config_regs.Busy <= 1;  // Set busy on write (spec says "ignored on write")
            end else if (state == S_DONE) begin
                config_regs.Busy <= 0;
            end
        end
    end

    // --------------------------------------------------------
    // 4. DATAPATH
    // --------------------------------------------------------
    assign f1write = 0; assign f1wadr = 0; assign f1wdata = 0;
    assign f2write = 0; assign f2wadr = 0; assign f2wdata = 0;

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
        tree_sum = 0;
        for (int j=0; j<42; j++) begin
            logic [11:0] d_raw, c_raw, d_safe, c_safe;

            if (process_upper) begin
                d_raw = data_upper[j];
                c_raw = coef_upper[j];
            end else begin
                d_raw = data_lower[j];
                c_raw = coef_lower[j];
            end

            d_safe = (^d_raw === 1'bx) ? 12'd0 : d_raw;
            c_safe = (^c_raw === 1'bx) ? 12'd0 : c_raw;

            tree_sum = tree_sum + calc_term(d_safe, c_safe);
        end
    end

    // --------------------------------------------------------
    // 5. CONTROL FSM
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            feed_count <= 0;
            accumulator <= 0;
            read_ptr1 <= 0;
            read_ptr2 <= 0;
            resout <= '0;
            f1radr <= 0;
            f2radr <= 0;
            process_upper <= 0;
        end else begin
            resout.pushOut <= 0;

            // Trigger on WRITE
            if (state == S_IDLE && bin.Opcode == WRITE_REQ && bin.Destination == device_id) begin
                state <= S_PRIME;
            end

            case (state)
                S_IDLE: begin
                    accumulator <= 0;
                    feed_count <= 0;
                    process_upper <= 0;
                    if (config_regs.Busy) begin
                        state <= S_PRIME;
                    end
                end

                S_PRIME: begin
                    f1radr <= config_regs.DataAddress[7:0];
                    f2radr <= config_regs.CoefAddress[7:0];
                    read_ptr1 <= config_regs.DataAddress[7:0] + 1;
                    read_ptr2 <= config_regs.CoefAddress[7:0] + 1;
                    process_upper <= 0;
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    state <= S_RUN;
                end

                S_RUN: begin
                    if (feed_count < config_regs.NumGroups) begin
                        accumulator <= accumulator + tree_sum;

                        if (process_upper == 0) begin
                            process_upper <= 1;
                        end else begin
                            process_upper <= 0;
                            f1radr <= read_ptr1;
                            f2radr <= read_ptr2;
                            read_ptr1 <= read_ptr1 + 1;
                            read_ptr2 <= read_ptr2 + 1;
                        end

                        feed_count <= feed_count + 1;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    resout.result <= accumulator;
                    resout.pushOut <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
