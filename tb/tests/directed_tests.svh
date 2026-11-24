// =============================================================================
// Directed tests
// =============================================================================

// -----------------------------------------------------------------------------
// burst_all: every HBURST type x every HSIZE, write then read back, rotated
// across the 4 slaves. WRAP bursts start mid-window so the address really wraps.
// -----------------------------------------------------------------------------
class burst_all_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(0, 1);
    cfg.idle_max = 1;
  endfunction

  virtual task body();
    hburst_e bt[8] = '{SINGLE, INCR, WRAP4, INCR4, WRAP8, INCR8, WRAP16, INCR16};
    hsize_e  sz[3] = '{BYTE, HALF, WORD};
    int      n = 0;
    foreach (bt[b]) foreach (sz[s]) begin
      int unsigned nbytes = 1 << sz[s];
      int          slv    = n % NUM_SLV;
      // start one beat into a 64-byte window -> wrap bursts wrap, INCR bursts stay < 1KB
      logic [31:0] a      = base(slv) + 32'h100 + 32'(n) * 32'h40 + nbytes;
      e.gen.burst_wr_rd(bt[b], a, sz[s], (bt[b] == INCR) ? 5 : 0);
      n++;
    end
    // undefined-length INCR edge lengths: 1 beat and 16 beats; INCR16 ending exactly at a 1KB boundary
    e.gen.burst_wr_rd(INCR,   base(0) + 32'h800, WORD, 1);
    e.gen.burst_wr_rd(INCR,   base(1) + 32'h400, WORD, 16);
    e.gen.burst_wr_rd(INCR16, base(3) + 32'h3C0, WORD);
  endtask
endclass

// -----------------------------------------------------------------------------
// wait_states: same traffic with fixed 0, 1 and 5 PREADY wait states, then a
// mixed phase with a different wait profile per slave.
// -----------------------------------------------------------------------------
class wait_states_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.idle_max = 1;
  endfunction

  local task traffic(logic [31:0] off);
    for (int s = 0; s < NUM_SLV; s++) begin
      e.gen.single(base(s) + off, 1'b1);
      e.gen.single(base(s) + off, 1'b0);
      e.gen.burst_wr_rd(INCR4, base(s) + off + 32'h10);
      e.gen.burst_wr_rd(WRAP4, base(s) + off + 32'h24, HALF);
    end
  endtask

  virtual task body();
    int unsigned w[3] = '{0, 1, 5};
    foreach (w[i]) begin
      e.wait_idle();                 // reconfigure only between transfers
      cfg.set_waits(w[i], w[i]);
      $display("[%0t] wait_states: phase with %0d wait state(s)", $time, w[i]);
      traffic(32'h200 + 32'(i) * 32'h40);
    end
    e.wait_idle();
    cfg.min_wait = '{0, 1, 5, 0};
    cfg.max_wait = '{0, 1, 5, 7};
    $display("[%0t] wait_states: mixed phase S0=0 S1=1 S2=5 S3=0..7", $time);
    traffic(32'h300);
  endtask
endclass

// -----------------------------------------------------------------------------
// slave_error: PSLVERR -> two-cycle AHB ERROR, for reads and writes, with and
// without wait states, on a single and mid-burst (master cancels / continues).
// Also checks that an errored write did not change the slave memory.
// -----------------------------------------------------------------------------
class slave_error_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(0, 0);
    cfg.idle_max = 1;
  endfunction

  virtual task body();
    // 1) every access to S1 errors
    cfg.err_pct = '{0, 100, 0, 0};
    e.gen.single(base(1) + 32'h40, 1'b1);
    e.gen.single(base(1) + 32'h40, 1'b0);
    e.gen.single(base(1) + 32'h44, 1'b1, BYTE);
    e.wait_idle();
    cfg.err_pct = '{0, 0, 0, 0};
    e.gen.single(base(1) + 32'h40, 1'b0);   // must still read the reset value: errored write ignored
    e.gen.single(base(1) + 32'h44, 1'b0);

    // 2) error on the 3rd beat of a burst, master cancels the rest (cancel_pct=100)
    e.wait_idle();
    e.slv[2].err_addrs.push_back(base(2) + 32'h88);
    cfg.cancel_pct = 100;
    e.gen.burst(INCR4, base(2) + 32'h80, 1'b1);
    e.gen.burst(INCR4, base(2) + 32'h80, 1'b0);
    // 3) same, but the master continues the burst after the ERROR (cancel_pct=0)
    e.wait_idle();
    cfg.cancel_pct = 0;
    e.gen.burst(INCR4, base(2) + 32'h80, 1'b1);
    e.gen.burst(WRAP8, base(2) + 32'h84, 1'b0);

    // 4) PSLVERR together with wait states
    e.wait_idle();
    e.slv[2].err_addrs.delete();
    cfg.min_wait = '{0, 0, 0, 3};
    cfg.max_wait = '{0, 0, 0, 3};
    e.slv[3].err_addrs.push_back(base(3) + 32'h10);
    e.gen.single(base(3) + 32'h10, 1'b0);
    e.gen.single(base(3) + 32'h10, 1'b1);
    e.gen.single(base(3) + 32'h14, 1'b1);   // neighbour still works
    e.gen.single(base(3) + 32'h14, 1'b0);
    // 5) back-to-back errors, then recovery
    e.wait_idle();
    cfg.set_waits(0, 0);
    cfg.idle_max = 0;
    cfg.err_pct  = '{100, 0, 0, 0};
    repeat (3) e.gen.single(base(0) + 32'h20, 1'b0);
    e.wait_idle();
    cfg.err_pct  = '{0, 0, 0, 0};
    e.gen.single(base(0) + 32'h20, 1'b1);
    e.gen.single(base(0) + 32'h20, 1'b0);
  endtask
endclass

// -----------------------------------------------------------------------------
// decode_error: addresses just outside every region edge, holes, far addresses
// and illegal HSIZE give a two-cycle ERROR with no APB transfer. Boundary words
// just inside each region must still work.
// -----------------------------------------------------------------------------
class decode_error_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(0, 1);
    cfg.idle_max = 1;
  endfunction

  virtual task body();
    logic [31:0] miss[] = '{32'h3FFF_FFFC,   // just below S0
                            32'h4000_2800,   // just above S2 (2KB) -> start of hole
                            32'h4000_2FFC,   // inside hole (would hit if S2 were decoded as 4KB)
                            32'h4000_3FFC,   // just below S3
                            32'h4000_6000,   // just above S3
                            32'h0000_0000, 32'h8000_0000, 32'hFFFF_FFFC};
    logic [31:0] hit[]  = '{32'h4000_0000, 32'h4000_0FFC, 32'h4000_1000, 32'h4000_1FFC,
                            32'h4000_2000, 32'h4000_27FC, 32'h4000_4000, 32'h4000_5FFC};
    foreach (miss[i]) begin
      e.gen.single(miss[i], 1'b1);
      e.gen.single(miss[i], 1'b0);
      e.gen.single(miss[i] | 32'h1, 1'b0, BYTE);
    end
    foreach (hit[i]) begin
      e.gen.single(hit[i], 1'b1);
      e.gen.single(hit[i], 1'b0);
    end
    // bursts into a hole: master cancels after the first ERROR, then continues through every beat
    cfg.cancel_pct = 100;
    e.gen.burst(INCR4, 32'h4000_2C00, 1'b1);
    e.gen.burst(WRAP4, 32'h4000_2C04, 1'b0);
    e.wait_idle();
    cfg.cancel_pct = 0;
    e.gen.burst(INCR8, 32'h4000_3000, 1'b0);
    e.gen.burst(INCR,  32'h4000_7000, 1'b1, WORD, 3);
    // HSIZE wider than the 32-bit bus to a mapped address -> ERROR, no APB
    e.gen.put(ahb_txn::make(base(0) + 32'h100, 1'b1, DWORD, SINGLE));
    e.gen.put(ahb_txn::make(base(1) + 32'h100, 1'b0, DWORD, SINGLE));
    // recovery
    e.gen.single(base(0) + 32'h100, 1'b0);
  endtask
endclass

// -----------------------------------------------------------------------------
// back_to_back: no IDLE cycles between transfers. Read-after-write to the same
// address, write/read ping-pong across slaves, streams of reads and writes.
// -----------------------------------------------------------------------------
class back_to_back_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(0, 0);
    cfg.idle_max = 0;
  endfunction

  virtual task body();
    for (int i = 0; i < 8; i++) begin              // RAW to the same address
      e.gen.single(base(i % 4) + 32'h500 + 32'(4 * i), 1'b1);
      e.gen.single(base(i % 4) + 32'h500 + 32'(4 * i), 1'b0);
    end
    for (int i = 0; i < 8; i++)                    // write stream across slaves
      e.gen.single(base(i % 4) + 32'h600 + 32'(4 * i), 1'b1);
    for (int i = 0; i < 8; i++)                    // read stream across slaves
      e.gen.single(base(i % 4) + 32'h600 + 32'(4 * i), 1'b0);
    // back-to-back bursts: write burst immediately followed by read burst
    e.gen.burst_wr_rd(INCR8, base(1) + 32'h700);
    e.gen.burst_wr_rd(WRAP8, base(2) + 32'h724, HALF);
    // same traffic with wait states
    e.wait_idle();
    cfg.set_waits(1, 3);
    for (int i = 0; i < 8; i++) begin
      e.gen.single(base(3) + 32'h780 + 32'(4 * i), 1'b1);
      e.gen.single(base(3) + 32'h780 + 32'(4 * i), 1'b0);
    end
  endtask
endclass

// -----------------------------------------------------------------------------
// busy_burst: BUSY cycles inserted before (almost) every non-first beat.
// -----------------------------------------------------------------------------
class busy_burst_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(0, 2);
    cfg.busy_pct = 80;
    cfg.busy_max = 3;
    cfg.idle_max = 1;
  endfunction

  virtual task body();
    hburst_e bt[7] = '{INCR, WRAP4, INCR4, WRAP8, INCR8, WRAP16, INCR16};
    foreach (bt[i]) begin
      // offsets stay below 0x800 so every slave (S2 is only 2KB) is hit
      e.gen.burst_wr_rd(bt[i], base(i % 4) + 32'h400 + 32'(i) * 32'h40, WORD, 6);
      e.gen.burst_wr_rd(bt[i], base((i + 1) % 4) + 32'h600 + 32'(i) * 32'h40 + 2, HALF, 6);
    end
    // BUSY combined with an ERROR in the middle of the burst
    e.wait_idle();
    cfg.cancel_pct = 100;
    e.slv[0].err_addrs.push_back(base(0) + 32'hB08);
    e.gen.burst(INCR8, base(0) + 32'hB00, 1'b1);
  endtask
endclass

// -----------------------------------------------------------------------------
// reset_mid: assert HRESETn in the middle of (a) an APB ACCESS wait state,
// (b) an AHB ERROR response, (c) a write data phase, (d) idle; check that the bridge
// recovers and works normally afterwards.
// -----------------------------------------------------------------------------
class reset_mid_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(4, 4);
    cfg.idle_max = 0;
  endfunction

  local task post_reset_check();
    for (int s = 0; s < NUM_SLV; s++) begin
      e.gen.single(base(s) + 32'h40, 1'b0);      // reset contents again
      e.gen.single(base(s) + 32'h40, 1'b1);
      e.gen.single(base(s) + 32'h40, 1'b0);
    end
    e.wait_idle();
  endtask

  virtual task body();
    // (a) reset while an APB transfer is waiting for PREADY
    fork
      begin
        e.gen.burst(INCR16, base(1) + 32'h100, 1'b1);
        e.gen.burst(INCR16, base(1) + 32'h100, 1'b0);
      end
    join_none
    do e.wait_cycles(1); while (!(e.apb_mon.in_xfer && e.apb_mon.cur.waits >= 2 && e.drv.n_completed >= 3));
    $display("[%0t] reset_mid: asserting reset during APB ACCESS wait state", $time);
    e.apply_reset(3);
    wait fork;
    e.wait_idle();
    post_reset_check();

    // (b) reset during the first cycle of an ERROR response
    cfg.set_waits(0, 0);
    fork e.gen.single(32'h4000_3000, 1'b0); join_none
    do e.wait_cycles(1); while (!(e.ahb_vif.HRESP && !e.ahb_vif.HREADYOUT));
    $display("[%0t] reset_mid: asserting reset during ERROR response", $time);
    e.apply_reset(2);
    wait fork;
    e.wait_idle();
    post_reset_check();

    // (c) reset in a write data phase before APB SETUP (bridge latching HWDATA)
    fork e.gen.single(base(2) + 32'h44, 1'b1); join_none
    do e.wait_cycles(1); while (!(e.ahb_mon.dp_valid && e.ahb_vif.HWRITE == 1'b1 && e.apb_vif.PSEL == '0));
    $display("[%0t] reset_mid: asserting reset in write data phase", $time);
    e.apply_reset(2);
    wait fork;
    e.wait_idle();
    post_reset_check();

    // (d) reset while the bus is idle
    e.wait_cycles(5);
    $display("[%0t] reset_mid: asserting reset while idle", $time);
    e.apply_reset(2);
    e.wait_cycles(2);
    post_reset_check();
  endtask
endclass
