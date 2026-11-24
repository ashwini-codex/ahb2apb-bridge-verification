// =============================================================================
// ahb_monitor - passive monitor: observes the bus only through its clocking block,
// rebuilds transactions, sends them to the scoreboard and samples coverage.
// =============================================================================
// -----------------------------------------------------------------------------
// ahb_monitor: tracks the AHB address/data pipeline, one ahb_beat per beat.
// -----------------------------------------------------------------------------
class ahb_monitor;
  virtual ahb_if.monitor  vif;
  std::mailbox #(ahb_beat)     mb;
  coverage                cov;
  test_cfg                cfg;

  bit          dp_valid;      // a data phase is outstanding (read by env for reset coverage)
  ahb_beat     dp;
  bit          prev_busy;
  int unsigned n_beats, n_busy, n_err, n_reset_drop, n_err_one_cycle;

  function new(virtual ahb_if.monitor vif, std::mailbox #(ahb_beat) mb, coverage cov, test_cfg cfg);
    this.vif = vif; this.mb = mb; this.cov = cov; this.cfg = cfg;
  endfunction

  task run();
    forever begin
      bit completed;
      @(vif.mon_cb);
      if (!vif.mon_cb.HRESETn) begin
        if (dp_valid) n_reset_drop++;
        dp_valid  = 0;
        prev_busy = 0;
        continue;
      end

      // ---------------- data phase ----------------
      completed = 0;
      if (dp_valid) begin
        if (vif.mon_cb.HREADY) begin
          dp.resp   = vif.mon_cb.HRESP;
          dp.rdata  = vif.mon_cb.HRDATA;
          dp.wdata  = vif.mon_cb.HWDATA;
          dp.t_done = $time;
          if (dp.resp) begin
            n_err++;
            if (!dp.err_first) n_err_one_cycle++;   // also flagged by SVA
          end
          if (cfg.verbose) $display("[%0t] AHBMON %s", $time, dp.convert2string());
          cov.sample_ahb(dp);
          mb.put(dp);
          n_beats++;
          dp_valid  = 0;
          completed = 1;
        end else begin
          dp.waits++;
          if (vif.mon_cb.HRESP) dp.err_first = 1;
        end
      end

      // ---------------- address phase ----------------
      if (vif.mon_cb.HREADY && vif.mon_cb.HSEL) begin
        case (htrans_e'(vif.mon_cb.HTRANS))
          NONSEQ, SEQ: begin
            dp            = new();
            dp.addr       = vif.mon_cb.HADDR;
            dp.write      = vif.mon_cb.HWRITE;
            dp.size       = vif.mon_cb.HSIZE;
            dp.burst      = vif.mon_cb.HBURST;
            dp.prot       = vif.mon_cb.HPROT;
            dp.trans      = htrans_e'(vif.mon_cb.HTRANS);
            dp.b2b        = completed;
            dp.after_busy = prev_busy;
            dp.t_addr     = $time;
            dp_valid      = 1;
            prev_busy     = 0;
          end
          BUSY:    begin n_busy++; prev_busy = 1; end
          default: prev_busy = 0;
        endcase
      end
    end
  endtask
endclass
