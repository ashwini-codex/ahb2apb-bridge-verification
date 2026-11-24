// =============================================================================
// test_cfg - every knob a test can turn. Tests set these in configure().
// =============================================================================
class test_cfg;
  string       test_name     = "single_rw";
  int unsigned seed          = 1;
  int unsigned num_txns      = 200;       // used by the random test(s); +NUM_TXNS=<n>
  int unsigned timeout_cycles= 2_000_000; // watchdog
  bit          verbose       = 0;         // +VERBOSE: print every beat / APB transfer

  // ---------------- constrained-random stimulus weights ----------------
  // target region of a transaction: S0, S1, S2, S3, unmapped-near (holes), unmapped-far
  int unsigned w_tgt[6]   = '{24, 24, 24, 23, 3, 2};
  // burst type weights in HBURST encoding order: SINGLE INCR WRAP4 INCR4 WRAP8 INCR8 WRAP16 INCR16
  int unsigned w_burst[8] = '{30, 10, 10, 10, 10, 10, 10, 10};
  int unsigned max_incr_beats = 16;       // length range for undefined-length INCR

  // ---------------- AHB driver behaviour ----------------
  int unsigned idle_max   = 2;            // random 0..idle_max IDLE cycles between transactions
  int unsigned busy_pct   = 0;            // % of burst beats preceded by BUSY cycles
  int unsigned busy_max   = 2;            // 1..busy_max BUSY cycles when inserted
  int unsigned cancel_pct = 100;          // % of ERRORs after which the master cancels the rest of the burst

  // ---------------- APB slave models ----------------
  int unsigned min_wait[ahb2apb_cfg_pkg::NUM_SLV] = '{0, 0, 0, 0};
  int unsigned max_wait[ahb2apb_cfg_pkg::NUM_SLV] = '{0, 0, 0, 0};
  int unsigned err_pct [ahb2apb_cfg_pkg::NUM_SLV] = '{0, 0, 0, 0};

  function void set_waits(int unsigned lo, int unsigned hi);
    foreach (min_wait[i]) begin min_wait[i] = lo; max_wait[i] = hi; end
  endfunction

  function void set_err_pct(int unsigned p);
    foreach (err_pct[i]) err_pct[i] = p;
  endfunction

  function void parse_plusargs();
    int unsigned v;
    void'($value$plusargs("TEST=%s", test_name));
    if ($value$plusargs("SEED=%d", v))      seed = v;
    if ($value$plusargs("NUM_TXNS=%d", v))  num_txns = v;
    if ($value$plusargs("TIMEOUT=%d", v))   timeout_cycles = v;
    if ($test$plusargs("VERBOSE"))          verbose = 1;
  endfunction

  function string convert2string();
    return $sformatf({"test=%s seed=%0d num_txns=%0d idle_max=%0d busy_pct=%0d cancel_pct=%0d ",
                      "waits=[%0d..%0d,%0d..%0d,%0d..%0d,%0d..%0d] err_pct=[%0d,%0d,%0d,%0d]"},
                     test_name, seed, num_txns, idle_max, busy_pct, cancel_pct,
                     min_wait[0], max_wait[0], min_wait[1], max_wait[1],
                     min_wait[2], max_wait[2], min_wait[3], max_wait[3],
                     err_pct[0], err_pct[1], err_pct[2], err_pct[3]);
  endfunction
endclass
