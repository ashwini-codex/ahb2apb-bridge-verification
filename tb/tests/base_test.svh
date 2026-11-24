// =============================================================================
// base_test - every test extends this.
//   configure() : set test_cfg knobs (runs BEFORE the env is built)
//   body()      : generate stimulus through e.gen (directed and/or random)
// =============================================================================
virtual class base_test;
  env      e;
  test_cfg cfg;

  function new(test_cfg cfg);
    this.cfg = cfg;
  endfunction

  virtual function void configure();
  endfunction

  pure virtual task body();

  // Base addresses of the 4 APB slaves
  function logic [31:0] base(int i);
    return SLV_BASE[i];
  endfunction

  // Last word-aligned address inside slave i
  function logic [31:0] last_word(int i);
    return SLV_BASE[i] + SLV_SIZE[i] - 4;
  endfunction
endclass
