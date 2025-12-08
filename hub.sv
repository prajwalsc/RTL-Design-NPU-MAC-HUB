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

    //---------------------------------------------------------
    // TB -> Ring Routing: Forward TB messages to correct ring
    //---------------------------------------------------------
    always_comb begin
        if (reset !== 1'b0) begin
            R0out = empty_pkt;
            R1out = empty_pkt;
            R2out = empty_pkt;
            R3out = empty_pkt;
        end else begin
            // Default: empty packets
            R0out = empty_pkt;
            R1out = empty_pkt;
            R2out = empty_pkt;
            R3out = empty_pkt;

            // Route non-empty TB messages to appropriate ring based on destination
            if (tbin.Opcode != EMPTY && tbin.Opcode != IDLE) begin
                case (tbin.Destination)
                    4'd8, 4'd9:   R0out = tbin;  // Memory0 or Device0
                    4'd10, 4'd11: R1out = tbin;  // Memory1 or Device1
                    4'd12, 4'd13: R2out = tbin;  // Memory2 or Device2
                    4'd14, 4'd15: R3out = tbin;  // Memory3 or Device3
                    default:      ; // Unknown destination, stay empty
                endcase
            end
        end
    end

    //---------------------------------------------------------
    // Ring -> TB Routing: Priority arbitration for responses
    //---------------------------------------------------------
    logic [1:0] priority_state;
    logic r0_has_response, r1_has_response, r2_has_response, r3_has_response;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            priority_state <= 2'd0;
        end else begin
            // Rotate priority when we forward a response
            if (tbout.Opcode != EMPTY && tbout.Opcode != IDLE && tbout.Destination == 4'd0) begin
                priority_state <= priority_state + 1;
            end
        end
    end

    always_comb begin
        if (reset !== 1'b0) begin
            tbout = empty_pkt;
        end else begin
            // Check which rings have responses destined for TB
            r0_has_response = (R0in.Opcode != EMPTY && R0in.Opcode != IDLE) && (R0in.Destination == 4'd0);
            r1_has_response = (R1in.Opcode != EMPTY && R1in.Opcode != IDLE) && (R1in.Destination == 4'd0);
            r2_has_response = (R2in.Opcode != EMPTY && R2in.Opcode != IDLE) && (R2in.Destination == 4'd0);
            r3_has_response = (R3in.Opcode != EMPTY && R3in.Opcode != IDLE) && (R3in.Destination == 4'd0);

            // Select response based on rotating priority
            tbout = empty_pkt;
            case (priority_state)
                2'd0: begin
                    if      (r0_has_response) tbout = R0in;
                    else if (r1_has_response) tbout = R1in;
                    else if (r2_has_response) tbout = R2in;
                    else if (r3_has_response) tbout = R3in;
                end
                2'd1: begin
                    if      (r1_has_response) tbout = R1in;
                    else if (r2_has_response) tbout = R2in;
                    else if (r3_has_response) tbout = R3in;
                    else if (r0_has_response) tbout = R0in;
                end
                2'd2: begin
                    if      (r2_has_response) tbout = R2in;
                    else if (r3_has_response) tbout = R3in;
                    else if (r0_has_response) tbout = R0in;
                    else if (r1_has_response) tbout = R1in;
                end
                2'd3: begin
                    if      (r3_has_response) tbout = R3in;
                    else if (r0_has_response) tbout = R0in;
                    else if (r1_has_response) tbout = R1in;
                    else if (r2_has_response) tbout = R2in;
                end
            endcase
        end
    end
endmodule
