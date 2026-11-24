// =============================================================================
// ahb2apb_sva_pkg - failure bookkeeping for the bound assertions.
// Each assertion's fail action calls fail(<label>). This keeps the simulation
// running, so a run reports every failing property instead of stopping at the
// first (Verilator's default $error action is $stop). The TB reads n_fail at
// the end to decide PASS/FAIL.
// =============================================================================
`timescale 1ns/1ps

package ahb2apb_sva_pkg;
  int unsigned n_fail = 0;
  int unsigned fails_by_name[string];
  int unsigned max_print_per_prop = 3;

  function automatic void fail(string name);
    n_fail++;
    if (fails_by_name.exists(name)) fails_by_name[name]++;
    else                            fails_by_name[name] = 1;
    if (fails_by_name[name] <= max_print_per_prop)
      $display("[%0t] SVA FAIL: %s", $time, name);
  endfunction

  function automatic void report();
    $display("---------------------------------------------------------------");
    $display(" ASSERTIONS: %0d failure(s)", n_fail);
    $display("---------------------------------------------------------------");
    foreach (fails_by_name[n])
      $display("  %-32s failed %0d time(s)", n, fails_by_name[n]);
  endfunction
endpackage
