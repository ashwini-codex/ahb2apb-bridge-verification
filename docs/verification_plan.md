# Verification plan: AHB-Lite to APB4 bridge

DUT: `rtl/ahb2apb_bridge.sv`. Specs: AMBA 3 AHB-Lite (ARM IHI 0033), AMBA APB (ARM IHI 0024, APB4 signals).

Every feature below is traced to the tests that stimulate it, the checks that verify it
(SVA in `tb/sva/ahb2apb_sva.sv`, scoreboard in `tb/classes/scoreboard.svh`), and the
coverage that proves it was exercised (`tb/classes/coverage.svh`, plus the
`cov_<label>` cover property paired with each assertion). The status column shows the
result of the regression committed in [`results/`](results/).

## 1. Feature list

| ID | Feature | Spec reference |
|---|---|---|
| F1 | AHB pipeline: address phase registered, write data taken in the following data phase | AHB-Lite: Basic transfers |
| F2 | HREADYOUT held low (AHB stalled) for the whole APB transfer | AHB-Lite: Waited transfers |
| F3 | APB sequencing IDLE → SETUP → ACCESS; PENABLE only in ACCESS; PENABLE drops after PREADY | APB: Operating states |
| F4 | PREADY wait states (0..N) honored | APB: transfers with wait states |
| F5 | APB address/control/data stable from SETUP through every wait state | APB: transfers with wait states |
| F6 | PSLVERR → two-cycle AHB ERROR (HRESP=1/HREADYOUT=0, then HRESP=1/HREADYOUT=1) | APB: Error response; AHB-Lite: Error response |
| F7 | 4-slave address decode from a parameterized map → one-hot PSEL | design spec |
| F8 | Out-of-map address → two-cycle ERROR, **no** APB transfer | design spec |
| F9 | HSIZE wider than 32 bits → ERROR, no APB transfer | design spec (defensive) |
| F10 | IDLE and BUSY transfers → zero-wait OKAY, no APB transfer | AHB-Lite: Transfer types |
| F11 | All burst types (SINGLE, INCR, INCR4/8/16, WRAP4/8/16), each beat becomes one APB transfer | AHB-Lite: Burst operation |
| F12 | Byte/halfword/word writes → PSTRB lanes; reads drive PSTRB = 0 | APB: Write strobes |
| F13 | HPROT → PPROT mapping | APB: Protection unit support |
| F14 | Read data path PRDATA → HRDATA, end-to-end against a reference memory | - |
| F15 | Reset: output values during reset, recovery after reset in the middle of a transfer | AHB-Lite: Reset |
| F16 | Back-to-back transfers (no IDLE cycles), including acceptance in the 2nd ERROR cycle | AHB-Lite: Basic transfers |
| F17 | AHB master (TB driver) behaviour: stable address/control/HWDATA during waits, burst cancel after ERROR | AHB-Lite: Waited transfers, Error response |

## 2. Test list

| Test | Kind | Stimulus |
|---|---|---|
| `single_rw` | directed | SINGLE write/read to every slave, first and last word, byte and halfword lanes, read of unwritten words |
| `burst_all` | directed | every HBURST × every HSIZE, write then read back; WRAP starting mid-window; INCR of length 1/5/16; INCR16 ending exactly at a 1 KB boundary |
| `wait_states` | directed | identical traffic with fixed 0, 1 and 5 wait states, then a mixed per-slave profile (0 / 1 / 5 / 0..7) |
| `slave_error` | directed | PSLVERR on reads and writes; mid-burst error with master cancel and continue; errors with wait states; back-to-back errors; errored write doesn't change memory |
| `decode_error` | directed | addresses just outside every region edge, in the S2/S3 hole, far away; region boundary words that must hit; bursts into holes; illegal HSIZE |
| `back_to_back` | directed | zero IDLE gaps: read-after-write to the same address, read and write streams across slaves, back-to-back bursts, with and without waits |
| `busy_burst` | directed | BUSY cycles before 80% of non-first beats, all burst types; BUSY combined with a mid-burst ERROR |
| `reset_mid` | directed | reset asserted during an APB ACCESS wait, in ERROR cycle 1, in a write data phase, and while idle; full re-check after each |
| `random_regress` | constrained random | 2,000 transactions per seed (10 seeds): weighted in-map/out-of-map addresses, all bursts/sizes, 0..5 random waits, 5% PSLVERR, 15% BUSY, random IDLE gaps, 50% cancel-on-error |
| `random_stress` | constrained random | 1,000 transactions per seed (5 seeds): no IDLE gaps, no waits, maximum throughput |

Constraints in `ahb_txn`: alignment to HSIZE, beat count from HBURST, the 1 KB boundary
for INCR-type bursts, WRAP addresses from the wrap boundary (`addr_of()`), a weighted
`dist` over target regions (4 slaves, near-unmapped, far-unmapped) and over burst types.

## 3. Traceability

| Feature | Tests | Assertions | Scoreboard checks | Functional coverage |
|---|---|---|---|---|
| F1 | all; `back_to_back`, `random_stress` | `ah_read_to_setup`, `ah_write_to_setup`, `ah_hwdata_stable_wait` | PADDR, PWDATA, PWRITE per beat | `cp_b2b`, `x_rw_b2b`, `cov_b2b_ahb` |
| F2 | all | `ah_stall_during_apb` | beat count driver = monitor = scoreboard | `cp_waits` |
| F3 | all | `ap_setup_then_access`, `ap_first_cycle_setup`, `ap_penable_only_access`, `ap_penable_drop_after_rdy`, `ap_psel_onehot0` | `NO_SETUP` check; APB slave model protocol checks | `cov_ap_*` hit counts |
| F4 | `wait_states`, `random_regress`, `reset_mid` | `ap_access_held_in_wait`, `ah_okay_after_apb` | read/write data across waits | `cp_waits` (0, 1, 2, 3-4, 5+), `x_waits_rw`, `cov_apb_wait_5` |
| F5 | `wait_states`, `random_regress` | `ap_stable_paddr`, `_pwrite`, `_psel`, `_pprot`, `_pstrb`, `_pwdata` | PADDR/PWDATA/PSTRB at completion | `cov_ap_stable_*` |
| F6 | `slave_error`, `random_regress`, `busy_burst` | `ah_slverr_to_error`, `ah_error_two_cycle`, `ah_error_second_has_first` | HRESP = PSLVERR; no memory update on errored write | `cp_err_cause.pslverr`, `x_psel_err`, `x_rw_err`, `cov_slverr_seq` |
| F7 | `single_rw`, `decode_error`, all | `ap_psel_matches_map` (independent reference decoder), `ap_psel_onehot0` | PSEL = 1 << decode(HADDR) | `cp_region`, `cp_psel`, `x_rw_region`, `x_psel_rw` |
| F8 | `decode_error`, `random_regress`, `random_stress` | `ah_unmapped_no_psel`, `ah_unmapped_error` | `UNEXPECTED_APB`, HRESP = ERROR | `cp_region.unmapped`, `cp_unmap_zone`, `cp_err_cause.decode`, `cov_decode_err_seq` |
| F9 | `decode_error` | `ah_unmapped_no_psel`, `ah_unmapped_error` (size is part of "mapped") | HRESP = ERROR, no APB | `cp_err_cause.bad_size` |
| F10 | `busy_burst`, `random_regress`, all (IDLE gaps) | `ah_idle_busy_okay` | no extra APB transfers (queue must be empty) | `cp_trans`, `cp_after_busy` |
| F11 | `burst_all`, `busy_burst`, random | (per-beat rules above) | every beat checked | `cp_burst`, `x_burst_size` (8 × 3) |
| F12 | `single_rw`, `burst_all`, random | `ap_pstrb_zero_on_read`, `ap_stable_pstrb` | PSTRB; HRDATA vs reference memory after partial writes | `cp_size` |
| F13 | all (random HPROT) | `ap_stable_pprot` | PPROT = {~HPROT[0], 0, HPROT[1]} | - |
| F14 | all reads | `ah_hrdata_from_prdata` | HRDATA = reference memory; HRDATA = PRDATA | `cp_rw.read`, `x_psel_rw` |
| F15 | `reset_mid`, every test (power-on) | `ar_reset_values`, `ar_no_x_ctrl` (4-state only) | scoreboard and slave memories flushed; re-check after reset | `cg_reset` (idle / AHB pending / APB in flight), `cov_reset_in_apb` |
| F16 | `back_to_back`, `slave_error` (step 5), `random_stress` | `ah_error_two_cycle` and the F1 properties | per beat | `cp_b2b.back2back`, `x_rw_b2b` |
| F17 | all | `ah_addr_ctrl_stable_wait`, `ah_hwdata_stable_wait` | beat accounting: generated = accepted + cancelled + dropped by reset | driver statistics (cancelled beats, BUSY count) |

## 4. Coverage goals and status

| Goal | Target | Achieved (merged regression) |
|---|---|---|
| Covergroup bins (`cg_ahb`, `cg_apb`, `cg_reset`) | 100% | 118/118 = 100% |
| Assertion cover properties (non-vacuous) | every property hit | 34/34 |
| RTL line / branch / expression / toggle | 100% (justified exclusions only) | 100% / 100% / 100% / 100%, with 2 exclusions: unreachable FSM `default`, lint tie-off |
| Assertion failures in the clean regression | 0 | 0 |
| Scoreboard mismatches in the clean regression | 0 | 0 |
| Injected RTL bugs detected | 4/4 | 4/4 |

Numbers come from [`results/coverage_summary.md`](results/coverage_summary.md) and
[`results/bug_injection.md`](results/bug_injection.md), both generated by `make results`.

## 5. Out of scope and known gaps

- **X propagation:** Verilator is a 2-state simulator, so `ar_no_x_ctrl` can't fail
  here. Reset robustness is checked instead with `--x-initial unique` and
  `--x-assign unique`, which randomize uninitialized state per seed.
- **Multi-slave AHB systems:** the TB has one AHB slave (the bridge), so `HREADY` always
  equals the bridge's `HREADYOUT`. The case where `HREADY` is low because *another*
  slave is stalling while the bridge is selected is not exercised.
- **Clock-domain crossing:** PCLK = HCLK by design. An asynchronous APB clock is not supported or verified.
- **Formal verification and synthesis** were not run.
