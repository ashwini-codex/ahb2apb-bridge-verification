# Debug log

These are the real problems found while bringing this project up on Verilator 5.054.
Each entry gives the symptom as it was seen, the root cause and the fix. Part 1 covers
problems found during development. Part 2 covers the deliberately injected RTL bugs
(`+define+INJECT_BUG_<n>`) and shows how they appear in the logs and waveforms.

**Honest summary:** the delivered RTL (`rtl/ahb2apb_bridge.sv`) has not failed any
assertion or scoreboard check since it was written. The bugs in Part 1 were in the
testbench, the tests, the coverage model and the tool flow. Part 2 shows the testbench
detecting realistic RTL bugs.

The cycle tables below come from `scripts/vcd_table.py`. It prints the value of each
signal **in the cycle that ends at the listed clock edge**, which is the value the
flops and assertions sample at that edge. The `<-` annotations were added by hand. The
bug 3 table puts columns from two runs (clean and injected) side by side.

---

## Part 1: bugs found during development

### 1. `ar_reset_values` failed at the first clock edge (testbench reset modelling)

- **Symptom:** the first run with the SVA bound reported `[5000] SVA FAIL: ar_reset_values`
  in `single_rw`. The scoreboard showed no other failures.
- **Debug:** at 5 ns reset is asserted, yet `HREADYOUT` was random. The DUT flops use
  `always_ff @(posedge HCLK or negedge HRESETn)`. The testbench drove `rst_n = 0` at
  t = 0, so there was **no negedge**, and the reset branch first ran at the first
  posedge. Until then the flops held their random `--x-initial unique` values, and the
  assertion samples the values from just before that edge.
- **Root cause:** a testbench issue. Real hardware resets on the level, but in simulation
  an asynchronous reset is triggered by its edge.
- **Fix:** `tb_top` starts `rst_n` at 1 and drives it low at 1 ns
  (`tb/top/tb_top.sv`). The assertion was correct and was left unchanged.

### 2. `busy_burst` test produced unexpected decode errors (test bug)

- **Symptom:** `busy_burst` passed, but its log showed `ERROR decode/slverr/size : 8 / 1 / 0`
  and `cancelled-after-ERROR 77`. The test was not meant to produce any decode errors.
  Coverage showed `cp_psel 75%`: slave 2 was never selected.
- **Root cause:** the test put bursts at `base(slave) + 0x900`, but slave 2 is only
  2 KB (`0x800`). Every burst aimed at slave 2 landed in the unmapped hole at
  0x4000_2800 to 0x4000_2FFF. The bridge and checkers behaved correctly (ERROR, no APB
  transfer), but the test was not testing what it claimed to.
- **Fix:** offsets moved below `0x800` (`tb/tests/directed_tests.svh`). After the fix:
  0 decode errors, `cp_psel` 100%.
- **Lesson:** a passing test is not evidence by itself. Read the stimulus statistics and
  the per-test coverage.

### 3. Driver and monitor disagreed on the BUSY count (testbench accounting)

- **Symptom:** in the same run, the driver reported `BUSY 243` and the AHB monitor `BUSY 237`.
- **Root cause:** when the master cancels a burst after the first ERROR cycle, a BUSY slot
  already on the bus is changed to IDLE. The driver still counted it as BUSY.
- **Fix:** the driver counts a BUSY slot only if it wasn't cancelled. Driver and monitor
  now agree (for example, 372 and 372 in `busy_burst` seed 1).

### 4. Reset covergroup hit the "idle" bin trivially (coverage model bug)

- **Symptom:** `cg_reset` showed 33% (the "idle" bin) in tests that never reset in the
  middle of a run, such as `slave_error`, `decode_error` and `wait_states`.
- **Root cause:** the power-on reset negedge (bug 1's fix) was being sampled as a
  mid-test reset while idle.
- **Fix:** `env.watch_reset()` waits for the first reset release before sampling. Then
  the real `reset_mid` test showed only 2 of 3 bins hit, so a fourth scenario (reset
  while the bus is idle) was added to that test. `cg_reset` is now 100%.

### 5. RTL line coverage reported `strobe()` as never executed (coverage measurement)

- **Symptom:** merged coverage showed 13/17 RTL lines. The `return` statements for byte
  and word in `strobe()` showed as unhit, yet byte and word writes certainly happen, and
  the scoreboard checks PSTRB on every write.
- **Root cause:** Verilator 5.054 did not attribute hits to the `return` statements inside
  the `case` of this function.
- **Fix:** the function now assigns a local variable in each branch and returns once.
  Line coverage then reports the branches correctly. Two remaining points were excluded
  with `/* verilator coverage_off */` plus a justification in the source: the FSM
  `default` branch (unreachable, since `state_q` only holds 6 legal encodings) and the
  `unused_ok` lint tie-off. The RTL is now at 100% line, branch, expression and toggle
  coverage with those two exclusions.

### 6. A short random run missed injected bug 4 (verification gap)

- **Symptom:** in the first bug-injection campaign, `random_regress` with 300
  transactions **passed** with `INJECT_BUG_4` (the wrong slave 2 decode). Only the
  directed `decode_error` test caught it.
- **Root cause:** the bug only affects a 2 KB window (0x4000_2800 to 0x4000_2FFF). In
  random stimulus, 3% of transactions target the "near unmapped" space (about 50 KB),
  so about 0.1% land in that window. 300 transactions are usually not enough.
- **Fix:** the campaign now runs `random_regress` at its real length of 2,000
  transactions. It then fails on seeds 1 to 5 with bug 4. A coverpoint `cp_unmap_zone`
  (below S0 / S2-to-S3 gap / above S3 / far) was added so the coverage report shows
  whether random stimulus reached each unmapped zone. The directed `decode_error` test
  stays the primary check for decode boundaries.

### 7. Tool-flow issues (Verilator 5.054)

| Symptom | Cause | Workaround |
|---|---|---|
| `Can't find typedef/interface: 'mailbox'` for `mailbox #(ahb_txn)` | Verilator didn't resolve the unqualified built-in class when parameterized with a class type | use the fully qualified `std::mailbox #(T)` (standard SystemVerilog, portable) |
| `fatal error: 'lz4.h' file not found` with `--trace-fst` | Homebrew's lz4 headers aren't on Verilator's include path | dump VCD (`--trace`). Surfer reads VCD. |
| Failed assertion aborted the simulation (`$stop`) | Verilator's default `$error` action on assertion failure | fail actions call `ahb2apb_sva_pkg::fail(<label>)`, which counts failures and keeps running. The test fails at the end if any count is non-zero. |

---

## Part 2: injected RTL bugs: how each one shows up

Build with `make compile BUG=<n>`, or run the whole campaign with `make bugs`. Full
results are in [`results/bug_injection.md`](results/bug_injection.md).

### INJECT_BUG_1: PADDR changes during a wait state

The address register's enable is `HSEL && HTRANS[1]` instead of `accept` (it is missing
the HREADY qualification). From `back_to_back`, seed 1:

```
[125000] SVA FAIL: ap_psel_matches_map
[125000] SVA FAIL: ap_stable_paddr
[135000] SB MISMATCH  PADDR    addr=0x40000500 RD : expected=0x40000500 actual=0x40001504
```

```
   t(ns)    state_q     HTRANS      HADDR     HWRITE  HREADYOUT       PSEL    PENABLE      PADDR     PREADY
     105          0          2   40000500          0          1          0          0   40000500          0
     115          2          2   40001504          1          0          1          0   40000500          0   <- SETUP for RD 0x40000500;
     125          3          2   40001504          1          0          1          1   40001504          1   <- master already pipelines
     135          0          2   40001504          1          1          0          0   40001504          0      the next address (WR 0x40001504)
```

During SETUP the master has already put the *next* address phase on HADDR (AHB
pipelining). The buggy enable loads it at the 115 ns edge, so PADDR changes between SETUP
and ACCESS, and the slave completes the read at the wrong address. `ap_stable_paddr`
fires at the first edge where PADDR has changed. The scoreboard then reports the
wrong PADDR and, later, wrong read data.

### INJECT_BUG_2: PENABLE asserted together with PSEL

`PENABLE` is decoded as `SETUP || ACCESS`. `ap_first_cycle_setup` fires on every transfer,
`ah_read_to_setup` and `ah_write_to_setup` fire because the bridge never presents a SETUP
cycle, the APB slave model reports `ACCESS (PENABLE=1) without a SETUP cycle`, and the
scoreboard flags `NO_SETUP`. All 9 tests fail.

### INJECT_BUG_3: second ERROR cycle missing

After ERR1 the FSM returns to IDLE with `HRESP=0`. From `slave_error`, seed 1, a write to
slave 1 with 100% PSLVERR injection:

```
[115000] SVA FAIL: ah_error_two_cycle
[115000] SB MISMATCH  HRESP    addr=0x40001040 WR : expected=0x1        actual=0x0
```

```
           clean RTL                                   INJECT_BUG_3
   t(ns) state HREADYOUT HRESP PSEL PENABLE PSLVERR     state HREADYOUT HRESP
      95     3         0     0    2       1       2         3         0     0   <- ACCESS, PREADY & PSLVERR
     105     4         0     1    0       0       0         4         0     1   <- ERROR cycle 1 (HREADYOUT=0)
     115     5         1     1    0       0       0         0         1     0   <- clean: ERROR cycle 2. bug: OKAY!
```

The AHB master samples the transfer as **OKAY** even though the APB slave signaled
PSLVERR. Only tests that produce errors can see this bug (`slave_error`, `decode_error`,
`busy_burst`, `random_regress`). The other five tests pass, as they should.

### INJECT_BUG_4: wrong PSEL decode for slave 2

Slave 2 is decoded with slave 1's 4 KB size, so the hole 0x4000_2800 to 0x4000_2FFF
selects slave 2. The independent reference decoder in the SVA module flags
`ah_unmapped_no_psel` and `ap_psel_matches_map`, plus `ah_unmapped_error` because no ERROR
response is given. The scoreboard reports `UNEXPECTED_APB` and `HRESP`. It is caught by
the directed `decode_error` test (address 0x4000_2FFC) and by the full-length
`random_regress` (see item 6 above).
