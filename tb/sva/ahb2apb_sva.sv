// =============================================================================
// ahb2apb_sva.sv - protocol assertions, bound into every ahb2apb_bridge instance.
//
// Each check is   <label>: assert property (...)  else ahb2apb_sva_pkg::fail(label)
//            and  cov_<label>: cover property (...)
// so every property also reports how often it was exercised non-vacuously.
//
// The address decoder below is an independent reference implementation built
// from the same parameters. It does NOT reuse the RTL's decode function, so a
// decode bug in the RTL shows up as a mismatch.
//
// Prefix:  ap_ = APB rules   ah_ = AHB rules   ar_ = reset rules
// =============================================================================
`timescale 1ns/1ps

`define AHB2APB_CHECK(label, prop) \
  label: assert property (@(posedge HCLK) disable iff (!HRESETn) prop) \
         else ahb2apb_sva_pkg::fail(`"label`"); \
  cov_``label: cover property (@(posedge HCLK) disable iff (!HRESETn) prop);

// Same, but active during reset too (for reset-value checks)
`define AHB2APB_CHECK_NORST(label, prop) \
  label: assert property (@(posedge HCLK) prop) \
         else ahb2apb_sva_pkg::fail(`"label`"); \
  cov_``label: cover property (@(posedge HCLK) prop);

module ahb2apb_sva #(
  parameter int unsigned              NUM_SLV  = 4,
  parameter logic [NUM_SLV-1:0][31:0] SLV_BASE = '0,
  parameter logic [NUM_SLV-1:0][31:0] SLV_SIZE = '0
) (
  input logic                      HCLK,
  input logic                      HRESETn,
  input logic                      HSEL,
  input logic [31:0]               HADDR,
  input logic [1:0]                HTRANS,
  input logic                      HWRITE,
  input logic [2:0]                HSIZE,
  input logic [2:0]                HBURST,
  input logic [3:0]                HPROT,
  input logic [31:0]               HWDATA,
  input logic                      HREADY,
  input logic                      HREADYOUT,
  input logic                      HRESP,
  input logic [31:0]               HRDATA,
  input logic [NUM_SLV-1:0]        PSEL,
  input logic                      PENABLE,
  input logic [31:0]               PADDR,
  input logic                      PWRITE,
  input logic [31:0]               PWDATA,
  input logic [3:0]                PSTRB,
  input logic [2:0]                PPROT,
  input logic [NUM_SLV-1:0][31:0]  PRDATA,
  input logic [NUM_SLV-1:0]        PREADY,
  input logic [NUM_SLV-1:0]        PSLVERR
);

  // ---------------------------------------------------------------------------
  // Helper signals
  // ---------------------------------------------------------------------------
  function automatic logic [NUM_SLV-1:0] ref_decode(input logic [31:0] a);
    logic [NUM_SLV-1:0] d;
    for (int i = 0; i < NUM_SLV; i++)
      d[i] = ({1'b0, a} >= {1'b0, SLV_BASE[i]}) && ({1'b0, a} < ({1'b0, SLV_BASE[i]} + {1'b0, SLV_SIZE[i]}));
    return d;
  endfunction

  logic        apb_setup, apb_access, apb_wait, apb_done, apb_pending;
  logic        pready_s, pslverr_s;
  logic [31:0] prdata_s;
  logic        ahb_xfer, ahb_mapped;

  always_comb begin
    pready_s  = 1'b0;
    pslverr_s = 1'b0;
    prdata_s  = '0;
    for (int i = 0; i < NUM_SLV; i++) if (PSEL[i]) begin
      pready_s  |= PREADY[i];
      pslverr_s |= PSLVERR[i];
      prdata_s  |= PRDATA[i];
    end
  end

  assign apb_setup   = (PSEL != '0) && !PENABLE;
  assign apb_access  = (PSEL != '0) &&  PENABLE;
  assign apb_wait    = apb_access && !pready_s;
  assign apb_done    = apb_access &&  pready_s;
  assign apb_pending = apb_setup || apb_wait;     // transfer started, not yet completed

  assign ahb_xfer    = HSEL && HREADY && HTRANS[1];                       // NONSEQ/SEQ sampled
  assign ahb_mapped  = (ref_decode(HADDR) != '0) && (HSIZE <= 3'd2);

  // Data-phase trackers (what the transfer in the data phase was)
  logic dp_write, dp_unmapped;
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      dp_write    <= 1'b0;
      dp_unmapped <= 1'b0;
    end else if (HREADY) begin
      dp_write    <= ahb_xfer && HWRITE;
      dp_unmapped <= ahb_xfer && !ahb_mapped;
    end
  end

  // ===========================================================================
  // APB sequencing  [IHI0024 4.1 operating states]
  // ===========================================================================
  // At most one slave selected
  `AHB2APB_CHECK(ap_psel_onehot0,           $onehot0(PSEL))
  // SETUP is always followed by ACCESS on the same slave
  `AHB2APB_CHECK(ap_setup_then_access,      apb_setup |=> (apb_access && $stable(PSEL)))
  // A new transfer starts with SETUP: PENABLE is low in the first PSEL cycle
  `AHB2APB_CHECK(ap_first_cycle_setup,      $rose(PSEL != '0) |-> !PENABLE)
  // PENABLE is only ever high in ACCESS (never without PSEL)
  `AHB2APB_CHECK(ap_penable_only_access,    PENABLE |-> (PSEL != '0))
  // ACCESS is held while PREADY is low
  `AHB2APB_CHECK(ap_access_held_in_wait,    apb_wait |=> apb_access)
  // PENABLE drops after the PREADY cycle
  `AHB2APB_CHECK(ap_penable_drop_after_rdy, apb_done |=> !PENABLE)

  // ===========================================================================
  // APB stability: SETUP->ACCESS and every wait state (PENABLE && !PREADY)
  // [IHI0024 3.1/3.3: signals unchanged until the transfer completes]
  // ===========================================================================
  `AHB2APB_CHECK(ap_stable_paddr,           apb_pending |=> $stable(PADDR))
  `AHB2APB_CHECK(ap_stable_pwrite,          apb_pending |=> $stable(PWRITE))
  `AHB2APB_CHECK(ap_stable_psel,            apb_pending |=> $stable(PSEL))
  `AHB2APB_CHECK(ap_stable_pprot,           apb_pending |=> $stable(PPROT))
  `AHB2APB_CHECK(ap_stable_pstrb,           apb_pending |=> $stable(PSTRB))
  `AHB2APB_CHECK(ap_stable_pwdata,          (apb_pending && PWRITE) |=> $stable(PWDATA))
  // PSTRB must be all-zero for reads [IHI0024 3.1.2]
  `AHB2APB_CHECK(ap_pstrb_zero_on_read,     ((PSEL != '0) && !PWRITE) |-> (PSTRB == '0))

  // ===========================================================================
  // Address decoding
  // ===========================================================================
  // The selected slave must be the one the reference map gives for PADDR
  `AHB2APB_CHECK(ap_psel_matches_map,       (PSEL != '0) |-> (PSEL == ref_decode(PADDR)))
  // An out-of-map (or illegal-size) transfer never asserts PSEL during its data phase
  `AHB2APB_CHECK(ah_unmapped_no_psel,       dp_unmapped |-> (PSEL == '0))
  // ... and it gets the ERROR response starting in its first data-phase cycle
  `AHB2APB_CHECK(ah_unmapped_error,         (ahb_xfer && !ahb_mapped) |=> (HRESP && !HREADYOUT))

  // ===========================================================================
  // AHB -> APB transfer sequencing (bridge latency)
  // ===========================================================================
  `AHB2APB_CHECK(ah_read_to_setup,          (ahb_xfer && ahb_mapped && !HWRITE) |=> apb_setup)
  `AHB2APB_CHECK(ah_write_to_setup,         (ahb_xfer && ahb_mapped &&  HWRITE) |=> ##1 apb_setup)
  // AHB is stalled for the whole APB transfer
  `AHB2APB_CHECK(ah_stall_during_apb,       (PSEL != '0) |-> !HREADYOUT)
  // Completion: OKAY on PREADY & !PSLVERR, ERROR on PSLVERR
  `AHB2APB_CHECK(ah_okay_after_apb,         (apb_done && !pslverr_s) |=> (HREADYOUT && !HRESP))
  `AHB2APB_CHECK(ah_slverr_to_error,        (apb_done &&  pslverr_s) |=> (HRESP && !HREADYOUT))
  // Read data returned to AHB is the PRDATA of the completing APB read
  `AHB2APB_CHECK(ah_hrdata_from_prdata,     (apb_done && !PWRITE && !pslverr_s) |=> (HRDATA == $past(prdata_s)))
  // IDLE / BUSY / unselected: zero-wait OKAY [IHI0033 3.2]
  `AHB2APB_CHECK(ah_idle_busy_okay,         (HREADY && !(HSEL && HTRANS[1])) |=> (HREADYOUT && !HRESP))

  // ===========================================================================
  // AHB two-cycle ERROR response [IHI0033 5.1.3]
  // ===========================================================================
  `AHB2APB_CHECK(ah_error_two_cycle,        (HRESP && !HREADYOUT) |=> (HRESP && HREADYOUT))
  `AHB2APB_CHECK(ah_error_second_has_first, (HRESP && HREADYOUT) |-> $past(HRESP && !HREADYOUT))

  // ===========================================================================
  // AHB master-side stability during wait states [IHI0033 3.6.1]
  // (checks the TB driver; while HREADY is low the pending NONSEQ/SEQ address
  //  phase must not change, except that the master may cancel the burst after the first ERROR cycle)
  // ===========================================================================
  `AHB2APB_CHECK(ah_addr_ctrl_stable_wait,  (!HREADY && HTRANS[1] && !HRESP) |=>
                                            $stable({HSEL, HADDR, HTRANS, HWRITE, HSIZE, HBURST, HPROT}))
  `AHB2APB_CHECK(ah_hwdata_stable_wait,     (dp_write && !HREADY) |=> $stable(HWDATA))

  // ===========================================================================
  // Reset
  // ===========================================================================
  // While reset is asserted: no APB transfer, AHB ready with OKAY [IHI0033 7.1.2]
  `AHB2APB_CHECK_NORST(ar_reset_values,     !HRESETn |-> (HREADYOUT && !HRESP && (PSEL == '0) && !PENABLE))
  // No X/Z on control outputs once out of reset. (Only meaningful on a 4-state
  // simulator; Verilator is 2-state, see README "Limitations".)
  `AHB2APB_CHECK(ar_no_x_ctrl,              !$isunknown({HREADYOUT, HRESP, PSEL, PENABLE, PWRITE, PADDR, PSTRB, PPROT}))

  // ===========================================================================
  // Extra cover-only scenarios
  // ===========================================================================
  cov_apb_wait_5:     cover property (@(posedge HCLK) disable iff (!HRESETn) apb_wait [*5]);
  cov_decode_err_seq: cover property (@(posedge HCLK) disable iff (!HRESETn)
                                      (ahb_xfer && !ahb_mapped) ##1 (HRESP && !HREADYOUT) ##1 (HRESP && HREADYOUT));
  cov_slverr_seq:     cover property (@(posedge HCLK) disable iff (!HRESETn)
                                      (apb_done && pslverr_s) ##1 (HRESP && !HREADYOUT) ##1 (HRESP && HREADYOUT));
  cov_b2b_ahb:        cover property (@(posedge HCLK) disable iff (!HRESETn)
                                      (ahb_xfer && HREADYOUT && !HRESP) ##1 !HREADYOUT [*1:8] ##1 (ahb_xfer && HREADYOUT));
  cov_reset_in_apb:   cover property (@(posedge HCLK) ((PSEL != '0) && HRESETn) ##1 !HRESETn);

  // HBURST is not checked by any property (the bridge ignores it); keep lint quiet
  logic unused_sva;
  assign unused_sva = &{1'b0, HBURST};

endmodule

// Attach to every instance of the bridge, picking up the instance's address map
bind ahb2apb_bridge ahb2apb_sva #(
  .NUM_SLV  (NUM_SLV),
  .SLV_BASE (SLV_BASE),
  .SLV_SIZE (SLV_SIZE)
) u_sva (.*);
