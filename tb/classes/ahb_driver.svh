// =============================================================================
// ahb_driver - AHB-Lite master BFM.
//
// Pipelining: in every bus cycle the driver puts the address phase of beat k
// on the bus, together with HWDATA for beat k-1 (whose address phase has
// already been accepted). It then waits for an edge where HREADY is high. At
// that edge beat k-1's data phase completes and beat k's address phase is
// accepted [AHB-Lite: Basic transfers].
//
// Rules followed:
//   * address/control are changed only after an edge with HREADY high, so they
//     are stable through wait states [AHB-Lite: Waited transfers]
//   * HWDATA is held for the whole (possibly stalled) data phase [AHB-Lite: Basic transfers]
//   * BUSY cycles between burst beats carry the address of the next beat [AHB-Lite: Transfer types]
//   * on the first ERROR cycle, the remaining beats of the burst may be
//     cancelled by driving IDLE [AHB-Lite: Error response]
// =============================================================================
class ahb_driver;
  virtual ahb_if.driver  vif;
  std::mailbox #(ahb_txn)     gen2drv;
  test_cfg               cfg;

  // pending data phase (beat whose address phase was accepted)
  local bit              dp_valid;
  local bit              dp_write;
  local logic [31:0]     dp_wdata;
  local ahb_txn          dp_txn;
  local bit              cancel_burst;
  local bit              reset_hit;
  local logic [31:0]     last_addr;
  bit                    in_txn;

  // statistics / accounting
  int unsigned n_txns, n_accepted, n_completed, n_cancelled, n_err_resp;
  int unsigned n_busy, n_idle, n_reset_inflight, n_reset_unissued, n_resets;

  function new(virtual ahb_if.driver vif, std::mailbox #(ahb_txn) gen2drv, test_cfg cfg);
    this.vif     = vif;
    this.gen2drv = gen2drv;
    this.cfg     = cfg;
  endfunction

  // True when there is nothing left to drive and no data phase is outstanding
  function bit idle();
    return !in_txn && !dp_valid && gen2drv.num() == 0;
  endfunction

  local task drive_reset_values();
    vif.drv_cb.HSEL   <= 1'b0;
    vif.drv_cb.HTRANS <= IDLE;
    vif.drv_cb.HADDR  <= '0;
    vif.drv_cb.HWRITE <= 1'b0;
    vif.drv_cb.HSIZE  <= WORD;
    vif.drv_cb.HBURST <= SINGLE;
    vif.drv_cb.HPROT  <= 4'b0011;
    vif.drv_cb.HWDATA <= '0;
  endtask

  local task handle_reset();
    n_resets++;
    drive_reset_values();
    dp_valid = 0;
    while (!vif.drv_cb.HRESETn) @(vif.drv_cb);
    reset_hit = 0;
  endtask

  task run();
    drive_reset_values();
    forever begin
      ahb_txn t;
      if (!vif.drv_cb.HRESETn) handle_reset();
      if (gen2drv.try_get(t)) begin
        in_txn = 1;
        n_txns++;
        drive_txn(t);
        in_txn = 0;
        if (!reset_hit) begin
          int unsigned n_gap = $urandom_range(0, cfg.idle_max);
          repeat (n_gap) begin
            bus_cycle(IDLE, null, 0);
            if (reset_hit) break;
          end
        end
      end else begin
        bus_cycle(IDLE, null, 0);
      end
      if (reset_hit) handle_reset();
    end
  endtask

  // Drive every beat of one transaction, inserting BUSY cycles between beats
  local task drive_txn(ahb_txn t);
    cancel_burst = 0;
    for (int unsigned i = 0; i < t.beats; i++) begin
      if (i > 0 && cfg.busy_pct > 0 && $urandom_range(0, 99) < cfg.busy_pct) begin
        int unsigned n_b = $urandom_range(1, cfg.busy_max);
        repeat (n_b) begin
          bus_cycle(BUSY, t, i);
          if (cancel_burst || reset_hit) break;
        end
      end
      if (!cancel_burst && !reset_hit) bus_cycle(i == 0 ? NONSEQ : SEQ, t, i);
      if (cancel_burst) begin n_cancelled      += t.beats - i; break; end
      if (reset_hit)    begin n_reset_unissued += t.beats - i; break; end
    end
  endtask

  // One AHB bus "slot": drive it, then wait until it is accepted (HREADY high)
  local task bus_cycle(htrans_e tr, ahb_txn t, int unsigned beat);
    bit cancelled = 0;

    vif.drv_cb.HTRANS <= tr;
    vif.drv_cb.HSEL   <= 1'b1;   // the bridge is the only AHB slave in this TB
    if (t != null) begin
      last_addr          = t.addr_of(beat);
      vif.drv_cb.HADDR  <= last_addr;
      vif.drv_cb.HWRITE <= t.write;
      vif.drv_cb.HSIZE  <= t.size;
      vif.drv_cb.HBURST <= t.burst;
      vif.drv_cb.HPROT  <= t.prot;
    end
    // HWDATA belongs to the previous beat's data phase. Outside a write data
    // phase, drive random junk so a bridge that wrongly samples HWDATA is caught.
    vif.drv_cb.HWDATA <= (dp_valid && dp_write) ? dp_wdata : $urandom;

    forever begin
      @(vif.drv_cb);
      if (!vif.drv_cb.HRESETn) begin
        reset_hit = 1;
        if (dp_valid) n_reset_inflight++;
        dp_valid = 0;
        return;
      end
      if (vif.drv_cb.HREADY) break;
      // Wait state. First ERROR cycle (HRESP=1, HREADY=0) for a beat of THIS
      // burst: optionally cancel the remaining beats by driving IDLE.
      if (vif.drv_cb.HRESP && dp_valid && !cancelled && t != null && t == dp_txn &&
          $urandom_range(0, 99) < cfg.cancel_pct) begin
        vif.drv_cb.HTRANS <= IDLE;
        cancelled    = 1;
        cancel_burst = 1;
      end
    end

    // HREADY high: previous data phase done, this slot's address phase accepted
    if (dp_valid) begin
      n_completed++;
      if (vif.drv_cb.HRESP) n_err_resp++;
    end
    if ((tr == NONSEQ || tr == SEQ) && !cancelled) begin
      dp_valid = 1;
      dp_write = t.write;
      dp_wdata = t.data[beat];
      dp_txn   = t;
      n_accepted++;
    end else begin
      dp_valid = 0;
    end
    if (tr == BUSY && !cancelled) n_busy++;
    if (tr == IDLE || cancelled)  n_idle++;
  endtask
endclass
