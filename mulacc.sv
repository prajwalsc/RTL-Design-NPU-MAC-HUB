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
    
    // --------------------------------------------------------
    // REGISTERS & SIGNALS
    // --------------------------------------------------------
    REGS config_regs, next_config;
    logic [7:0] fifo_write_ptr1, fifo_write_ptr2;
    logic [7:0] fifo_read_ptr1, fifo_read_ptr2;
    logic signed [31:0] groups_remaining, next_groups;
    logic signed [47:0] accumulator;
    logic has_token;
    logic [6:0] compute_idx;
    
    RBUS empty_pkt;
    always_comb begin
        empty_pkt = '0;
        empty_pkt.Opcode = EMPTY;
        empty_pkt.Token = 1;
    end
    
    RBUS idle_pkt;
    always_comb begin
        idle_pkt = '0;
        idle_pkt.Opcode = IDLE;
        idle_pkt.Source = device_id;
        idle_pkt.Destination = 0;
        idle_pkt.Token = has_token ? 1'b1 : 1'b0;
    end
    
    // --------------------------------------------------------
    // MATH FUNCTIONS
    // --------------------------------------------------------
    function automatic logic signed [47:0] calc_term(input logic [11:0] D, input logic [11:0] C);
        logic s_d, s_c, s_res;
        logic signed [4:0] e_d, e_c;
        logic signed [6:0] e_sum;
        logic [5:0] m_d, m_c;
        logic [13:0] m_prod;
        logic signed [47:0] fixed_res;
        int shift_amount;

        if (D[10:0] == 11'h7FF || C[10:0] == 11'h7FF) return 48'd0;

        s_d = D[11]; s_c = C[11];
        e_d = D[10:6]; e_c = C[10:6];
        m_d = D[5:0]; m_c = C[5:0];

        m_prod = {1'b1, m_d} * {1'b1, m_c};
        e_sum = $signed({e_d[4], e_d}) + $signed({e_c[4], e_c});
        s_res = s_d ^ s_c;

        fixed_res = $signed({34'b0, m_prod});
        shift_amount = 12 + $signed(e_sum);
        
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

        if (s_res) fixed_res = -fixed_res;
        return fixed_res;
    endfunction
    
    // --------------------------------------------------------
    // DATA UNPACKING
    // --------------------------------------------------------
    wire [11:0] data_val [83:0];
    wire [11:0] coef_val [83:0];
    
    genvar i;
    generate
        for (i=0; i<42; i++) begin : UNPACK_LOWER
            assign data_val[i] = f1rdata[(i*12) +: 12];
            assign coef_val[i] = f2rdata[(i*12) +: 12];
        end
        for (i=42; i<84; i++) begin : UNPACK_UPPER
            assign data_val[i] = f1rdata[((i-42)*12 + 504) +: 12];
            assign coef_val[i] = f2rdata[((i-42)*12 + 504) +: 12];
        end
    endgenerate
    
    // --------------------------------------------------------
    // COMPUTATION
    // --------------------------------------------------------
    logic signed [47:0] tree_sum;
    
    always_comb begin
        automatic logic [11:0] d_safe, c_safe;
        automatic int idx;
        
        tree_sum = 0;
        for (int j=0; j<42; j++) begin
            idx = compute_idx * 42 + j;
            d_safe = (^data_val[idx] === 1'bx) ? 12'd0 : data_val[idx];
            c_safe = (^coef_val[idx] === 1'bx) ? 12'd0 : coef_val[idx];
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
            // Show received messages
            if (bin.Opcode != EMPTY && bin.Opcode != IDLE) begin
                $display("Time=%0t [Engine %0d] Rx: Op=%s Src=%0d Dst=%0d Tok=%0d State=%s",
                    $time, device_id, bin.Opcode.name(), bin.Source, bin.Destination,
                    bin.Token, state.name());
            end
            
            // Show transmit (current output)
            if (bout.Opcode != EMPTY || bout.Token) begin
                $display("Time=%0t [Engine %0d] Tx: Op=%s Src=%0d Dst=%0d Tok=%0d State=%s",
                    $time, device_id, bout.Opcode.name(), bout.Source, bout.Destination, 
                    bout.Token, state.name());
            end
            
            // Show state transitions (what will happen next cycle)
            if (next_state != state) begin
                $display("Time=%0t [Engine %0d] State: %s -> %s",
                    $time, device_id, state.name(), next_state.name());
            end
            
            // Show config updates
            if (bin.Opcode == WRITE_REQ && bin.Destination == device_id) begin
                $display("Time=%0t [Engine %0d] Config: DataAddr=%012h CoefAddr=%012h Groups=%0d",
                    $time, device_id, bin.Data[47:0], bin.Data[95:48], $signed(bin.Data[127:96]));
            end
        end
    end
    
    // --------------------------------------------------------
    // NEXT STATE LOGIC
    // --------------------------------------------------------
    always_comb begin
        next_state = state;
        next_config = config_regs;
        next_groups = groups_remaining;
        
        // Handle WRITE_REQ configuration
        if (bin.Opcode == WRITE_REQ && bin.Destination == device_id) begin
            next_config.DataAddress = bin.Data[47:0];
            next_config.CoefAddress = bin.Data[95:48];
            next_config.NumGroups = bin.Data[127:96];
            next_config.ChainAddress = bin.Data[175:128];
            next_config.Busy = 1;
            next_groups = $signed(bin.Data[127:96]);
            if (state == STATE_IDLE) begin
                next_state = WAIT_TOKEN;
            end
        end
        
        // State transitions
        case (state)
            WAIT_TOKEN: begin
                if (has_token || bin.Token) begin
                    next_state = SEND_DATA_REQ;
                end
            end
            
            SEND_DATA_REQ: begin
                next_state = WAIT_DATA_RESP;
            end
            
            WAIT_DATA_RESP: begin
                if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                    next_state = SEND_COEF_REQ;
                end
            end
            
            SEND_COEF_REQ: begin
                next_state = WAIT_COEF_RESP;
            end
            
            WAIT_COEF_RESP: begin
                if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                    next_state = PREP_READ;
                end
            end
            
            PREP_READ: begin
                next_state = FIFO_LATENCY;
            end
            
            FIFO_LATENCY: begin
                next_state = FEED_DATAPATH;
            end
            
            FEED_DATAPATH: begin
                next_state = COMPUTING;
            end
            
            COMPUTING: begin
                // Stay in computing until done with all cycles
            end
        endcase
    end
    
    // --------------------------------------------------------
    // STATE REGISTER & DATAPATH
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            has_token <= 0;
            config_regs <= '0;
            fifo_write_ptr1 <= 0;
            fifo_write_ptr2 <= 0;
            fifo_read_ptr1 <= 0;
            fifo_read_ptr2 <= 0;
            groups_remaining <= 0;
            accumulator <= 0;
            compute_idx <= 0;
            resout <= '0;
        end else begin
            state <= next_state;
            config_regs <= next_config;
            groups_remaining <= next_groups;
            resout.pushOut <= 0;
            
            // Capture token
            if (bin.Token && !has_token && bin.Destination != device_id) begin
                has_token <= 1;
            end
            
            // State-specific actions
            case (state)
                STATE_IDLE: begin
                    accumulator <= 0;
                    compute_idx <= 0;
                    fifo_write_ptr1 <= 0;
                    fifo_write_ptr2 <= 0;
                    fifo_read_ptr1 <= 0;
                    fifo_read_ptr2 <= 0;
                end
                
                WAIT_DATA_RESP: begin
                    if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                        $display("Time=%0t [Engine %0d] Got DATA. Writing FIFO1 ptr=%3d",
                            $time, device_id, fifo_write_ptr1);
                        fifo_write_ptr1 <= fifo_write_ptr1 + 1;
                    end
                end
                
                WAIT_COEF_RESP: begin
                    if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                        $display("Time=%0t [Engine %0d] Got COEF. Writing FIFO2 ptr=%3d",
                            $time, device_id, fifo_write_ptr2);
                        fifo_write_ptr2 <= fifo_write_ptr2 + 1;
                    end
                end
                
                COMPUTING: begin
                    // Output result for current group
                    resout.result <= tree_sum;
                    resout.pushOut <= 1;
                    groups_remaining <= groups_remaining - 1;
                    
                    if (compute_idx == 0) begin
                        // Just finished first group, process second group from same word
                        compute_idx <= 1;
                    end else begin
                        // Just finished second group, fetch next word
                        compute_idx <= 0;
                        
                        if (groups_remaining <= 1) begin
                            state <= STATE_IDLE;
                            config_regs.Busy <= 0;
                        end else begin
                            fifo_read_ptr1 <= fifo_read_ptr1 + 1;
                            fifo_read_ptr2 <= fifo_read_ptr2 + 1;
                            state <= SEND_DATA_REQ;
                        end
                    end
                end
            endcase
        end
    end
    
    // --------------------------------------------------------
    // BUS OUTPUT LOGIC
    // --------------------------------------------------------
    logic req_print_done_data, req_print_done_coef;
    
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            req_print_done_data <= 0;
            req_print_done_coef <= 0;
        end else begin
            // Print only once per request when entering the state
            if (state == SEND_DATA_REQ && !req_print_done_data) begin
                $display("T=%0t [Eng %0d] READ_REQ DATA: mem=%0d addr=%0d len=%0d",
                    $time, device_id, 8, config_regs.DataAddress + fifo_write_ptr1, 1);
                req_print_done_data <= 1;
            end else if (state != SEND_DATA_REQ) begin
                req_print_done_data <= 0;
            end
            
            if (state == SEND_COEF_REQ && !req_print_done_coef) begin
                $display("T=%0t [Eng %0d] READ_REQ COEF: mem=%0d addr=%0d len=%0d",
                    $time, device_id, 8, config_regs.CoefAddress + fifo_write_ptr2, 1);
                req_print_done_coef <= 1;
            end else if (state != SEND_COEF_REQ) begin
                req_print_done_coef <= 0;
            end
        end
    end
    
    always_comb begin
        bout = idle_pkt;
        
        if (reset !== 1'b0) begin
            bout = empty_pkt;
        end else begin
            // Handle messages for us
            if (bin.Destination == device_id) begin
                if (bin.Opcode == WRITE_REQ) begin
                    // Consume WRITE_REQ
                    bout = idle_pkt;
                    bout.Token = 0;
                end else if (bin.Opcode == READ_REQ) begin
                    // Respond with config
                    bout.Opcode = RDATA;
                    bout.Source = device_id;
                    bout.Destination = bin.Source;
                    bout.Token = 1;
                    bout.Data = '0;
                    bout.Data[($bits(REGS)-1):0] = config_regs;
                end else if (bin.Opcode == RDATA) begin
                    // Consume RDATA
                    bout = idle_pkt;
                    bout.Token = 0;
                end
            end else if (bin.Opcode != EMPTY && bin.Opcode != IDLE) begin
                // Forward messages not for us
                bout = bin;
            end
            
            // Override with our requests when in send states
            if (state == SEND_DATA_REQ) begin
                bout.Opcode = READ_REQ;
                bout.Source = device_id;
                bout.Destination = 4'd8;
                bout.Token = 1;
                bout.Data = '0;
                bout.Data[3:0] = 4'd1;
                bout.Data[51:4] = config_regs.DataAddress + fifo_write_ptr1;
            end else if (state == SEND_COEF_REQ) begin
                bout.Opcode = READ_REQ;
                bout.Source = device_id;
                bout.Destination = 4'd8;
                bout.Token = 1;
                bout.Data = '0;
                bout.Data[3:0] = 4'd1;
                bout.Data[51:4] = config_regs.CoefAddress + fifo_write_ptr2;
            end
        end
    end
    
    // --------------------------------------------------------
    // FIFO CONTROL - Use combinational data with gated output
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
