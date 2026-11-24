#!/usr/bin/env python3
"""
Print a cycle-by-cycle table of selected signals from a VCD, sampled just
before each rising clock edge (the values the flops and assertions see).

  python3 scripts/vcd_table.py waves/slave_error_1.vcd --from 400 --to 520
  python3 scripts/vcd_table.py waves/x.vcd --signals HTRANS,HADDR,PSEL,PENABLE --from 100 --to 200

Times are in ns. Signal names are looked up under tb_top.dut.
"""
import argparse

DEFAULT = "state_q,HTRANS,HADDR,HWRITE,HREADYOUT,HRESP,PSEL,PENABLE,PADDR,PREADY,PSLVERR"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("--signals", default=DEFAULT)
    ap.add_argument("--scope", default="tb_top.dut")
    ap.add_argument("--clock", default="tb_top.clk")
    ap.add_argument("--from", dest="t0", type=float, default=0)
    ap.add_argument("--to", dest="t1", type=float, default=1e18)
    a = ap.parse_args()

    sigs = a.signals.split(",")
    full = {f"{a.scope}.{s}": s for s in sigs}
    text = open(a.vcd).read()
    hdr, body = text.split("$enddefinitions", 1)

    ts = hdr.split("$timescale", 1)[-1].split("$end", 1)[0]
    timescale_ps = 1000 if "1ns" in ts else 1

    code2name, scope = {}, []
    for line in hdr.splitlines():
        t = line.split()
        if not t:
            continue
        if t[0] == "$scope":
            scope.append(t[2])
        elif t[0] == "$upscope":
            scope.pop()
        elif t[0] == "$var":
            name = ".".join(scope + [t[4]])
            if name in full:
                code2name.setdefault(t[3], []).append(full[name])   # VCD may alias one id to many names
            if name == a.clock:
                code2name.setdefault(t[3], []).append("__clk")

    val = {s: "?" for s in sigs}
    before = dict(val)          # values at the end of the previous timestep
    rows, now, pending = [], 0, None
    for tok in body.split():
        if tok[0] == "#":
            now = int(tok[1:]) * timescale_ps
            before = dict(val)
            continue
        if tok[0] in "bB":
            pending = tok[1:]
            continue
        if pending is not None and tok in code2name:
            for n in code2name[tok]:
                if n != "__clk":
                    val[n] = f"{int(pending, 2):x}" if set(pending) <= {"0", "1"} else pending
            pending = None
            continue
        if tok[0] in "01xz" and tok[1:] in code2name:
            for n in code2name[tok[1:]]:
                if n == "__clk":
                    if tok[0] == "1":        # rising edge: record values from before this edge
                        rows.append((now, before))
                else:
                    val[n] = tok[0]

    print(f"{'t(ns)':>8} " + " ".join(f"{s:>10}" for s in sigs))
    for t, v in rows:
        if a.t0 * 1000 <= t <= a.t1 * 1000:
            print(f"{t / 1000:8.0f} " + " ".join(f"{v[s]:>10}" for s in sigs))


if __name__ == "__main__":
    main()
