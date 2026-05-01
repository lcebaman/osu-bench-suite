#!/usr/bin/env python3
"""
plot_results.py — Generate publication-quality plots from OSU benchmark CSVs.

Produces per-benchmark plots:
  1. Latency/BW vs message size  (one line per MPI label, one panel per node count)
  2. Scaling plot                (latency at fixed msg size vs node count, one line per MPI label)
  3. Comparison heatmap          (MPI label vs node count, value at largest message size)

Usage:
    python3 plot_results.py [--csv-dir DIR] [--plot-dir DIR] [--bench NAME] [--format pdf|png]
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# ---------------------------------------------------------------------------
# Style
# ---------------------------------------------------------------------------
COLORS = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e",
          "#9467bd", "#8c564b", "#e377c2", "#7f7f7f"]
MARKERS = ["o", "s", "^", "D", "v", ">", "<", "p"]
LINESTYLES = ["-", "--", "-.", ":", "-", "--"]

plt.rcParams.update({
    "font.family":      "sans-serif",
    "font.size":        11,
    "axes.titlesize":   12,
    "axes.labelsize":   11,
    "legend.fontsize":  9,
    "axes.grid":        True,
    "grid.alpha":       0.3,
    "grid.linestyle":   "--",
    "axes.spines.top":  False,
    "axes.spines.right":False,
    "figure.dpi":       150,
})

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def bytes_to_label(b):
    """Return human-readable byte size."""
    for unit, thresh in [("GiB", 2**30), ("MiB", 2**20), ("KiB", 2**10)]:
        if b >= thresh:
            return f"{b/thresh:.0f} {unit}"
    return f"{b} B"


def is_bw_bench(bench_name):
    return any(x in bench_name for x in ["bw", "mbw"])


def value_label(bench_name):
    if is_bw_bench(bench_name):
        return "Bandwidth (MB/s)"
    return "Latency (µs)"


def load_csv(path):
    try:
        df = pd.read_csv(path)
        df.columns = df.columns.str.strip()
        return df
    except Exception as e:
        print(f"  ERROR loading {path}: {e}")
        return None


# ---------------------------------------------------------------------------
# Plot 1: Latency/BW vs message size — multi-panel (one per node count)
# ---------------------------------------------------------------------------

def plot_vs_msgsize(df, bench_name, plot_dir, fmt):
    node_counts = sorted(df["nodes"].unique())
    labels = sorted(df["mpi_label"].unique())
    val_col = [c for c in df.columns if c not in ("mpi_label","nodes","nranks","msg_bytes")][0]
    is_bw = is_bw_bench(bench_name)

    ncols = min(len(node_counts), 4)
    nrows = (len(node_counts) + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols,
                             figsize=(5 * ncols, 4 * nrows),
                             squeeze=False)
    fig.suptitle(f"{bench_name} — {value_label(bench_name)} vs Message Size",
                 fontsize=13, fontweight="bold", y=1.01)

    for idx, nodes in enumerate(node_counts):
        ax = axes[idx // ncols][idx % ncols]
        sub = df[df["nodes"] == nodes]
        nranks = sub["nranks"].iloc[0] if not sub.empty else nodes * "?"

        for i, label in enumerate(labels):
            grp = sub[sub["mpi_label"] == label].sort_values("msg_bytes")
            if grp.empty:
                continue
            ax.plot(grp["msg_bytes"], grp[val_col],
                    color=COLORS[i % len(COLORS)],
                    marker=MARKERS[i % len(MARKERS)],
                    linestyle=LINESTYLES[i % len(LINESTYLES)],
                    markersize=5, linewidth=1.5, label=label)

        ax.set_xscale("log", base=2)
        if not is_bw:
            ax.set_yscale("log")
        ax.set_xlabel("Message Size (bytes)")
        ax.set_ylabel(value_label(bench_name))
        ax.set_title(f"{nodes} node(s) — {nranks} ranks")
        ax.xaxis.set_major_formatter(
            ticker.FuncFormatter(lambda x, _: bytes_to_label(int(x))))
        ax.tick_params(axis="x", rotation=30)
        ax.legend(loc="best", framealpha=0.7)

    # Hide unused panels
    for idx in range(len(node_counts), nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    fig.tight_layout()
    out = plot_dir / f"{bench_name}_vs_msgsize.{fmt}"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# Plot 2: Scaling — value at fixed message size vs node count
# ---------------------------------------------------------------------------

def plot_scaling(df, bench_name, plot_dir, fmt, fixed_sizes=None):
    val_col = [c for c in df.columns if c not in ("mpi_label","nodes","nranks","msg_bytes")][0]
    labels = sorted(df["mpi_label"].unique())
    is_bw = is_bw_bench(bench_name)

    # Pick a few representative message sizes
    all_sizes = sorted(df["msg_bytes"].unique())
    if fixed_sizes is None:
        # Pick ~3 representative sizes: small, medium, large
        picks = []
        for frac in [0, 0.5, 1.0]:
            idx = min(int(frac * (len(all_sizes) - 1)), len(all_sizes) - 1)
            picks.append(all_sizes[idx])
        fixed_sizes = sorted(set(picks))

    # Skip barrier (no message size)
    if "osu_barrier" in bench_name:
        fixed_sizes = [None]

    ncols = len(fixed_sizes)
    fig, axes = plt.subplots(1, ncols, figsize=(5 * ncols, 4), squeeze=False)
    fig.suptitle(f"{bench_name} — Scaling vs Node Count",
                 fontsize=13, fontweight="bold")

    for col, sz in enumerate(fixed_sizes):
        ax = axes[0][col]
        if sz is None:
            sub = df.copy()
            title_sz = "(all)"
        else:
            sub = df[df["msg_bytes"] == sz]
            title_sz = bytes_to_label(sz)

        node_counts = sorted(sub["nodes"].unique())

        for i, label in enumerate(labels):
            grp = sub[sub["mpi_label"] == label].sort_values("nodes")
            if grp.empty:
                continue
            vals = grp.groupby("nodes")[val_col].mean()
            ax.plot(vals.index, vals.values,
                    color=COLORS[i % len(COLORS)],
                    marker=MARKERS[i % len(MARKERS)],
                    linestyle=LINESTYLES[i % len(LINESTYLES)],
                    markersize=6, linewidth=1.8, label=label)

        ax.set_xlabel("Nodes")
        ax.set_ylabel(value_label(bench_name))
        ax.set_title(f"Message size: {title_sz}")
        ax.set_xticks(node_counts)
        ax.legend(loc="best", framealpha=0.7)
        if not is_bw and ax.get_ylim()[0] > 0:
            ax.set_yscale("log")

    fig.tight_layout()
    out = plot_dir / f"{bench_name}_scaling.{fmt}"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# Plot 3: Heatmap — MPI label vs node count (value at largest msg size)
# ---------------------------------------------------------------------------

def plot_heatmap(df, bench_name, plot_dir, fmt):
    val_col = [c for c in df.columns if c not in ("mpi_label","nodes","nranks","msg_bytes")][0]
    is_bw = is_bw_bench(bench_name)

    # Use largest message size available
    if "osu_barrier" in bench_name:
        pivot = df.groupby(["mpi_label", "nodes"])[val_col].mean().unstack("nodes")
        sz_label = "(barrier, no msg size)"
    else:
        max_sz = df["msg_bytes"].max()
        sub = df[df["msg_bytes"] == max_sz]
        pivot = sub.groupby(["mpi_label", "nodes"])[val_col].mean().unstack("nodes")
        sz_label = bytes_to_label(int(max_sz))

    if pivot.empty or pivot.shape[1] < 2:
        return   # not enough data for a useful heatmap

    fig, ax = plt.subplots(figsize=(max(6, pivot.shape[1] * 1.4), max(3, pivot.shape[0] * 0.9)))
    cmap = "RdYlGn_r" if not is_bw else "RdYlGn"

    im = ax.imshow(pivot.values, cmap=cmap, aspect="auto")
    cbar = fig.colorbar(im, ax=ax)
    cbar.set_label(value_label(bench_name))

    ax.set_xticks(range(pivot.shape[1]))
    ax.set_xticklabels([f"{c}N" for c in pivot.columns])
    ax.set_yticks(range(pivot.shape[0]))
    ax.set_yticklabels(pivot.index)
    ax.set_xlabel("Node Count")
    ax.set_ylabel("MPI Installation")
    ax.set_title(f"{bench_name} — {value_label(bench_name)} @ {sz_label}")

    # Annotate cells
    for r in range(pivot.shape[0]):
        for c in range(pivot.shape[1]):
            val = pivot.values[r, c]
            if np.isnan(val):
                continue
            txt = f"{val:.1f}" if val < 1000 else f"{val:.0f}"
            ax.text(c, r, txt, ha="center", va="center",
                    fontsize=9, color="black", fontweight="bold")

    fig.tight_layout()
    out = plot_dir / f"{bench_name}_heatmap.{fmt}"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# Plot 4: Bar chart comparison at largest message size, largest node count
# ---------------------------------------------------------------------------

def plot_bar_comparison(all_data, plot_dir, fmt):
    """Single figure comparing all benchmarks across MPI installs."""
    rows = []
    for bench_name, df in all_data.items():
        val_col = [c for c in df.columns
                   if c not in ("mpi_label","nodes","nranks","msg_bytes")][0]
        is_bw = is_bw_bench(bench_name)
        max_nodes = df["nodes"].max()
        if "osu_barrier" not in bench_name:
            max_sz = df["msg_bytes"].max()
            sub = df[(df["nodes"] == max_nodes) & (df["msg_bytes"] == max_sz)]
        else:
            sub = df[df["nodes"] == max_nodes]

        for label in df["mpi_label"].unique():
            grp = sub[sub["mpi_label"] == label]
            if grp.empty:
                continue
            val = grp[val_col].mean()
            rows.append({"bench": bench_name, "label": label,
                         "value": val, "is_bw": is_bw,
                         "nodes": max_nodes})

    if not rows:
        return

    summary = pd.DataFrame(rows)
    benches = sorted(summary["bench"].unique())
    labels  = sorted(summary["label"].unique())

    x = np.arange(len(benches))
    width = 0.8 / len(labels)

    fig, ax = plt.subplots(figsize=(max(10, len(benches) * 1.5), 5))

    for i, label in enumerate(labels):
        vals = []
        for b in benches:
            row = summary[(summary["bench"] == b) & (summary["label"] == label)]
            vals.append(row["value"].mean() if not row.empty else 0)
        offset = (i - len(labels) / 2 + 0.5) * width
        bars = ax.bar(x + offset, vals, width * 0.9,
                      label=label, color=COLORS[i % len(COLORS)], alpha=0.85)

    ax.set_xticks(x)
    ax.set_xticklabels([b.replace("osu_", "") for b in benches], rotation=30, ha="right")
    ax.set_ylabel("Latency (µs) / BW (MB/s)")
    ax.set_title("MPI Installation Comparison — All Benchmarks\n"
                 "(largest message size, largest node count)")
    ax.legend(title="MPI Installation", bbox_to_anchor=(1.01, 1), loc="upper left")
    ax.set_yscale("log")

    fig.tight_layout()
    out = plot_dir / f"comparison_overview.{fmt}"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv-dir",  default="results/csv",  help="Directory with CSV files")
    parser.add_argument("--plot-dir", default="plots",         help="Output directory for plots")
    parser.add_argument("--bench",    default=None,            help="Only plot this benchmark")
    parser.add_argument("--format",   default="png",           choices=["png","pdf","svg"])
    args = parser.parse_args()

    csv_dir  = Path(args.csv_dir)
    plot_dir = Path(args.plot_dir)
    plot_dir.mkdir(parents=True, exist_ok=True)

    if not csv_dir.exists():
        print(f"ERROR: CSV directory not found: {csv_dir}")
        print("Run collect_results.sh first.")
        sys.exit(1)

    csv_files = sorted(csv_dir.glob("*.csv"))
    if not csv_files:
        print(f"No CSV files found in {csv_dir}")
        sys.exit(1)

    all_data = {}
    for csv_path in csv_files:
        bench_name = csv_path.stem
        if args.bench and bench_name != args.bench:
            continue
        df = load_csv(csv_path)
        if df is None or df.empty:
            continue
        all_data[bench_name] = df

    if not all_data:
        print("No data loaded — check CSV files.")
        sys.exit(1)

    print(f"Plotting {len(all_data)} benchmark(s) → {plot_dir}/")
    print()

    for bench_name, df in all_data.items():
        print(f"[{bench_name}]")
        try:
            plot_vs_msgsize(df, bench_name, plot_dir, args.format)
        except Exception as e:
            print(f"  WARN plot_vs_msgsize: {e}")
        try:
            plot_scaling(df, bench_name, plot_dir, args.format)
        except Exception as e:
            print(f"  WARN plot_scaling: {e}")
        try:
            plot_heatmap(df, bench_name, plot_dir, args.format)
        except Exception as e:
            print(f"  WARN plot_heatmap: {e}")

    # Overview bar chart across all benchmarks
    try:
        plot_bar_comparison(all_data, plot_dir, args.format)
    except Exception as e:
        print(f"  WARN plot_bar_comparison: {e}")

    print()
    print(f"Done. Plots written to: {plot_dir}/")


if __name__ == "__main__":
    main()
