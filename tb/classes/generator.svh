// =============================================================================
// generator - produces directed or constrained-random ahb_txn objects and
// sends them to the driver through a (bounded) mailbox.
// =============================================================================
class generator;
  test_cfg              cfg;
  std::mailbox #(ahb_txn)    gen2drv;
  int unsigned          n_txns, n_beats, n_rand_fail, n_illegal;

  function new(test_cfg cfg, std::mailbox #(ahb_txn) gen2drv);
    this.cfg     = cfg;
    this.gen2drv = gen2drv;
  endfunction

  // Send one transaction (directed or random)
  task put(ahb_txn t);
    string why = t.check_legal();
    if (why != "") begin
      n_illegal++;
      $display("[%0t] GEN ERROR: illegal directed transaction (%s): %s", $time, why, t.convert2string());
      return;
    end
    if (cfg.verbose) $display("[%0t] GEN  %s", $time, t.convert2string());
    gen2drv.put(t);
    n_txns++;
    n_beats += t.beats;
  endtask

  // ---------------- directed helpers ----------------
  task single(logic [31:0] a, bit w, hsize_e s = WORD);
    put(ahb_txn::make(a, w, s, SINGLE));
  endtask

  task burst(hburst_e b, logic [31:0] a, bit w, hsize_e s = WORD, int unsigned n = 0);
    put(ahb_txn::make(a, w, s, b, n));
  endtask

  // Write a burst, then read the same beats back with an identical burst
  task burst_wr_rd(hburst_e b, logic [31:0] a, hsize_e s = WORD, int unsigned n = 0);
    burst(b, a, 1'b1, s, n);
    burst(b, a, 1'b0, s, n);
  endtask

  // ---------------- constrained random ----------------
  task random(int unsigned n);
    repeat (n) begin
      ahb_txn t;
      t = new();
      t.set_weights(cfg);
      if (!t.randomize()) begin
        n_rand_fail++;
        $display("[%0t] GEN ERROR: randomize() failed", $time);
        continue;
      end
      put(t);
    end
  endtask
endclass
