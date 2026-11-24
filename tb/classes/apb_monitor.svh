// =============================================================================
// apb_monitor - passive monitor: observes the bus only through its clocking block,
// rebuilds transactions, sends them to the scoreboard and samples coverage.
// =============================================================================
// -----------------------------------------------------------------------------
// apb_monitor: one apb_txn per completed APB transfer (ACCESS with PREADY).
// -----------------------------------------------------------------------------
class apb_monitor;
  virtual apb_if.monitor  vif;
  std::mailbox #(apb_txn)      mb;
  coverage                cov;
  test_cfg                cfg;

  bit          in_xfer;      // read by env for reset coverage
  apb_txn      cur;
  int unsigned n_xfers, n_err, n_reset_drop;

  function new(virtual apb_if.monitor vif, std::mailbox #(apb_txn) mb, coverage cov, test_cfg cfg);
    this.vif = vif; this.mb = mb; this.cov = cov; this.cfg = cfg;
  endfunction

  local function int lowest_sel(logic [NUM_SLV-1:0] s);
    for (int i = 0; i < NUM_SLV; i++) if (s[i]) return i;
    return 0;
  endfunction

  task run();
    forever begin
      int i;
      @(vif.mon_cb);
      if (!vif.mon_cb.PRESETn) begin
        if (in_xfer) n_reset_drop++;
        in_xfer = 0;
        continue;
      end
      if (vif.mon_cb.PSEL != '0 && !vif.mon_cb.PENABLE) begin
        // SETUP
        cur         = new();
        cur.psel    = vif.mon_cb.PSEL;
        cur.t_setup = $time;
        in_xfer     = 1;
      end else if (vif.mon_cb.PSEL != '0 && vif.mon_cb.PENABLE) begin
        // ACCESS
        if (!in_xfer) begin
          cur          = new();
          cur.psel     = vif.mon_cb.PSEL;
          cur.no_setup = 1;
          cur.t_setup  = $time;
          in_xfer      = 1;
        end
        i = lowest_sel(vif.mon_cb.PSEL);
        if (vif.mon_cb.PREADY[i]) begin
          cur.psel    = vif.mon_cb.PSEL;
          cur.slv     = i;
          cur.paddr   = vif.mon_cb.PADDR;
          cur.pwrite  = vif.mon_cb.PWRITE;
          cur.pwdata  = vif.mon_cb.PWDATA;
          cur.pstrb   = vif.mon_cb.PSTRB;
          cur.pprot   = vif.mon_cb.PPROT;
          cur.prdata  = vif.mon_cb.PRDATA[i];
          cur.pslverr = vif.mon_cb.PSLVERR[i];
          cur.t_done  = $time;
          if (cur.pslverr) n_err++;
          if (cfg.verbose) $display("[%0t] APBMON %s", $time, cur.convert2string());
          cov.sample_apb(cur);
          mb.put(cur);
          n_xfers++;
          in_xfer = 0;
        end else begin
          cur.waits++;
        end
      end else begin
        in_xfer = 0;
      end
    end
  endtask
endclass
