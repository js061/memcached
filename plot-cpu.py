#!/usr/bin/env python3
"""Plot CPU utilization over time for the memcached server and memtier client.

Reads two `perf stat -I <ms> -x, -e task-clock` CSV files (one per process) and
plots utilization vs time, normalized to each side's allotted (pinned) core count
so 100% means every pinned core is saturated.

perf's interval CSV rows look like:
    1.001234567,1001.50,msec,task-clock,1001508079,100.00,1.000,CPUs utilized
      time(s)    value   unit  event     ...
The task-clock `value` is CPU-time in msec consumed during that interval; dividing
by the interval length (in ms) gives cores-utilized.
"""

import argparse
import sys


def parse_perf_csv(path):
    """Return (times, util_cores): elapsed seconds and cores-utilized per interval."""
    times, values = [], []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                fields = line.split(",")
                if len(fields) < 4:
                    continue
                # fields: time, value, unit, event, ...
                # event may carry a modifier, e.g. "task-clock:u" (userspace-only,
                # which is what perf records as non-root under perf_event_paranoid>=2).
                if not fields[3].startswith("task-clock"):
                    continue
                if fields[1] in ("<not counted>", "<not supported>", ""):
                    continue
                try:
                    t = float(fields[0])
                    v = float(fields[1])  # task-clock, msec
                except ValueError:
                    continue
                times.append(t)
                values.append(v)
    except FileNotFoundError:
        return [], []

    # interval length = diff of cumulative perf timestamps (first measured from 0)
    util_cores = []
    prev = 0.0
    for t, v in zip(times, values):
        interval_s = t - prev
        prev = t
        if interval_s <= 0:
            util_cores.append(0.0)
        else:
            util_cores.append(v / (interval_s * 1000.0))  # msec -> cores
    return times, util_cores


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--server", required=True, help="perf CSV for memcached")
    ap.add_argument("--client", required=True, help="perf CSV for memtier")
    ap.add_argument("--out", required=True, help="output PNG path")
    ap.add_argument("--server-cores", type=int, default=1,
                    help="number of cores memcached is pinned to (for normalization)")
    ap.add_argument("--client-cores", type=int, default=1,
                    help="number of cores memtier is pinned to (for normalization)")
    ap.add_argument("--title", default="CPU utilization over time")
    args = ap.parse_args()

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("ERROR: matplotlib not installed. Install it with:", file=sys.stderr)
        print("    python3 -m pip install matplotlib", file=sys.stderr)
        return 1

    s_t, s_cores = parse_perf_csv(args.server)
    c_t, c_cores = parse_perf_csv(args.client)

    if not s_t and not c_t:
        print("ERROR: no task-clock samples found in either CSV", file=sys.stderr)
        return 1

    s_pct = [100.0 * c / max(args.server_cores, 1) for c in s_cores]
    c_pct = [100.0 * c / max(args.client_cores, 1) for c in c_cores]

    fig, ax = plt.subplots(figsize=(10, 5))
    if s_t:
        ax.plot(s_t, s_pct, marker="o", ms=3,
                label=f"memcached (server, {args.server_cores} cores)")
    if c_t:
        ax.plot(c_t, c_pct, marker="s", ms=3,
                label=f"memtier (client, {args.client_cores} cores)")
    ax.axhline(100.0, color="gray", linestyle="--", linewidth=1, label="100% (all pinned cores)")

    ax.set_xlabel("Time (s)")
    ax.set_ylabel("CPU utilization (% of pinned cores)")
    ax.set_title(args.title)
    ax.set_ylim(bottom=0)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best", fontsize=9)
    fig.tight_layout()
    fig.savefig(args.out, dpi=120)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
