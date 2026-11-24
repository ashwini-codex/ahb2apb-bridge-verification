// =============================================================================
// rst_if.sv - clock/reset control, so a test class can apply reset mid-run.
// =============================================================================
`timescale 1ns/1ps

interface rst_if (input logic clk);
  logic rst_n;

  // Assert reset asynchronously (mid-cycle, like a real reset pin) for n cycles,
  // then release it synchronously just after a rising edge.
  task automatic pulse(int unsigned n_cycles, int unsigned assert_delay_ns = 3);
    #(assert_delay_ns);
    rst_n = 1'b0;
    repeat (n_cycles) @(posedge clk);
    #1 rst_n = 1'b1;
  endtask
endinterface
