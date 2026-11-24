// =============================================================================
// ahb2apb_test_pkg - all tests, plus the +TEST=<name> factory.
// =============================================================================
`timescale 1ns/1ps

package ahb2apb_test_pkg;
  import ahb2apb_cfg_pkg::*;
  import ahb2apb_pkg::*;

  `include "base_test.svh"
  `include "single_rw_test.svh"
  `include "directed_tests.svh"
  `include "random_tests.svh"

  // Names accepted by +TEST= (the regression list lives in scripts/regress.py)
  function automatic base_test create_test(string name, test_cfg cfg);
    case (name)
      "single_rw":      begin single_rw_test      t = new(cfg); return t; end
      "burst_all":      begin burst_all_test      t = new(cfg); return t; end
      "wait_states":    begin wait_states_test    t = new(cfg); return t; end
      "slave_error":    begin slave_error_test    t = new(cfg); return t; end
      "decode_error":   begin decode_error_test   t = new(cfg); return t; end
      "back_to_back":   begin back_to_back_test   t = new(cfg); return t; end
      "busy_burst":     begin busy_burst_test     t = new(cfg); return t; end
      "reset_mid":      begin reset_mid_test      t = new(cfg); return t; end
      "random_regress": begin random_regress_test t = new(cfg); return t; end
      "random_stress":  begin random_stress_test  t = new(cfg); return t; end
      default:          return null;
    endcase
  endfunction
endpackage
