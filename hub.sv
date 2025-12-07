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
    // TB -> Ring Routing
    //---------------------------------------------------------
    always_comb begin
        if (reset !== 1'b0) begin
            R0out = empty_pkt;
            R1out = empty_pkt;
            R2out = empty_pkt;
            R3out = empty_pkt;
        end else begin
            R0out = empty_pkt;
            R1out = empty_pkt;
            R2out = empty_pkt;
            R3out = empty_pkt;

            if (tbin.Opcode != EMPTY && tbin.Opcode != IDLE) begin
                case (tbin.Destination)
                    4'd8, 4'd9:   R0out = tbin;
                    4'd10, 4'd11: R1out = tbin;
                    4'd12, 4'd13: R2out = tbin;
                    4'd14, 4'd15: R3out = tbin;
                    default: ; 
                endcase
            end
        end
    end

    //---------------------------------------------------------
    // Ring -> TB Routing
    //---------------------------------------------------------
    always_comb begin
        if (reset !== 1'b0) begin
            tbout = empty_pkt;
        end else begin
            tbout = empty_pkt;
            
            if ((R0in.Opcode != EMPTY && R0in.Opcode != IDLE) && R0in.Destination == 4'd0) begin
                tbout = R0in;
            end
            else if ((R1in.Opcode != EMPTY && R1in.Opcode != IDLE) && R1in.Destination == 4'd0) begin
                tbout = R1in;
            end
            else if ((R2in.Opcode != EMPTY && R2in.Opcode != IDLE) && R2in.Destination == 4'd0) begin
                tbout = R2in;
            end
            else if ((R3in.Opcode != EMPTY && R3in.Opcode != IDLE) && R3in.Destination == 4'd0) begin
                tbout = R3in;
            end
        end
    end

endmodule
