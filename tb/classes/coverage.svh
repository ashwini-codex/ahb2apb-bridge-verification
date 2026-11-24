// =============================================================================
// coverage - functional coverage, sampled by the monitors.
// =============================================================================
class coverage;
  // ---- AHB-side sample fields ----
  hburst_e     c_burst;
  int          c_size;
  bit          c_write;
  int          c_region;     // 0..3 = slave, -1 = unmapped
  bit          c_resp;
  int          c_err_cause;  // 0 none, 1 decode, 2 PSLVERR, 3 illegal size
  bit          c_b2b;
  bit          c_after_busy;
  htrans_e     c_trans;
  // ---- APB-side sample fields ----
  int          c_psel;
  int unsigned c_waits;
  bit          c_pslverr;
  bit          c_pwrite;
  // ---- reset sample fields ----
  int          c_rst_phase;  // 0 bus idle, 1 AHB data phase pending (no APB), 2 APB transfer in flight

  covergroup cg_ahb;
    cp_burst:      coverpoint c_burst;
    cp_size:       coverpoint c_size     { bins byte_ = {0}; bins half = {1}; bins word = {2}; }
    cp_rw:         coverpoint c_write    { bins read = {0}; bins write = {1}; }
    cp_region:     coverpoint c_region   { bins slv[4] = {[0:3]}; bins unmapped = {-1}; }
    cp_resp:       coverpoint c_resp     { bins okay = {0}; bins error = {1}; }
    cp_err_cause:  coverpoint c_err_cause{ bins none = {0}; bins decode = {1}; bins pslverr = {2}; bins bad_size = {3}; }
    cp_b2b:        coverpoint c_b2b      { bins gap = {0}; bins back2back = {1}; }
    cp_trans:      coverpoint c_trans    { bins nonseq = {NONSEQ}; bins seq = {SEQ}; }
    cp_after_busy: coverpoint c_after_busy { bins no = {0}; bins yes = {1}; }
    x_burst_size:  cross cp_burst, cp_size;
    x_rw_region:   cross cp_rw, cp_region;
    x_rw_b2b:      cross cp_rw, cp_b2b;
    x_rw_err:      cross cp_rw, cp_resp;
  endgroup

  covergroup cg_apb;
    cp_psel:    coverpoint c_psel    { bins slv[4] = {[0:3]}; }
    cp_waits:   coverpoint c_waits   { bins w0 = {0}; bins w1 = {1}; bins w2 = {2}; bins w3_4 = {[3:4]}; bins w5_plus = {[5:$]}; }
    cp_pslverr: coverpoint c_pslverr { bins okay = {0}; bins slverr = {1}; }
    cp_pwrite:  coverpoint c_pwrite  { bins read = {0}; bins write = {1}; }
    x_psel_rw:    cross cp_psel, cp_pwrite;
    x_waits_rw:   cross cp_waits, cp_pwrite;
    x_psel_err:   cross cp_psel, cp_pslverr;
  endgroup

  covergroup cg_reset;
    cp_rst_phase: coverpoint c_rst_phase { bins idle = {0}; bins ahb_pending = {1}; bins apb_in_flight = {2}; }
  endgroup

  function new();
    cg_ahb   = new();
    cg_apb   = new();
    cg_reset = new();
  endfunction

  function void sample_ahb(ahb_beat b);
    int s = decode_slave(b.addr);
    c_burst      = hburst_e'(b.burst);
    c_size       = int'(b.size);
    c_write      = b.write;
    c_region     = s;
    c_resp       = b.resp;
    c_err_cause  = !b.resp ? 0 : (b.size > 2 ? 3 : (s < 0 ? 1 : 2));
    c_b2b        = b.b2b;
    c_after_busy = b.after_busy;
    c_trans      = b.trans;
    cg_ahb.sample();
  endfunction

  function void sample_apb(apb_txn t);
    c_psel    = t.slv;
    c_waits   = t.waits;
    c_pslverr = t.pslverr;
    c_pwrite  = t.pwrite;
    cg_apb.sample();
  endfunction

  function void sample_reset(int phase);
    c_rst_phase = phase;
    cg_reset.sample();
  endfunction

  function void report();
    $display("---------------------------------------------------------------");
    $display(" FUNCTIONAL COVERAGE (this run)");
    $display("---------------------------------------------------------------");
    $display("  cg_ahb   %6.2f %%", cg_ahb.get_coverage());
    $display("    cp_burst      %6.2f %%   cp_size       %6.2f %%   cp_rw        %6.2f %%",
             cg_ahb.cp_burst.get_inst_coverage(), cg_ahb.cp_size.get_inst_coverage(), cg_ahb.cp_rw.get_inst_coverage());
    $display("    cp_region     %6.2f %%   cp_resp       %6.2f %%   cp_err_cause %6.2f %%",
             cg_ahb.cp_region.get_inst_coverage(), cg_ahb.cp_resp.get_inst_coverage(), cg_ahb.cp_err_cause.get_inst_coverage());
    $display("    cp_b2b        %6.2f %%   cp_trans      %6.2f %%   cp_after_busy %5.2f %%",
             cg_ahb.cp_b2b.get_inst_coverage(), cg_ahb.cp_trans.get_inst_coverage(), cg_ahb.cp_after_busy.get_inst_coverage());
    $display("    x_burst_size  %6.2f %%   x_rw_region   %6.2f %%   x_rw_b2b     %6.2f %%   x_rw_err %6.2f %%",
             cg_ahb.x_burst_size.get_inst_coverage(), cg_ahb.x_rw_region.get_inst_coverage(),
             cg_ahb.x_rw_b2b.get_inst_coverage(), cg_ahb.x_rw_err.get_inst_coverage());
    $display("  cg_apb   %6.2f %%", cg_apb.get_coverage());
    $display("    cp_psel       %6.2f %%   cp_waits      %6.2f %%   cp_pslverr   %6.2f %%   cp_pwrite %6.2f %%",
             cg_apb.cp_psel.get_inst_coverage(), cg_apb.cp_waits.get_inst_coverage(),
             cg_apb.cp_pslverr.get_inst_coverage(), cg_apb.cp_pwrite.get_inst_coverage());
    $display("    x_psel_rw     %6.2f %%   x_waits_rw    %6.2f %%   x_psel_err   %6.2f %%",
             cg_apb.x_psel_rw.get_inst_coverage(), cg_apb.x_waits_rw.get_inst_coverage(), cg_apb.x_psel_err.get_inst_coverage());
    $display("  cg_reset %6.2f %%", cg_reset.get_coverage());
  endfunction
endclass
