#!/usr/bin/env python3
"""
Regression runner for the AHB-to-APB bridge testbench (Verilator).

  python3 scripts/regress.py                 # every test x seeds, summary table
  python3 scripts/regress.py --coverage      # + merge coverage and print coverage report
  python3 scripts/regress.py --save          # + write docs/results/*.md from this run
  python3 scripts/regress.py --tests single_rw,reset_mid --seeds 1,2

Each run's PASS/FAIL comes from the simulator's own "RESULT:" line plus its
exit code. Nothing is computed or assumed here that the simulator did not print.
"""
import argparse
import collections
import concurrent.futures as cf
import datetime
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DIRECTED = ["single_rw", "burst_all", "wait_states", "slave_error",
            "decode_error", "back_to_back", "busy_burst", "reset_mid"]
RANDOM = ["random_regress", "random_stress"]

# default seeds per test
SEEDS = {t: [1, 2, 3, 4, 5] for t in DIRECTED}
SEEDS["random_regress"] = list(range(1, 11))
SEEDS["random_stress"] = [1, 2, 3, 4, 5]

RESULT_RE = re.compile(r"RESULT: test=(\S+) seed=(\d+) status=(\w+) checks=(\d+) sb_fail=(\d+) "
                       r"sva_fail=(\d+) cov_ahb=([\d.]+) cov_apb=([\d.]+)(?: reasons:(.*))?")


def sim_cmd(binary, test, seed, variant, extra=()):
    cov = os.path.join("cov", f"{variant}_{test}_{seed}.dat")
    return [binary, f"+TEST={test}", f"+SEED={seed}", f"+verilator+seed+{seed}",
            "+verilator+rand+reset+2", f"+verilator+coverage+file+{cov}", *extra]


def run_one(binary, test, seed, variant="default", extra=(), timeout=900):
    log = os.path.join("logs", f"{variant}_{test}_{seed}.log")
    t0 = time.time()
    try:
        p = subprocess.run(sim_cmd(binary, test, seed, variant, extra), cwd=ROOT,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), -999
        out += "\n[regress.py] wall-clock timeout\n"
    dt = time.time() - t0
    with open(os.path.join(ROOT, log), "w") as f:
        f.write(out)
    m = RESULT_RE.search(out)
    r = dict(test=test, seed=seed, log=log, rc=rc, secs=dt, status="FAIL", checks=0, sb_fail=0,
             sva_fail=0, cov_ahb=0.0, cov_apb=0.0, reasons="no RESULT line" if not m else "")
    if m:
        r.update(status=m.group(3), checks=int(m.group(4)), sb_fail=int(m.group(5)),
                 sva_fail=int(m.group(6)), cov_ahb=float(m.group(7)), cov_apb=float(m.group(8)),
                 reasons=(m.group(9) or "").strip())
    if rc != 0 and r["status"] == "PASS":
        r["status"], r["reasons"] = "FAIL", f"exit code {rc}"
    return r


def build(variant_bug=None):
    args = ["make", "compile"] + ([f"BUG={variant_bug}"] if variant_bug else [])
    p = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        print(p.stdout[-4000:])
        sys.exit(f"build failed: {' '.join(args)}")


# ----------------------------------------------------------------------------- coverage
def parse_dat(path):
    recs = []
    with open(path, encoding="latin1") as f:
        for line in f:
            if not line.startswith("C '"):
                continue
            key, cnt = line[3:].rstrip("\n").rsplit("' ", 1)
            d = {}
            for part in key.split("\x01")[1:]:
                k, _, v = part.partition("\x02")
                d[k] = v
            recs.append((d, int(cnt)))
    return recs


def coverage_report(dat_files, merged):
    subprocess.run(["verilator_coverage", "--write", merged, *dat_files], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["verilator_coverage", "--annotate", "cov/annotated", "--annotate-min", "1", merged],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    recs = parse_dat(os.path.join(ROOT, merged))
    lines = []

    # ---- functional coverage (covergroups), merged over all runs ----
    groups = collections.OrderedDict()
    for d, c in recs:
        if d.get("t") != "covergroup":
            continue
        h = d["h"].split("::")[-1]              # coverage::cg_ahb.cp_burst.auto[INCR16] -> cg_ahb.cp_burst...
        h = h.split("coverage::")[-1]
        cg, cp, binname = h.split(".", 2)
        groups.setdefault(cg, collections.OrderedDict()).setdefault(cp, []).append((binname, c))
    lines.append("### Functional coverage (covergroups, merged over all runs)\n")
    lines.append("| Covergroup | Coverpoint / cross | Bins hit | Coverage | Unhit bins |")
    lines.append("|---|---|---|---|---|")
    tot_hit = tot_all = 0
    for cg, cps in groups.items():
        for cp, bins in cps.items():
            hit = sum(1 for _, c in bins if c > 0)
            tot_hit += hit
            tot_all += len(bins)
            unhit = ", ".join(b for b, c in bins if c == 0) or "-"
            lines.append(f"| {cg} | {cp} | {hit}/{len(bins)} | {100.0 * hit / len(bins):.1f}% | {unhit} |")
    lines.append(f"\n**All covergroup bins: {tot_hit}/{tot_all} = {100.0 * tot_hit / max(tot_all, 1):.1f}%**\n")

    # ---- SVA cover properties ----
    sva = [(d["o"], c) for d, c in recs if d.get("t") == "user" and d.get("o", "").startswith("cov_")]
    lines.append("### Assertion cover properties (non-vacuous hits, merged)\n")
    lines.append("| Cover property | Hits |")
    lines.append("|---|---|")
    for name, c in sva:
        lines.append(f"| {name} | {c} |")
    zero = [n for n, c in sva if c == 0]
    lines.append(f"\n**{len(sva) - len(zero)}/{len(sva)} cover properties hit**"
                 + (f" (never hit: {', '.join(zero)})" if zero else "") + "\n")

    # ---- RTL code coverage ----
    lines.append("### RTL code coverage (rtl/ahb2apb_bridge.sv, Verilator --coverage)\n")
    lines.append("| Metric | Points hit | Coverage |")
    lines.append("|---|---|---|")
    for metric in ["line", "branch", "expr", "toggle"]:
        pts = [c for d, c in recs if d.get("t") == metric and d.get("f") == "rtl/ahb2apb_bridge.sv"]
        hit = sum(1 for c in pts if c > 0)
        if pts:
            lines.append(f"| {metric} | {hit}/{len(pts)} | {100.0 * hit / len(pts):.1f}% |")
    unhit_tog = sorted({d["o"].split(":")[0].split("[")[0] for d, c in recs
                        if d.get("t") == "toggle" and d.get("f") == "rtl/ahb2apb_bridge.sv" and c == 0})
    lines.append(f"\nSignals with at least one untoggled bit: {', '.join(unhit_tog) or 'none'}\n")
    unhit_other = [(d["t"], d["l"], d.get("o", "")) for d, c in recs
                   if d.get("t") in ("line", "branch", "expr") and d.get("f") == "rtl/ahb2apb_bridge.sv" and c == 0]
    if unhit_other:
        lines.append("Unhit RTL line/branch/expr points:\n")
        for t, l, o in unhit_other:
            lines.append(f"- {t} @ line {l}: `{o}`")
        lines.append("")
    lines.append("Annotated source: `cov/annotated/` (generated by `verilator_coverage --annotate`).")
    return "\n".join(lines)


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tests", help="comma-separated subset")
    ap.add_argument("--seeds", help="comma-separated seeds (overrides defaults)")
    ap.add_argument("--coverage", action="store_true", help="merge coverage and report")
    ap.add_argument("--save", action="store_true", help="write docs/results/*.md")
    ap.add_argument("-j", type=int, default=os.cpu_count())
    args = ap.parse_args()

    tests = args.tests.split(",") if args.tests else DIRECTED + RANDOM
    jobs = [(t, int(s)) for t in tests
            for s in (args.seeds.split(",") if args.seeds else SEEDS.get(t, [1]))]

    os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
    os.makedirs(os.path.join(ROOT, "cov"), exist_ok=True)
    for f in os.listdir(os.path.join(ROOT, "cov")):
        if f.startswith("default_") and f.endswith(".dat"):
            os.remove(os.path.join(ROOT, "cov", f))
    build()
    binary = os.path.join(ROOT, "build/default/Vtb_top")

    t0 = time.time()
    results = []
    with cf.ThreadPoolExecutor(max_workers=args.j) as ex:
        futs = {ex.submit(run_one, binary, t, s): (t, s) for t, s in jobs}
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            print(f"  {r['status']:4}  {r['test']:15} seed={r['seed']:<3} {r['secs']:6.1f}s  {r['reasons']}", flush=True)
    wall = time.time() - t0
    order = {t: i for i, t in enumerate(tests)}
    results.sort(key=lambda r: (order[r["test"]], r["seed"]))

    # ---- per-test summary table ----
    by_test = collections.OrderedDict()
    for r in results:
        by_test.setdefault(r["test"], []).append(r)
    hdr = "| Test | Seeds | Pass | Fail | Beats checked | SB mismatches | SVA failures | cg_ahb (best seed) | cg_apb (best seed) |"
    rows = [hdr, "|---|---|---|---|---|---|---|---|---|"]
    for t, rs in by_test.items():
        rows.append(f"| {t} | {','.join(str(r['seed']) for r in rs)} | {sum(r['status'] == 'PASS' for r in rs)} "
                    f"| {sum(r['status'] != 'PASS' for r in rs)} | {sum(r['checks'] for r in rs)} "
                    f"| {sum(r['sb_fail'] for r in rs)} | {sum(r['sva_fail'] for r in rs)} "
                    f"| {max(r['cov_ahb'] for r in rs):.2f}% | {max(r['cov_apb'] for r in rs):.2f}% |")
    npass = sum(r["status"] == "PASS" for r in results)
    total = (f"**{npass}/{len(results)} runs passed, {sum(r['checks'] for r in results)} AHB beats checked "
             f"by the scoreboard, wall time {wall:.0f}s with {args.j} parallel jobs.**")
    print("\n" + "\n".join(rows) + "\n\n" + total)
    fails = [r for r in results if r["status"] != "PASS"]
    for r in fails:
        print(f"FAILED: {r['test']} seed={r['seed']} -> {r['log']} ({r['reasons']})")

    cov_md = ""
    if args.coverage:
        dats = sorted(os.path.join("cov", f) for f in os.listdir(os.path.join(ROOT, "cov"))
                      if f.startswith("default_") and f.endswith(".dat"))
        cov_md = coverage_report(dats, "cov/merged.dat")
        print("\n" + cov_md)

    if args.save:
        ver = subprocess.run(["verilator", "--version"], stdout=subprocess.PIPE, text=True).stdout.strip()
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        os.makedirs(os.path.join(ROOT, "docs/results"), exist_ok=True)
        with open(os.path.join(ROOT, "docs/results/regression_summary.md"), "w") as f:
            f.write(f"# Regression summary\n\nGenerated by `scripts/regress.py` on {stamp} with {ver}.\n\n")
            f.write("\n".join(rows) + "\n\n" + total + "\n\n")
            f.write("## Every run\n\n| Test | Seed | Status | Beats checked | cg_ahb | cg_apb | Time (s) |\n|---|---|---|---|---|---|---|\n")
            for r in results:
                f.write(f"| {r['test']} | {r['seed']} | {r['status']} | {r['checks']} | {r['cov_ahb']:.2f}% "
                        f"| {r['cov_apb']:.2f}% | {r['secs']:.1f} |\n")
        if cov_md:
            with open(os.path.join(ROOT, "docs/results/coverage_summary.md"), "w") as f:
                f.write(f"# Coverage summary\n\nGenerated by `scripts/regress.py --coverage` on {stamp} with {ver}, "
                        f"merged over the {len(results)} regression runs above.\n\n{cov_md}\n")
        print("\nWrote docs/results/regression_summary.md" + (" and coverage_summary.md" if cov_md else ""))

    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
