// =============================================================================
// env - builds and connects every component, and runs the run/report phases.
//
//   generator --gen2drv--> ahb_driver ==AHB==> DUT ==APB==> apb_slave_model x4
//                               ahb_monitor --ahb_mb--> scoreboard <--apb_mb-- apb_monitor
//                                     \------------> coverage <--------------/
// =============================================================================
class env;
  test_cfg               cfg;
  virtual ahb_if         ahb_vif;
  virtual apb_if         apb_vif;
  virtual rst_if         rst_vif;

  std::mailbox #(ahb_txn)     gen2drv;
  std::mailbox #(ahb_beat)    ahb_mb;
  std::mailbox #(apb_txn)     apb_mb;

  generator              gen;
  ahb_driver             drv;
  apb_slave_model        slv[NUM_SLV];
  ahb_monitor            ahb_mon;
  apb_monitor            apb_mon;
  scoreboard             sb;
  coverage               cov;

  // ---------------- build phase ----------------
  function new(test_cfg cfg, virtual ahb_if ahb_vif, virtual apb_if apb_vif, virtual rst_if rst_vif);
    this.cfg     = cfg;
    this.ahb_vif = ahb_vif;
    this.apb_vif = apb_vif;
    this.rst_vif = rst_vif;
    gen2drv = new(4);   // bounded: generator runs at most 4 transactions ahead
    ahb_mb  = new();
    apb_mb  = new();
    cov     = new();
    gen     = new(cfg, gen2drv);
    drv     = new(ahb_vif, gen2drv, cfg);
    foreach (slv[i]) slv[i] = new(apb_vif, i, cfg);
    ahb_mon = new(ahb_vif, ahb_mb, cov, cfg);
    apb_mon = new(apb_vif, apb_mb, cov, cfg);
    sb      = new(ahb_mb, apb_mb, ahb_vif, cfg);
  endfunction

  // ---------------- run phase ----------------
  task run();
    fork
      drv.run();
      ahb_mon.run();
      apb_mon.run();
      watch_reset();
    join_none
    foreach (slv[i]) begin
      automatic int k = i;
      fork slv[k].run(); join_none
    end
    sb.run();
  endtask

  // Sample reset coverage: what was the bridge doing when reset hit?
  // (The power-on reset is not sampled.)
  local task watch_reset();
    @(posedge ahb_vif.HRESETn);
    forever begin
      @(negedge ahb_vif.HRESETn);
      cov.sample_reset(apb_mon.in_xfer ? 2 : (ahb_mon.dp_valid ? 1 : 0));
    end
  endtask

  task apply_reset(int unsigned cycles = 3);
    rst_vif.pulse(cycles);
  endtask

  // Wait until all generated stimulus has been driven and checked
  task wait_idle();
    do @(posedge ahb_vif.HCLK); while (!(drv.idle() && sb.drained()));
    repeat (4) @(posedge ahb_vif.HCLK);
  endtask

  task wait_cycles(int unsigned n);
    repeat (n) @(posedge ahb_vif.HCLK);
  endtask

  // ---------------- report phase ----------------
  function bit report(bit timed_out);
    bit pass = 1;
    int unsigned slv_proto = 0;
    string why = "";

    foreach (slv[i]) slv_proto += slv[i].n_proto_err;

    sb.report();
    cov.report();
    ahb2apb_sva_pkg::report();

    $display("---------------------------------------------------------------");
    $display(" STIMULUS / ACCOUNTING");
    $display("---------------------------------------------------------------");
    $display("  generator : txns %0d  beats %0d  (rand fail %0d, illegal %0d)",
             gen.n_txns, gen.n_beats, gen.n_rand_fail, gen.n_illegal);
    $display("  driver    : accepted %0d completed %0d cancelled-after-ERROR %0d  BUSY %0d  IDLE %0d",
             drv.n_accepted, drv.n_completed, drv.n_cancelled, drv.n_busy, drv.n_idle);
    $display("              resets %0d (in-flight beats lost %0d, unissued beats dropped %0d)",
             drv.n_resets, drv.n_reset_inflight, drv.n_reset_unissued);
    $display("  ahb_mon   : beats %0d  ERROR %0d  BUSY %0d  apb_mon: transfers %0d  PSLVERR %0d",
             ahb_mon.n_beats, ahb_mon.n_err, ahb_mon.n_busy, apb_mon.n_xfers, apb_mon.n_err);
    foreach (slv[i])
      $display("  slave S%0d  : transfers %0d (rd %0d, wr %0d, PSLVERR %0d) protocol errors %0d",
               i, slv[i].n_xfers, slv[i].n_reads, slv[i].n_writes, slv[i].n_errors, slv[i].n_proto_err);

    // ---------------- pass/fail criteria ----------------
    if (timed_out)                         begin pass = 0; why = {why, " timeout"}; end
    if (sb.n_fail != 0)                    begin pass = 0; why = {why, " scoreboard"}; end
    if (ahb2apb_sva_pkg::n_fail != 0)      begin pass = 0; why = {why, " assertions"}; end
    if (slv_proto != 0)                    begin pass = 0; why = {why, " apb_protocol"}; end
    if (gen.n_rand_fail || gen.n_illegal)  begin pass = 0; why = {why, " generator"}; end
    if (sb.n_checked == 0)                 begin pass = 0; why = {why, " nothing_checked"}; end
    if (sb.apb_q.size() != 0)              begin pass = 0; why = {why, " unmatched_apb"}; end
    // every generated beat is accounted for
    if (gen.n_beats != drv.n_accepted + drv.n_cancelled + drv.n_reset_unissued)
                                           begin pass = 0; why = {why, " beat_accounting"}; end
    if (drv.n_accepted != drv.n_completed + drv.n_reset_inflight)
                                           begin pass = 0; why = {why, " inflight_accounting"}; end
    if (ahb_mon.n_beats != drv.n_completed) begin pass = 0; why = {why, " monitor_vs_driver"}; end
    if (sb.n_checked != ahb_mon.n_beats)    begin pass = 0; why = {why, " unchecked_beats"}; end
    if (ahb_mon.n_err_one_cycle != 0)       begin pass = 0; why = {why, " one_cycle_error"}; end

    $display("===============================================================");
    $display(" RESULT: test=%s seed=%0d status=%s checks=%0d sb_fail=%0d sva_fail=%0d cov_ahb=%0.2f cov_apb=%0.2f%s",
             cfg.test_name, cfg.seed, pass ? "PASS" : "FAIL", sb.n_checked, sb.n_fail,
             ahb2apb_sva_pkg::n_fail, cov.cg_ahb.get_coverage(), cov.cg_apb.get_coverage(),
             pass ? "" : {" reasons:", why});
    $display("===============================================================");
    return pass;
  endfunction
endclass
