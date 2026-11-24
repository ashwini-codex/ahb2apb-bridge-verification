// =============================================================================
// ahb_if.sv - AHB-Lite bus between the TB master (driver) and the bridge.
//   drv_cb : master side, drives the address/control and write data, samples the response
//   mon_cb : passive, samples everything
// Inputs are sampled #1step before the clock edge, and outputs are driven 1ns
// after it, so the TB never races the DUT.
// =============================================================================
`timescale 1ns/1ps

interface ahb_if (input logic HCLK, input logic HRESETn);
  logic        HSEL;
  logic [31:0] HADDR;
  logic [1:0]  HTRANS;
  logic        HWRITE;
  logic [2:0]  HSIZE;
  logic [2:0]  HBURST;
  logic [3:0]  HPROT;
  logic [31:0] HWDATA;
  logic        HREADY;      // global HREADY seen by master and slave
  logic        HREADYOUT;   // bridge's ready output
  logic        HRESP;
  logic [31:0] HRDATA;

  clocking drv_cb @(posedge HCLK);
    default input #1step output #1;
    output HSEL, HADDR, HTRANS, HWRITE, HSIZE, HBURST, HPROT, HWDATA;
    input  HREADY, HRESP, HRDATA, HRESETn;
  endclocking

  clocking mon_cb @(posedge HCLK);
    default input #1step;
    input HSEL, HADDR, HTRANS, HWRITE, HSIZE, HBURST, HPROT, HWDATA,
          HREADY, HREADYOUT, HRESP, HRDATA, HRESETn;
  endclocking

  modport driver  (clocking drv_cb, input HCLK, input HRESETn);
  modport monitor (clocking mon_cb, input HCLK, input HRESETn);
  modport dut     (input HCLK, HRESETn, HSEL, HADDR, HTRANS, HWRITE, HSIZE, HBURST, HPROT, HWDATA, HREADY,
                   output HREADYOUT, HRESP, HRDATA);
endinterface
