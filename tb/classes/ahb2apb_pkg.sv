// =============================================================================
// ahb2apb_pkg - class-based testbench (UVM-style structure, plain SystemVerilog)
// =============================================================================
`timescale 1ns/1ps

package ahb2apb_pkg;
  import ahb2apb_cfg_pkg::*;

  `include "test_cfg.svh"
  `include "ahb_txn.svh"
  `include "obs_items.svh"
  `include "coverage.svh"
  `include "generator.svh"
  `include "ahb_driver.svh"
  `include "apb_slave_model.svh"
  `include "ahb_monitor.svh"
  `include "apb_monitor.svh"
  `include "scoreboard.svh"
  `include "env.svh"
endpackage
