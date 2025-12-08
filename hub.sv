module hub(
    input logic clk, reset,
    // Testbench bus
    input RBUS tbin,
    output RBUS tbout,
    // Ring 0
    input RBUS R0in,
    output RBUS R0out,
    // Ring 1
    input RBUS R1in,
    output RBUS R1out,
    // Ring 2
    input RBUS R2in,
    output RBUS R2out,
    // Ring 3
    input RBUS R3in,
    output RBUS R3out
);
    // Default Empty Packet
    RBUS empty_pkt;
    always_comb begin
        empty_pkt = '0;
        empty_pkt.Opcode = EMPTY;
        empty_pkt.Token = 1;
    end

    // DEBUG: Monitor Traffic
    always @(posedge clk) begin
        if (!reset) begin
            if (tbin.Opcode != EMPTY && tbin.Opcode != IDLE)
                $display("Time=%0t [HUB] TB Input: Op=%s Src=%0d Dst=%0d Tok=%0d",
                    $time, tbin.Opcode.name(), tbin.Source, tbin.Destination, tbin.Token);

            if (R0in.Opcode != EMPTY && R0in.Opcode != IDLE)
                $display("Time=%0t [HUB] R0 Input: Op=%s Src=%0d Dst=%0d Tok=%0d",
                    $time, R0in.Opcode.name(), R0in.Source, R0in.Destination, R0in.Token);
            else if (R0in.Token)
                $display("Time=%0t [HUB] R0 Input: TOKEN (Op=%s)", $time, R0in.Opcode.name());

            if (R0in.Opcode != EMPTY && R0in.Opcode != IDLE && R0in.Destination != 4'd0)
                 $display("Time=%0t [HUB] Selected[0]: Op=%s Src=%0d Dst=%0d -> Broadcasting",
                    $time, R0in.Opcode.name(), R0in.Source, R0in.Destination);
        end
    end

    //---------------------------------------------------------
    // TB -> Ring Routing: Forward TB messages OR Recirculate Ring messages
    //---------------------------------------------------------
    always_comb begin
        if (reset !== 1'b0) begin
            R0out = empty_pkt; R1out = empty_pkt;
            R2out = empty_pkt; R3out = empty_pkt;
        end else begin
            // --------------------------------------------------------
            // FORWARDING LOGIC
            // --------------------------------------------------------
            if (R0in.Token || (R0in.Opcode != EMPTY && R0in.Opcode != IDLE && R0in.Destination != 4'd0))
                R0out = R0in;
            else
                R0out = empty_pkt;

            if (R1in.Token || (R1in.Opcode != EMPTY && R1in.Opcode != IDLE && R1in.Destination != 4'd0))
                R1out = R1in;
            else
                R1out = empty_pkt;

            if (R2in.Token || (R2in.Opcode != EMPTY && R2in.Opcode != IDLE && R2in.Destination != 4'd0))
                R2out = R2in;
            else
                R2out = empty_pkt;

            if (R3in.Token || (R3in.Opcode != EMPTY && R3in.Opcode != IDLE && R3in.Destination != 4'd0))
                R3out = R3in;
            else
                R3out = empty_pkt;

            // --------------------------------------------------------
            // TESTBENCH OVERRIDE
            // --------------------------------------------------------
            if (tbin.Opcode != EMPTY && tbin.Opcode != IDLE) begin
                case (tbin.Destination)
                    4'd8, 4'd9:   R0out = tbin;
                    4'd10, 4'd11: R1out = tbin;
                    4'd12, 4'd13: R2out = tbin;
                    4'd14, 4'd15: R3out = tbin;
                    default:      ;
                endcase
            end
        end
    end

    //---------------------------------------------------------
    // Ring -> TB Routing
    //---------------------------------------------------------
    logic [1:0] priority_state;
    logic r0_has, r1_has, r2_has, r3_has;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            priority_state <= 2'd0;
        end else begin
            if (tbout.Opcode != EMPTY && tbout.Opcode != IDLE) begin
                priority_state <= priority_state + 1;
            end
        end
    end

    always_comb begin
        if (reset !== 1'b0) begin
            tbout = empty_pkt;
        end else begin
            r0_has = (R0in.Opcode != EMPTY && R0in.Opcode != IDLE) && (R0in.Destination == 4'd0);
            r1_has = (R1in.Opcode != EMPTY && R1in.Opcode != IDLE) && (R1in.Destination == 4'd0);
            r2_has = (R2in.Opcode != EMPTY && R2in.Opcode != IDLE) && (R2in.Destination == 4'd0);
            r3_has = (R3in.Opcode != EMPTY && R3in.Opcode != IDLE) && (R3in.Destination == 4'd0);

            tbout = empty_pkt;
            case (priority_state)
                2'd0: begin
                    if      (r0_has) tbout = R0in;
                    else if (r1_has) tbout = R1in;
                    else if (r2_has) tbout = R2in;
                    else if (r3_has) tbout = R3in;
                end
                2'd1: begin
                    if      (r1_has) tbout = R1in;
                    else if (r2_has) tbout = R2in;
                    else if (r3_has) tbout = R3in;
                    else if (r0_has) tbout = R0in;
                end
                2'd2: begin
                    if      (r2_has) tbout = R2in;
                    else if (r3_has) tbout = R3in;
                    else if (r0_has) tbout = R0in;
                    else if (r1_has) tbout = R1in;
                end
                2'd3: begin
                    if      (r3_has) tbout = R3in;
                    else if (r0_has) tbout = R0in;
                    else if (r1_has) tbout = R1in;
                    else if (r2_has) tbout = R2in;
                end
            endcase
        end
    end
endmodule
