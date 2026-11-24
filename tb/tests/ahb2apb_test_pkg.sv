// =============================================================================
// ahb2apb_test_pkg - all tests, plus the +TEST=<name> factory.
// =============================================================================
`timescale 1ns/1ps

package ahb2apb_test_pkg;
  import ahb2apb_cfg_pkg::*;
  import ahb2apb_pkg::*;

  `include "base_test.svh"
  `include "single_rw_test.svh"

  // Names accepted by +TEST=
  function automatic base_test create_test(string name, test_cfg cfg);
    case (name)
      "single_rw":      begin single_rw_test      t = new(cfg); return t; end
      default:          return null;
    endcase
  endfunction
endpackage
