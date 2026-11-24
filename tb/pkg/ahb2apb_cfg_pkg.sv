// =============================================================================
// ahb2apb_cfg_pkg.sv
// Shared constants: AHB encodings and the APB address map. tb_top passes the
// map to the DUT as parameters, and the scoreboard and coverage reference it
// independently of the RTL decoder.
// =============================================================================
`timescale 1ns/1ps

package ahb2apb_cfg_pkg;

  localparam int unsigned NUM_SLV = 4;

  // Address map (must match the parameters tb_top passes to the DUT)
  localparam logic [NUM_SLV-1:0][31:0] SLV_BASE = {32'h4000_4000, 32'h4000_2000, 32'h4000_1000, 32'h4000_0000};
  localparam logic [NUM_SLV-1:0][31:0] SLV_SIZE = {32'h0000_2000, 32'h0000_0800, 32'h0000_1000, 32'h0000_1000};

  // AHB encodings [IHI0033]
  typedef enum logic [1:0] { IDLE = 2'b00, BUSY = 2'b01, NONSEQ = 2'b10, SEQ = 2'b11 } htrans_e;
  typedef enum logic [2:0] { SINGLE = 3'd0, INCR = 3'd1, WRAP4 = 3'd2, INCR4 = 3'd3,
                             WRAP8  = 3'd4, INCR8 = 3'd5, WRAP16 = 3'd6, INCR16 = 3'd7 } hburst_e;
  typedef enum logic [2:0] { BYTE = 3'd0, HALF = 3'd1, WORD = 3'd2, DWORD = 3'd3 } hsize_e;
  typedef enum logic       { OKAY = 1'b0, ERROR = 1'b1 } hresp_e;

  // Reference decode: returns slave index 0..NUM_SLV-1, or -1 if unmapped.
  function automatic int decode_slave(input logic [31:0] a);
    for (int i = 0; i < NUM_SLV; i++)
      if ({1'b0, a} >= {1'b0, SLV_BASE[i]} && {1'b0, a} < ({1'b0, SLV_BASE[i]} + {1'b0, SLV_SIZE[i]}))
        return i;
    return -1;
  endfunction

  // Expected PSTRB for an AHB write (0 for reads) [IHI0024 3.1.2]
  function automatic logic [3:0] exp_strobe(input logic write, input logic [2:0] size, input logic [1:0] a);
    if (!write) return 4'b0000;
    case (size)
      3'd0:    return 4'b0001 << a;
      3'd1:    return a[1] ? 4'b1100 : 4'b0011;
      default: return 4'b1111;
    endcase
  endfunction

  // Expected PPROT from HPROT: {instruction, non-secure, privileged}
  function automatic logic [2:0] exp_pprot(input logic [3:0] hprot);
    return {~hprot[0], 1'b0, hprot[1]};
  endfunction

  // Power-on contents of an APB slave word that has never been written.
  // This defines the peripheral model's reset value. The APB slave model and
  // the scoreboard's reference memory both use it, so reads of unwritten
  // locations still check the full read-data path.
  function automatic logic [31:0] slv_init_word(input int idx, input logic [31:0] waddr);
    return {4'hA, idx[3:0], waddr[23:0]} ^ 32'h0055_AA00;
  endfunction

  // Garbage the slave model returns on an errored read (must never be checked as data)
  localparam logic [31:0] ERR_RDATA = 32'hDEAD_BEEF;

endpackage
