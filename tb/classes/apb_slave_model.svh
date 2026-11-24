// =============================================================================
// apb_slave_model - reactive, memory-backed APB4 completer for ONE PSEL bit.
//
// * Sees SETUP (PSEL[idx]=1, PENABLE=0), picks a random wait count in
//   [min_wait, max_wait] and an optional PSLVERR, then drives PREADY low for
//   that many ACCESS cycles before driving PREADY=1 with PRDATA/PSLVERR.
// * Writes update memory (byte lanes per PSTRB) only if not errored.
// * Memory is cleared on PRESETn (peripheral registers reset).
// * Flags protocol violations it can see (ACCESS without SETUP, PSEL dropped
//   mid-transfer).
// =============================================================================
class apb_slave_model;
  virtual apb_if.slave      vif;
  int                       idx;
  test_cfg                  cfg;
  logic [31:0]              mem[logic [31:0]];
  logic [31:0]              err_addrs[$];      // directed: these word addresses always PSLVERR

  int unsigned n_xfers, n_reads, n_writes, n_errors, n_proto_err;

  local bit                 active, ready_q, err;
  local int unsigned        waits, cnt;

  function new(virtual apb_if.slave vif, int idx, test_cfg cfg);
    this.vif = vif;
    this.idx = idx;
    this.cfg = cfg;
  endfunction

  function logic [31:0] read_word(logic [31:0] a);
    logic [31:0] wa = {a[31:2], 2'b00};
    return mem.exists(wa) ? mem[wa] : slv_init_word(idx, wa);
  endfunction

  local function bit is_err_addr(logic [31:0] a);
    foreach (err_addrs[i]) if (err_addrs[i] == {a[31:2], 2'b00}) return 1;
    return 0;
  endfunction

  local task drive_idle();
    vif.slv_cb.PREADY[idx]  <= 1'b0;
    vif.slv_cb.PSLVERR[idx] <= 1'b0;
    vif.slv_cb.PRDATA[idx]  <= '0;
    ready_q = 0;
  endtask

  local task drive_resp();
    vif.slv_cb.PREADY[idx]  <= 1'b1;
    vif.slv_cb.PSLVERR[idx] <= err;
    vif.slv_cb.PRDATA[idx]  <= vif.slv_cb.PWRITE ? 32'h0 : (err ? ERR_RDATA : read_word(vif.slv_cb.PADDR));
    ready_q = 1;
  endtask

  local task start_xfer();
    active = 1;
    cnt    = 0;
    waits  = $urandom_range(cfg.min_wait[idx], cfg.max_wait[idx]);
    err    = is_err_addr(vif.slv_cb.PADDR) || ($urandom_range(0, 99) < cfg.err_pct[idx]);
    if (waits == 0) drive_resp();
    else begin
      vif.slv_cb.PREADY[idx] <= 1'b0;
      ready_q = 0;
    end
  endtask

  local task complete_xfer();
    logic [31:0] wa = {vif.slv_cb.PADDR[31:2], 2'b00};
    n_xfers++;
    if (err) n_errors++;
    if (vif.slv_cb.PWRITE) begin
      n_writes++;
      if (!err) begin
        logic [31:0] w = read_word(wa);
        for (int b = 0; b < 4; b++)
          if (vif.slv_cb.PSTRB[b]) w[8*b +: 8] = vif.slv_cb.PWDATA[8*b +: 8];
        mem[wa] = w;
      end
    end else begin
      n_reads++;
    end
    active = 0;
    drive_idle();
  endtask

  task run();
    drive_idle();
    forever begin
      @(vif.slv_cb);
      if (!vif.slv_cb.PRESETn) begin
        mem.delete();
        active = 0;
        drive_idle();
        continue;
      end
      if (!vif.slv_cb.PSEL[idx]) begin
        if (active) begin
          n_proto_err++;
          $display("[%0t] APB S%0d PROTOCOL ERROR: PSEL dropped before PREADY", $time, idx);
          active = 0;
          drive_idle();
        end
        continue;
      end
      if (!active) begin
        // expect SETUP
        if (vif.slv_cb.PENABLE) begin
          n_proto_err++;
          $display("[%0t] APB S%0d PROTOCOL ERROR: ACCESS (PENABLE=1) without a SETUP cycle, PADDR=0x%08h",
                   $time, idx, vif.slv_cb.PADDR);
        end
        start_xfer();
      end else begin
        // in ACCESS
        if (!vif.slv_cb.PENABLE) begin
          n_proto_err++;
          $display("[%0t] APB S%0d PROTOCOL ERROR: PENABLE low during ACCESS", $time, idx);
        end
        if (ready_q) complete_xfer();          // PREADY was high at this edge: transfer done
        else if (++cnt >= waits) drive_resp(); // last wait cycle: assert PREADY next cycle
      end
    end
  endtask
endclass
