// =============================================================================
// ahb2apb_bridge.sv
//
// AHB-Lite slave  ->  APB4 master bridge with a 4-slave address decoder.
//
// References:
//   [AHB] ARM IHI 0033  AMBA 3 AHB-Lite Protocol Specification
//   [APB] ARM IHI 0024  AMBA APB Protocol Specification (APB4: PPROT/PSTRB/PSLVERR)
//
// Micro-architecture summary
// --------------------------
// * Every AHB beat (HTRANS = NONSEQ or SEQ) becomes exactly one APB transfer.
//   Bursts need no special handling: AHB already gives the address of every
//   beat, so HBURST is informational only (unused here, kept on the port list
//   for a complete AHB-Lite slave interface).
// * IDLE and BUSY transfers get a zero-wait OKAY response [AHB 3.2], which is
//   automatic here because they never leave the IDLE state.
// * The AHB address phase is registered when (HSEL & HREADY & HTRANS[1]).
//   Write data arrives one cycle later, in the data phase [AHB 3.1], so writes
//   spend one cycle in ST_WDATA latching HWDATA before APB SETUP.
// * HREADYOUT is held low while the APB transfer is in progress, which stalls
//   the AHB master (wait states) [AHB 3.3].
// * All AHB response outputs (HREADYOUT, HRESP, HRDATA) and all APB outputs are
//   driven from flops / state decode. There is no combinational path from
//   PREADY/PSLVERR to HREADYOUT/HRESP, at the cost of one extra cycle per
//   transfer.
// * ERROR response is the mandatory two-cycle response [AHB 5.1.3]:
//      cycle 1: HRESP=1, HREADYOUT=0  (ST_ERR1)
//      cycle 2: HRESP=1, HREADYOUT=1  (ST_ERR2)
//   It is produced for: APB PSLVERR, an address outside the APB map, and
//   HSIZE wider than the 32-bit data bus.
//
// FSM (APB protocol states are SETUP and ACCESS [APB 4.1]):
//
//            accept & mapped & read                       PREADY & !PSLVERR
//   ST_IDLE ---------------------------> ST_SETUP --> ST_ACCESS ----------------> ST_IDLE
//      |  accept & mapped & write          ^             |  ^ !PREADY (wait)
//      +---------------------> ST_WDATA ---+             |  +--+
//      |                                                 | PREADY & PSLVERR
//      | accept & (unmapped | bad size)                  v
//      +-----------------------------------------------> ST_ERR1 --> ST_ERR2 --> (ST_IDLE or accept)
//
// A new address phase is accepted whenever HREADYOUT is high, i.e. in ST_IDLE
// and in ST_ERR2 (the second ERROR cycle is also the last data-phase cycle).
// =============================================================================
`timescale 1ns/1ps

module ahb2apb_bridge #(
  parameter int unsigned                  NUM_SLV  = 4,
  // Parameterized APB address map: slave i decodes [SLV_BASE[i], SLV_BASE[i]+SLV_SIZE[i]).
  // Defaults: S0 4KB @0x4000_0000, S1 4KB @0x4000_1000, S2 2KB @0x4000_2000, S3 8KB @0x4000_4000.
  // Gaps (e.g. 0x4000_2800-0x4000_3FFF) and everything else are unmapped.
  parameter logic [NUM_SLV-1:0][31:0]     SLV_BASE = {32'h4000_4000, 32'h4000_2000, 32'h4000_1000, 32'h4000_0000},
  parameter logic [NUM_SLV-1:0][31:0]     SLV_SIZE = {32'h0000_2000, 32'h0000_0800, 32'h0000_1000, 32'h0000_1000}
) (
  // ---------------- AHB-Lite slave side ----------------
  input  logic                        HCLK,
  input  logic                        HRESETn,     // active-low, asynchronous assert
  input  logic                        HSEL,
  input  logic [31:0]                 HADDR,
  input  logic [1:0]                  HTRANS,
  input  logic                        HWRITE,
  input  logic [2:0]                  HSIZE,
  input  logic [2:0]                  HBURST,      // unused: each beat is converted independently
  input  logic [3:0]                  HPROT,
  input  logic [31:0]                 HWDATA,
  input  logic                        HREADY,      // global HREADY (from the AHB slave mux)
  output logic                        HREADYOUT,
  output logic                        HRESP,       // 0 = OKAY, 1 = ERROR
  output logic [31:0]                 HRDATA,
  // ---------------- APB4 master side -------------------
  output logic [NUM_SLV-1:0]          PSEL,
  output logic                        PENABLE,
  output logic [31:0]                 PADDR,
  output logic                        PWRITE,
  output logic [31:0]                 PWDATA,
  output logic [3:0]                  PSTRB,
  output logic [2:0]                  PPROT,
  input  logic [NUM_SLV-1:0][31:0]    PRDATA,      // per-slave read data (muxed inside the bridge)
  input  logic [NUM_SLV-1:0]          PREADY,
  input  logic [NUM_SLV-1:0]          PSLVERR
);

  // ---------------------------------------------------------------------------
  // Local definitions
  // ---------------------------------------------------------------------------
  // HTRANS encoding [AHB 3.2]: 00 IDLE, 01 BUSY, 10 NONSEQ, 11 SEQ.
  // HTRANS[1] alone distinguishes a real transfer (NONSEQ/SEQ) from IDLE/BUSY.

  typedef enum logic [2:0] {
    ST_IDLE   = 3'd0,   // no APB transfer; HREADYOUT=1 (also the OKAY completion cycle)
    ST_WDATA  = 3'd1,   // write data phase: latch HWDATA
    ST_SETUP  = 3'd2,   // APB SETUP : PSEL=1, PENABLE=0
    ST_ACCESS = 3'd3,   // APB ACCESS: PSEL=1, PENABLE=1, wait for PREADY
    ST_ERR1   = 3'd4,   // ERROR cycle 1: HRESP=1, HREADYOUT=0
    ST_ERR2   = 3'd5    // ERROR cycle 2: HRESP=1, HREADYOUT=1
  } state_e;

  state_e                state_q;
  logic                  hreadyout_q, hresp_q;
  logic [31:0]           hrdata_q;
  logic [31:0]           addr_q;
  logic                  write_q;
  logic [3:0]            strb_q;
  logic [2:0]            prot_q;
  logic [31:0]           pwdata_q;
  logic [NUM_SLV-1:0]    sel_q;

  // ---------------------------------------------------------------------------
  // Address decoder: one-hot slave select from the parameterized map.
  // 33-bit compare so BASE+SIZE cannot overflow at the top of the address space.
  // ---------------------------------------------------------------------------
  function automatic logic [NUM_SLV-1:0] decode(input logic [31:0] a);
    logic [NUM_SLV-1:0] d;
    for (int i = 0; i < NUM_SLV; i++) begin
`ifdef INJECT_BUG_4
      // BUG 4 (wrong PSEL decode): copy-paste error, slave 2 is decoded with
      // slave 1's 4KB size instead of its own 2KB, so the unmapped hole
      // 0x4000_2800-0x4000_2FFF wrongly selects slave 2.
      if (i == 2)
        d[i] = ({1'b0, a} >= {1'b0, SLV_BASE[i]}) &&
               ({1'b0, a} <  ({1'b0, SLV_BASE[i]} + {1'b0, SLV_SIZE[1]}));
      else
`endif
      d[i] = ({1'b0, a} >= {1'b0, SLV_BASE[i]}) &&
             ({1'b0, a} <  ({1'b0, SLV_BASE[i]} + {1'b0, SLV_SIZE[i]}));
    end
    return d;
  endfunction

  // Byte-lane strobes for a write on a 32-bit little-endian bus [APB 3.1.2]
  function automatic logic [3:0] strobe(input logic [2:0] size, input logic [1:0] a);
    logic [3:0] s;
    case (size)
      3'd0:    s = 4'b0001 << a;                      // byte
      3'd1:    s = a[1] ? 4'b1100 : 4'b0011;         // halfword
      default: s = 4'b1111;                           // word
    endcase
    return s;
  endfunction

  // ---------------------------------------------------------------------------
  // AHB address-phase qualification
  //   A transfer is sampled only when HSEL & HREADY & (NONSEQ|SEQ) [AHB 3.1, 4.1].
  //   The bridge can only take it when it is ready itself (HREADYOUT high), which
  //   in a correct system is implied by HREADY, but is also checked explicitly.
  // ---------------------------------------------------------------------------
  logic               ahb_xfer;
  logic               accept;
  logic [NUM_SLV-1:0] dec;
  logic               bad_size;

  assign ahb_xfer = HSEL && HREADY && HTRANS[1];
  assign accept   = ahb_xfer && hreadyout_q;
  assign dec      = decode(HADDR);
  assign bad_size = (HSIZE > 3'd2);                 // wider than the 32-bit bus

  // Read-data / response mux from the selected APB slave
  logic        pready_m, pslverr_m;
  logic [31:0] prdata_m;
  always_comb begin
    pready_m  = 1'b0;
    pslverr_m = 1'b0;
    prdata_m  = '0;
    for (int i = 0; i < NUM_SLV; i++) begin
      if (sel_q[i]) begin
        pready_m  = pready_m  | PREADY[i];
        pslverr_m = pslverr_m | PSLVERR[i];
        prdata_m  = prdata_m  | PRDATA[i];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Main FSM + registered AHB response
  // ---------------------------------------------------------------------------
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      state_q     <= ST_IDLE;
      hreadyout_q <= 1'b1;   // AHB: HREADYOUT must be high during/after reset [AHB 7.1.2]
      hresp_q     <= 1'b0;
      hrdata_q    <= '0;
      write_q     <= 1'b0;
      strb_q      <= '0;
      prot_q      <= '0;
      sel_q       <= '0;
      pwdata_q    <= '0;
    end else begin
      case (state_q)
        // ---------------------------------------------------------------
        // IDLE and ERR2 both have HREADYOUT=1, so the next address phase
        // may be sampled in either of them.
        // ---------------------------------------------------------------
        ST_IDLE, ST_ERR2: begin
          if (accept) begin
            write_q <= HWRITE;
            strb_q  <= HWRITE ? strobe(HSIZE, HADDR[1:0]) : 4'b0000; // PSTRB=0 on reads [APB 3.1.2]
            // HPROT[0]=data/opcode, HPROT[1]=privileged  ->  PPROT[2]=instruction, PPROT[0]=privileged.
            // AHB-Lite has no security attribute, so PPROT[1] (non-secure) is driven 0 (secure).
            prot_q  <= {~HPROT[0], 1'b0, HPROT[1]};
            if (dec == '0 || bad_size) begin
              // Unmapped address / illegal size: ERROR, and no APB transfer is started.
              sel_q       <= '0;
              state_q     <= ST_ERR1;
              hreadyout_q <= 1'b0;
              hresp_q     <= 1'b1;
            end else begin
              sel_q       <= dec;
              state_q     <= HWRITE ? ST_WDATA : ST_SETUP;
              hreadyout_q <= 1'b0;    // stall AHB for the duration of the APB transfer
              hresp_q     <= 1'b0;
            end
          end else begin
            // IDLE / BUSY / not selected: zero-wait OKAY [AHB 3.2]
            state_q     <= ST_IDLE;
            hreadyout_q <= 1'b1;
            hresp_q     <= 1'b0;
          end
        end

        // Write data is valid in the cycle after the address phase [AHB 3.1]
        ST_WDATA: begin
          pwdata_q <= HWDATA;
          state_q  <= ST_SETUP;
        end

        // APB SETUP lasts exactly one cycle, then always ACCESS [APB 4.1]
        ST_SETUP: begin
          state_q <= ST_ACCESS;
        end

        // APB ACCESS: hold everything until PREADY [APB 3.1.2 / 3.3]
        ST_ACCESS: begin
          if (pready_m) begin
            if (pslverr_m) begin
              state_q     <= ST_ERR1;
              hreadyout_q <= 1'b0;
              hresp_q     <= 1'b1;
            end else begin
              state_q     <= ST_IDLE;
              hreadyout_q <= 1'b1;
              hresp_q     <= 1'b0;
              if (!write_q) hrdata_q <= prdata_m;
            end
          end
        end

        // ERROR cycle 1 -> cycle 2 [AHB 5.1.3]
        ST_ERR1: begin
`ifdef INJECT_BUG_3
          // BUG 3 (second ERROR cycle missing): returns to IDLE after the first
          // ERROR cycle, so the data phase completes with HRESP=0 (OKAY) and the
          // master never sees the error [violates AHB 5.1.3].
          state_q     <= ST_IDLE;
          hreadyout_q <= 1'b1;
          hresp_q     <= 1'b0;
`else
          state_q     <= ST_ERR2;
          hreadyout_q <= 1'b1;
          hresp_q     <= 1'b1;
`endif
        end

        // Unreachable: state_q only ever holds the six encodings above.
        // Kept for safe recovery; excluded from code coverage.
        /* verilator coverage_off */
        default: begin
          state_q     <= ST_IDLE;
          hreadyout_q <= 1'b1;
          hresp_q     <= 1'b0;
        end
        /* verilator coverage_on */
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Address register. Loaded only when a transfer is accepted, so PADDR stays
  // stable through SETUP and every ACCESS wait state even though the master
  // already drives the NEXT address on HADDR (AHB pipelining).
  // ---------------------------------------------------------------------------
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      addr_q <= '0;
`ifdef INJECT_BUG_1
    // BUG 1 (PADDR changes during wait states): the enable is missing the
    // HREADY/ready qualification, so the next pipelined address phase on HADDR
    // overwrites the address of the APB transfer in progress.
    end else if (HSEL && HTRANS[1]) begin
`else
    end else if (accept) begin
`endif
      addr_q <= HADDR;
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign HREADYOUT = hreadyout_q;
  assign HRESP     = hresp_q;
  assign HRDATA    = hrdata_q;

  assign PSEL    = (state_q == ST_SETUP || state_q == ST_ACCESS) ? sel_q : '0;
`ifdef INJECT_BUG_2
  // BUG 2 (PENABLE asserted together with PSEL): SETUP phase skipped.
  assign PENABLE = (state_q == ST_SETUP || state_q == ST_ACCESS);
`else
  assign PENABLE = (state_q == ST_ACCESS);
`endif
  assign PADDR   = addr_q;
  assign PWRITE  = write_q;
  assign PWDATA  = pwdata_q;
  assign PSTRB   = strb_q;
  assign PPROT   = prot_q;

  // Inputs intentionally unused:
  //   HBURST     - per-beat conversion does not need the burst type
  //   HTRANS[0]  - NONSEQ vs SEQ treated identically (each beat is a new APB transfer)
  //   HPROT[3:2] - bufferable/cacheable have no APB equivalent
  /* verilator coverage_off */
  logic unused_ok;
  assign unused_ok = &{1'b0, HBURST, HTRANS[0], HPROT[3:2]};
  /* verilator coverage_on */

endmodule
