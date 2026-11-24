// =============================================================================
// apb_if.sv - APB4 bus between the bridge (master) and the 4 slave models.
// Each slave i drives only its own slice: PRDATA[i], PREADY[i], PSLVERR[i].
//   slv_cb : reactive slave side (samples the request, drives the response)
//   mon_cb : passive
// =============================================================================
`timescale 1ns/1ps

interface apb_if (input logic PCLK, input logic PRESETn);
  import ahb2apb_cfg_pkg::NUM_SLV;

  logic [NUM_SLV-1:0]       PSEL;
  logic                     PENABLE;
  logic [31:0]              PADDR;
  logic                     PWRITE;
  logic [31:0]              PWDATA;
  logic [3:0]               PSTRB;
  logic [2:0]               PPROT;
  logic [NUM_SLV-1:0][31:0] PRDATA;
  logic [NUM_SLV-1:0]       PREADY;
  logic [NUM_SLV-1:0]       PSLVERR;

  clocking slv_cb @(posedge PCLK);
    default input #1step output #1;
    input  PSEL, PENABLE, PADDR, PWRITE, PWDATA, PSTRB, PPROT, PRESETn;
    output PRDATA, PREADY, PSLVERR;
  endclocking

  clocking mon_cb @(posedge PCLK);
    default input #1step;
    input PSEL, PENABLE, PADDR, PWRITE, PWDATA, PSTRB, PPROT, PRDATA, PREADY, PSLVERR, PRESETn;
  endclocking

  modport slave   (clocking slv_cb, input PCLK, input PRESETn);
  modport monitor (clocking mon_cb, input PCLK, input PRESETn);
  modport dut     (input PCLK, PRESETn, PRDATA, PREADY, PSLVERR,
                   output PSEL, PENABLE, PADDR, PWRITE, PWDATA, PSTRB, PPROT);
endinterface
