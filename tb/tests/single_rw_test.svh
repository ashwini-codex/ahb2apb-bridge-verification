// =============================================================================
// single_rw: directed SINGLE write then read-back to every slave, at the first
// and last word of each region, plus byte and halfword lanes. Zero wait states.
// =============================================================================
class single_rw_test extends base_test;
  function new(test_cfg cfg); super.new(cfg); endfunction

  virtual function void configure();
    cfg.set_waits(0, 0);
    cfg.set_err_pct(0);
    cfg.idle_max = 1;
  endfunction

  virtual task body();
    for (int s = 0; s < NUM_SLV; s++) begin
      // read of never-written location: checks reset contents path
      e.gen.single(base(s) + 32'h10, 1'b0);
      // word write/read at the first and last word of the region
      e.gen.single(base(s),        1'b1);
      e.gen.single(base(s),        1'b0);
      e.gen.single(last_word(s),   1'b1);
      e.gen.single(last_word(s),   1'b0);
      // byte lanes 0..3 then halfword lanes 0/2, then read the word back
      for (int b = 0; b < 4; b++) e.gen.single(base(s) + 32'h20 + b, 1'b1, BYTE);
      e.gen.single(base(s) + 32'h20, 1'b0);
      e.gen.single(base(s) + 32'h24, 1'b1, HALF);
      e.gen.single(base(s) + 32'h26, 1'b1, HALF);
      e.gen.single(base(s) + 32'h24, 1'b0);
      e.gen.single(base(s) + 32'h26, 1'b0, HALF);
      e.gen.single(base(s) + 32'h23, 1'b0, BYTE);
    end
  endtask
endclass
