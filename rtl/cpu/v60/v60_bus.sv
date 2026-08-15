//============================================================================
//  V60 logical-bus adapter (DESIGN.md §5.4 "bus unit")
//  Turns the CPU's logical accesses (any address, size 1/2/4 bytes) into
//  1..3 aligned 16-bit cycles on the system bus (V60 has a 16-bit external
//  data bus).  V70 (IS_V70=1) uses 1..2 aligned 32-bit cycles.
//============================================================================

module s32_v60_bus #(
    parameter IS_V70 = 1'b0
)(
    input             clk,
    input             ce,
    input             rst,

    // CPU side (logical)
    input             c_req,
    input             c_we,
    input      [31:0] c_addr,
    input       [1:0] c_size,      // 0=B 1=H 2=W
    input      [31:0] c_wdata,
    output reg [31:0] c_rdata,
    output reg        c_ack,

    // system side: 16-bit bus
    output reg        m_req,
    output reg        m_we,
    output reg [23:1] m_addr,
    output reg [15:0] m_wdata,
    output reg  [1:0] m_be,
    input      [15:0] m_rdata,
    input             m_ack
);

typedef enum logic [1:0] { I_IDLE, I_CYC, I_WAIT } bst_t;
bst_t bst;

reg [1:0]  cyc, cycs;        // current / total 16-bit cycles - 1
reg [31:0] acc;
reg [31:0] addr_r;
reg [31:0] wdata_r;
reg [1:0]  size_r;
reg        we_r;
reg        c_req_d;

// how many 16-bit cycles and initial byte lane for a given access
always @(posedge clk) begin
    if (rst) begin
        bst <= I_IDLE; m_req <= 0; c_ack <= 0; c_req_d <= 0;
    end
    else if (ce) begin
        c_ack <= 1'b0;
        c_req_d <= c_req;

        case (bst)
        I_IDLE: if (c_req && !c_req_d) begin
            addr_r  <= c_addr;
            wdata_r <= c_wdata;
            size_r  <= c_size;
            we_r    <= c_we;
            cyc     <= 0;
            // cycles needed
            case (c_size)
                2'd0: cycs <= 0;                                   // byte: 1
                2'd1: cycs <= (c_addr[0]) ? 2'd1 : 2'd0;           // half: 1 or 2
                default: cycs <= (c_addr[0]) ? 2'd2 : 2'd1;        // word: 2 or 3
            endcase
            bst <= I_CYC;
        end
        I_CYC: begin
            m_req  <= 1'b1;
            m_we   <= we_r;
            // For each 16-bit cycle, figure the aligned word address and lanes
            if (!addr_r[0]) begin
                m_addr  <= addr_r[23:1] + {21'b0, cyc};
                case (size_r)
                    2'd0: begin m_be <= 2'b01; m_wdata <= {8'h00, wdata_r[7:0]}; end
                    2'd1: begin m_be <= 2'b11; m_wdata <= wdata_r[15:0]; end
                    default: begin
                        m_be <= 2'b11;
                        m_wdata <= (cyc == 0) ? wdata_r[15:0] : wdata_r[31:16];
                    end
                endcase
            end
            else begin
                // unaligned start: first cycle covers high lane of first word
                if (cyc == 0) begin
                    m_addr <= addr_r[23:1];
                    m_be   <= 2'b10;
                    m_wdata<= {wdata_r[7:0], 8'h00};
                end
                else begin
                    m_addr <= addr_r[23:1] + {21'b0, cyc};
                    if (cyc == cycs && size_r == 2'd2) begin
                        m_be    <= 2'b01;
                        m_wdata <= {8'h00, wdata_r[31:24]};
                    end
                    else if (cyc == cycs && size_r == 2'd1) begin
                        m_be    <= 2'b01;
                        m_wdata <= {8'h00, wdata_r[15:8]};
                    end
                    else begin
                        m_be    <= 2'b11;
                        m_wdata <= wdata_r[23:8];
                    end
                end
            end
            bst <= I_WAIT;
        end
        I_WAIT: if (m_ack) begin
            m_req <= 1'b0;
            // assemble read data
            if (!we_r) begin
                if (!addr_r[0]) begin
                    case (size_r)
                        2'd0: acc[7:0] <= m_rdata[7:0];
                        2'd1: acc[15:0] <= m_rdata;
                        default: begin
                            if (cyc == 0) acc[15:0]  <= m_rdata;
                            else          acc[31:16] <= m_rdata;
                        end
                    endcase
                end
                else begin
                    if (cyc == 0) acc[7:0] <= m_rdata[15:8];
                    else if (cyc == cycs && size_r == 2'd2) acc[31:24] <= m_rdata[7:0];
                    else if (cyc == cycs && size_r == 2'd1) acc[15:8]  <= m_rdata[7:0];
                    else acc[23:8] <= m_rdata;
                end
            end
            if (cyc == cycs) begin
                bst <= I_IDLE;
                c_ack <= 1'b1;
            end
            else begin
                cyc <= cyc + 1'd1;
                bst <= I_CYC;
            end
        end
        default: bst <= I_IDLE;
        endcase

        // read data out (combinable timing: valid with c_ack)
        if (bst == I_WAIT && m_ack && cyc == cycs && !we_r) begin
            // merge final lane into output
            c_rdata <= acc;
            if (!addr_r[0]) begin
                case (size_r)
                    2'd0: c_rdata <= {24'b0, m_rdata[7:0]};
                    2'd1: c_rdata <= {16'b0, m_rdata};
                    default: c_rdata <= (cycs == 2'd1) ? {m_rdata, acc[15:0]} : acc;
                endcase
            end
            else begin
                case (size_r)
                    2'd0: c_rdata <= {24'b0, m_rdata[15:8]};
                    2'd1: c_rdata <= {16'b0, m_rdata[7:0], acc[7:0]};
                    default: c_rdata <= {m_rdata[7:0], acc[23:0]};
                endcase
            end
        end
    end
end

endmodule
