// =============================================================================
// Constrained-random tests
// =============================================================================

// -----------------------------------------------------------------------------
// random_regress: long constrained-random run. Random burst types/sizes/
// addresses (in-map and out-of-map), random 0..5 wait states per slave,
// 5% random PSLVERR, random BUSY and IDLE insertion, random cancel-on-error.
// Length: +NUM_TXNS=<n> (default 2000).
// -----------------------------------------------------------------------------
class random_regress_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    if (!$test$plusargs("NUM_TXNS")) cfg.num_txns = 2000;
    cfg.set_waits(0, 5);
    cfg.set_err_pct(5);
    cfg.busy_pct   = 15;
    cfg.busy_max   = 2;
    cfg.idle_max   = 3;
    cfg.cancel_pct = 50;
  endfunction

  virtual task body();
    e.gen.random(cfg.num_txns);
  endtask
endclass

// -----------------------------------------------------------------------------
// random_stress: maximum throughput, back-to-back random traffic with no wait
// states, no IDLE gaps and no errors injected by slaves (decode errors still
// occur from out-of-map addresses).
// -----------------------------------------------------------------------------
class random_stress_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    if (!$test$plusargs("NUM_TXNS")) cfg.num_txns = 1000;
    cfg.set_waits(0, 0);
    cfg.set_err_pct(0);
    cfg.idle_max = 0;
    cfg.busy_pct = 0;
  endfunction

  virtual task body();
    e.gen.random(cfg.num_txns);
  endtask
endclass
