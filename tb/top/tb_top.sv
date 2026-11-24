// =============================================================================
// tb_top - clock, reset, interfaces, DUT, SVA bind, test selection, waves.
//
//   +TEST=<name>   select a test (see ahb2apb_test_pkg::create_test)
//   +SEED=<n>      seed (the Makefile also passes +verilator+seed+<n>)
//   +NUM_TXNS=<n>  transaction count for random tests
//   +WAVES         dump waves/<test>_<seed>.vcd
//   +VERBOSE       print every transaction
// =============================================================================
`timescale 1ns/1ps

module tb_top;
  import ahb2apb_cfg_pkg::*;
  import ahb2apb_pkg::*;
  import ahb2apb_test_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;           // 100 MHz HCLK (= PCLK)

  rst_if rif (clk);
  ahb_if ahb (clk, rif.rst_n);
  apb_if apb (clk, rif.rst_n);

  // Single AHB slave: the HREADY mux collapses to the bridge's own HREADYOUT.
  assign ahb.HREADY = ahb.HREADYOUT;

  ahb2apb_bridge #(
    .NUM_SLV  (NUM_SLV),
    .SLV_BASE (SLV_BASE),
    .SLV_SIZE (SLV_SIZE)
  ) dut (
    .HCLK      (clk),
    .HRESETn   (rif.rst_n),
    .HSEL      (ahb.HSEL),
    .HADDR     (ahb.HADDR),
    .HTRANS    (ahb.HTRANS),
    .HWRITE    (ahb.HWRITE),
    .HSIZE     (ahb.HSIZE),
    .HBURST    (ahb.HBURST),
    .HPROT     (ahb.HPROT),
    .HWDATA    (ahb.HWDATA),
    .HREADY    (ahb.HREADY),
    .HREADYOUT (ahb.HREADYOUT),
    .HRESP     (ahb.HRESP),
    .HRDATA    (ahb.HRDATA),
    .PSEL      (apb.PSEL),
    .PENABLE   (apb.PENABLE),
    .PADDR     (apb.PADDR),
    .PWRITE    (apb.PWRITE),
    .PWDATA    (apb.PWDATA),
    .PSTRB     (apb.PSTRB),
    .PPROT     (apb.PPROT),
    .PRDATA    (apb.PRDATA),
    .PREADY    (apb.PREADY),
    .PSLVERR   (apb.PSLVERR)
  );

  initial begin
    test_cfg  cfg;
    env       e;
    base_test t;
    bit       pass;
    bit       timed_out = 0;
    string    wave_file;

    rif.rst_n = 1'b0;

    cfg = new();
    cfg.parse_plusargs();

    if ($test$plusargs("WAVES")) begin
      wave_file = $sformatf("waves/%s_%0d.vcd", cfg.test_name, cfg.seed);
      $display("Dumping waves to %s", wave_file);
      $dumpfile(wave_file);
      $dumpvars(0, tb_top);
    end

    t = create_test(cfg.test_name, cfg);
    if (t == null) begin
      $display("RESULT: test=%s seed=%0d status=FAIL reasons: unknown_test", cfg.test_name, cfg.seed);
      $fatal(1, "Unknown +TEST=%s", cfg.test_name);
    end
    t.configure();
    $display("CONFIG: %s", cfg.convert2string());

    e   = new(cfg, ahb, apb, rif);
    t.e = e;
    e.run();

    // Power-on reset: 5 cycles
    repeat (5) @(posedge clk);
    #1 rif.rst_n = 1'b1;
    @(posedge clk);

    fork
      begin
        t.body();
        e.wait_idle();
      end
      begin
        repeat (cfg.timeout_cycles) @(posedge clk);
        timed_out = 1;
        $display("[%0t] TIMEOUT after %0d cycles", $time, cfg.timeout_cycles);
      end
    join_any
    disable fork;

    pass = e.report(timed_out);
    if ($test$plusargs("WAVES")) $dumpflush;
    if (!pass) $fatal(1, "TEST FAILED");
    $display("TEST PASSED");
    $finish;
  end
endmodule
