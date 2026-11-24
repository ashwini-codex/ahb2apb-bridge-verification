// =============================================================================
// scoreboard - reference model + checker.
//
// For every completed AHB beat (from ahb_monitor) the reference model predicts:
//   * whether an APB transfer must happen (mapped address and legal size), and
//     if so exactly which PSEL, PADDR, PWRITE, PWDATA, PSTRB and PPROT
//   * the AHB response: ERROR for unmapped/illegal size, otherwise ERROR iff
//     the APB slave returned PSLVERR
//   * the read data: from a reference memory updated by every successful write
// and compares the prediction against the APB transfer the apb_monitor saw.
//
// Ordering: the bridge handles one beat at a time and its AHB response is
// registered, so a beat's APB transfer always completes before the AHB data
// phase. When an AHB beat arrives, the APB queue must hold exactly 0 or 1
// transfers for it.
// =============================================================================
class scoreboard;
  std::mailbox #(ahb_beat)     ahb_mb;
  std::mailbox #(apb_txn)      apb_mb;
  virtual ahb_if.monitor  vif;
  test_cfg                cfg;

  apb_txn                 apb_q[$];
  logic [31:0]            ref_mem[logic [31:0]];   // keyed by word address

  int unsigned n_beats, n_checked, n_pass, n_fail, n_mismatch_fields;
  int unsigned n_okay, n_err_decode, n_err_slverr, n_err_size, n_reads_checked, n_writes;
  int unsigned n_flushed_apb, n_resets;
  local int unsigned max_print = 20;

  function new(std::mailbox #(ahb_beat) ahb_mb, std::mailbox #(apb_txn) apb_mb, virtual ahb_if.monitor vif, test_cfg cfg);
    this.ahb_mb = ahb_mb; this.apb_mb = apb_mb; this.vif = vif; this.cfg = cfg;
  endfunction

  local function logic [31:0] ref_read(logic [31:0] a);
    logic [31:0] wa = {a[31:2], 2'b00};
    return ref_mem.exists(wa) ? ref_mem[wa] : slv_init_word(decode_slave(wa), wa);
  endfunction

  local function void ref_write(logic [31:0] a, logic [31:0] d, logic [3:0] strb);
    logic [31:0] wa = {a[31:2], 2'b00};
    logic [31:0] w  = ref_read(wa);
    for (int b = 0; b < 4; b++) if (strb[b]) w[8*b +: 8] = d[8*b +: 8];
    ref_mem[wa] = w;
  endfunction

  // Report one field mismatch: time, address, expected vs actual
  local function bit chk(string what, ahb_beat b, logic [31:0] exp, logic [31:0] act);
    if (exp === act) return 1;
    n_mismatch_fields++;
    if (n_mismatch_fields <= max_print)
      $display("[%0t] SB MISMATCH  %-8s addr=0x%08h %s : expected=0x%08h actual=0x%08h",
               $time, what, b.addr, b.write ? "WR" : "RD", exp, act);
    return 0;
  endfunction

  local function void check_beat(ahb_beat b);
    int     slv      = decode_slave(b.addr);
    bit     bad_size = (b.size > 3'd2);
    bit     ok       = 1;
    apb_txn p;

    n_beats++;
    n_checked++;

    if (slv < 0 || bad_size) begin
      // ---- no APB transfer allowed; AHB must see ERROR ----
      if (apb_q.size() != 0) begin
        ok = 0;
        n_mismatch_fields++;
        if (n_mismatch_fields <= max_print)
          $display("[%0t] SB MISMATCH  APB transfer started for %s address 0x%08h: %s",
                   $time, bad_size ? "illegal-size" : "UNMAPPED", b.addr, apb_q[0].convert2string());
        apb_q.delete();
      end
      ok &= chk("HRESP", b, ERROR, b.resp);
      if (bad_size) n_err_size++; else n_err_decode++;
    end else begin
      // ---- exactly one APB transfer expected ----
      if (apb_q.size() == 0) begin
        ok = 0;
        n_mismatch_fields++;
        if (n_mismatch_fields <= max_print)
          $display("[%0t] SB MISMATCH  no APB transfer for mapped addr=0x%08h (expected PSEL[%0d])",
                   $time, b.addr, slv);
      end else begin
        if (apb_q.size() > 1) begin
          ok = 0;
          n_mismatch_fields++;
          if (n_mismatch_fields <= max_print)
            $display("[%0t] SB MISMATCH  %0d APB transfers queued for one AHB beat addr=0x%08h",
                     $time, apb_q.size(), b.addr);
        end
        p   = apb_q.pop_front();
        ok &= chk("PSEL",   b, 32'(1 << slv),                       32'(p.psel));
        ok &= chk("PADDR",  b, b.addr,                              p.paddr);
        ok &= chk("PWRITE", b, 32'(b.write),                        32'(p.pwrite));
        ok &= chk("PSTRB",  b, 32'(exp_strobe(b.write, b.size, b.addr[1:0])), 32'(p.pstrb));
        ok &= chk("PPROT",  b, 32'(exp_pprot(b.prot)),              32'(p.pprot));
        if (b.write) ok &= chk("PWDATA", b, b.wdata, p.pwdata);
        if (p.no_setup) begin
          ok = 0;
          n_mismatch_fields++;
          $display("[%0t] SB MISMATCH  APB transfer for addr=0x%08h had no SETUP phase", $time, b.addr);
        end
        // AHB response must reflect PSLVERR
        ok &= chk("HRESP", b, 32'(p.pslverr), 32'(b.resp));
        if (p.pslverr) n_err_slverr++;
        else begin
          n_okay++;
          if (b.write) begin
            ref_write(b.addr, b.wdata, exp_strobe(1'b1, b.size, b.addr[1:0]));
            n_writes++;
          end else begin
            ok &= chk("HRDATA", b, ref_read(b.addr), b.rdata);   // end-to-end vs reference memory
            ok &= chk("HRD/PRD", b, p.prdata, b.rdata);          // bridge passes PRDATA unchanged
            n_reads_checked++;
          end
        end
      end
    end

    if (ok) n_pass++;
    else    n_fail++;
  endfunction

  local task collect_apb();
    apb_txn t;
    forever begin
      apb_mb.get(t);
      apb_q.push_back(t);
    end
  endtask

  local task collect_ahb();
    ahb_beat b;
    forever begin
      ahb_mb.get(b);
      check_beat(b);
    end
  endtask

  // On reset: in-flight work is discarded and the reference memory is reset,
  // just as the APB peripherals are.
  local task watch_reset();
    forever begin
      @(negedge vif.HRESETn);
      n_resets++;
      n_flushed_apb += apb_q.size();
      apb_q.delete();
      ref_mem.delete();
    end
  endtask

  task run();
    fork
      collect_apb();
      collect_ahb();
      watch_reset();
    join_none
  endtask

  function bit drained();
    return ahb_mb.num() == 0 && apb_mb.num() == 0;
  endfunction

  function void report();
    $display("---------------------------------------------------------------");
    $display(" SCOREBOARD");
    $display("---------------------------------------------------------------");
    $display("  AHB beats checked   : %0d   (pass %0d, fail %0d, field mismatches %0d)",
             n_checked, n_pass, n_fail, n_mismatch_fields);
    $display("  OKAY                : %0d   (writes %0d, reads data-checked %0d)", n_okay, n_writes, n_reads_checked);
    $display("  ERROR decode/slverr/size : %0d / %0d / %0d", n_err_decode, n_err_slverr, n_err_size);
    $display("  APB left unmatched  : %0d   flushed by reset: %0d   resets (incl. power-on): %0d",
             apb_q.size(), n_flushed_apb, n_resets);
  endfunction
endclass
