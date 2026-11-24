// =============================================================================
// ahb_txn - one AHB transaction (SINGLE or a whole burst) as produced by the
// generator and consumed by the driver.
// =============================================================================
typedef enum int { T_S0 = 0, T_S1 = 1, T_S2 = 2, T_S3 = 3, T_HOLE = 4, T_FAR = 5 } target_e;

class ahb_txn;
  static int unsigned next_id = 0;
  int unsigned        id;

  rand target_e       target;       // region the burst starts in (drives the weighted address choice)
  rand logic [31:0]   addr;         // address of the first beat
  rand bit            write;
  rand hsize_e        size;
  rand hburst_e       burst;
  rand int unsigned   beats;
  rand logic [31:0]   data[];       // write data per beat (ignored for reads)
  rand logic [3:0]    prot;

  // Weights copied from test_cfg before randomize()
  int unsigned w_tgt[6]   = '{24, 24, 24, 23, 3, 2};
  int unsigned w_burst[8] = '{30, 10, 10, 10, 10, 10, 10, 10};
  int unsigned max_incr_beats = 16;

  // ---------------------------------------------------------------------------
  // Constraints
  // ---------------------------------------------------------------------------
  // Weighted distribution of in-map vs out-of-map targets
  constraint c_target_dist {
    target dist { T_S0 := w_tgt[0], T_S1 := w_tgt[1], T_S2 := w_tgt[2], T_S3 := w_tgt[3],
                  T_HOLE := w_tgt[4], T_FAR := w_tgt[5] };
  }

  constraint c_target_addr {
    (target == T_S0) -> addr inside {[SLV_BASE[0] : SLV_BASE[0] + SLV_SIZE[0] - 1]};
    (target == T_S1) -> addr inside {[SLV_BASE[1] : SLV_BASE[1] + SLV_SIZE[1] - 1]};
    (target == T_S2) -> addr inside {[SLV_BASE[2] : SLV_BASE[2] + SLV_SIZE[2] - 1]};
    (target == T_S3) -> addr inside {[SLV_BASE[3] : SLV_BASE[3] + SLV_SIZE[3] - 1]};
    // "near" unmapped: the gaps around/inside the APB window (decode edge cases)
    (target == T_HOLE) -> (addr inside {[32'h3FFF_F000 : 32'h4000_FFFF]}) &&
                          !(addr inside {[SLV_BASE[0] : SLV_BASE[0] + SLV_SIZE[0] - 1],
                                         [SLV_BASE[1] : SLV_BASE[1] + SLV_SIZE[1] - 1],
                                         [SLV_BASE[2] : SLV_BASE[2] + SLV_SIZE[2] - 1],
                                         [SLV_BASE[3] : SLV_BASE[3] + SLV_SIZE[3] - 1]});
    (target == T_FAR)  -> !(addr inside {[32'h3FFF_F000 : 32'h4000_FFFF]});
  }

  // Only sizes up to the 32-bit bus width
  constraint c_size { size inside {BYTE, HALF, WORD}; }

  // Address aligned to HSIZE [AHB-Lite: Transfer size]
  constraint c_align {
    (size == HALF) -> addr[0]   == 1'b0;
    (size == WORD) -> addr[1:0] == 2'b00;
  }

  constraint c_burst_dist {
    burst dist { SINGLE := w_burst[0], INCR   := w_burst[1], WRAP4  := w_burst[2], INCR4 := w_burst[3],
                 WRAP8  := w_burst[4], INCR8  := w_burst[5], WRAP16 := w_burst[6], INCR16 := w_burst[7] };
  }

  // Number of beats from HBURST [AHB-Lite: Burst operation]
  constraint c_beats {
    (burst == SINGLE)                -> beats == 1;
    (burst == INCR)                  -> beats inside {[1 : max_incr_beats]};
    (burst inside {WRAP4,  INCR4})   -> beats == 4;
    (burst inside {WRAP8,  INCR8})   -> beats == 8;
    (burst inside {WRAP16, INCR16})  -> beats == 16;
  }

  // Incrementing bursts must not cross a 1KB boundary [AHB-Lite: Burst operation].
  // Wrapping bursts never can: the wrap window is at most 16 x 4 = 64 bytes and is aligned.
  constraint c_1kb {
    (burst inside {INCR, INCR4, INCR8, INCR16}) ->
      ({22'b0, addr[9:0]} + (beats << size)) <= 32'd1024;
  }

  constraint c_data  { data.size() == beats; }

  constraint c_order { solve target before addr; solve burst before beats; solve size before addr; }

  function new();
    id = next_id++;
  endfunction

  function void set_weights(test_cfg cfg);
    w_tgt          = cfg.w_tgt;
    w_burst        = cfg.w_burst;
    max_incr_beats = cfg.max_incr_beats;
  endfunction

  // Build a directed transaction (random data/prot unless overridden later)
  static function ahb_txn make(logic [31:0] a, bit w, hsize_e s, hburst_e b, int unsigned n = 0);
    ahb_txn t = new();
    t.addr  = a;
    t.write = w;
    t.size  = s;
    t.burst = b;
    case (b)
      SINGLE:         t.beats = 1;
      INCR:           t.beats = (n == 0) ? 4 : n;
      WRAP4, INCR4:   t.beats = 4;
      WRAP8, INCR8:   t.beats = 8;
      default:        t.beats = 16;
    endcase
    t.data = new[t.beats];
    foreach (t.data[i]) t.data[i] = $urandom;
    t.prot = 4'($urandom);
    t.target = target_e'(decode_slave(a) < 0 ? T_HOLE : decode_slave(a));
    return t;
  endfunction

  function int unsigned bytes_per_beat();
    return 1 << size;
  endfunction

  function bit is_wrap();
    return burst inside {WRAP4, WRAP8, WRAP16};
  endfunction

  // Address of beat i: incrementing, or wrapping at (beats x size) boundary [AHB-Lite: Burst operation]
  function logic [31:0] addr_of(int unsigned i);
    int unsigned nbytes = bytes_per_beat();
    if (is_wrap()) begin
      logic [31:0] wrap_bytes = beats * nbytes;
      logic [31:0] base       = addr & ~(wrap_bytes - 1);
      return base + ((addr - base + i * nbytes) % wrap_bytes);
    end
    return addr + i * nbytes;
  endfunction

  // Protocol-legality check used on directed transactions (random ones are legal by construction)
  function string check_legal();
    if (size == HALF  && addr[0]   != 0) return "unaligned halfword";
    if (size == WORD  && addr[1:0] != 0) return "unaligned word";
    if (size == DWORD && addr[2:0] != 0) return "unaligned doubleword";
    if (data.size() != beats)            return "data[] size != beats";
    if ((burst inside {INCR, INCR4, INCR8, INCR16}) && ((addr & 32'h3FF) + beats * bytes_per_beat()) > 1024)
      return "INCR burst crosses 1KB boundary";
    return "";
  endfunction

  function ahb_txn copy();
    ahb_txn t = new();
    t.target = target; t.addr = addr; t.write = write; t.size = size; t.burst = burst;
    t.beats  = beats;  t.prot = prot; t.data  = data;  // dynamic array assignment copies
    t.w_tgt  = w_tgt;  t.w_burst = w_burst; t.max_incr_beats = max_incr_beats;
    return t;
  endfunction

  function bit compare(ahb_txn o);
    if (o == null) return 0;
    if (addr != o.addr || write != o.write || size != o.size || burst != o.burst ||
        beats != o.beats || prot != o.prot) return 0;
    if (write) foreach (data[i]) if (data[i] != o.data[i]) return 0;
    return 1;
  endfunction

  function string convert2string();
    return $sformatf("txn#%0d %s %s %s x%0d addr=0x%08h prot=%b tgt=%s",
                     id, write ? "WR" : "RD", burst.name(), size.name(), beats, addr, prot, target.name());
  endfunction
endclass
