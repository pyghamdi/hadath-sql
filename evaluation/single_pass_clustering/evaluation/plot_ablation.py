#!/usr/bin/env python3
"""Figures of the ablation (ABLATION.md): clustering time against the number of
documents, one panel per threshold, one line per driver, log-log axes. Writes one PDF
per dataset into the paper's Figures folder.

Run with the project environment, which has matplotlib:
    ../../../.venv/bin/python plot_ablation.py
Text is typeset by LaTeX (text.usetex) so that it matches the paper (Computer Modern).
"""
import csv
import math
import os

import matplotlib
matplotlib.use("pdf")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "..", "..", "..", "Writeup", "HadathSQL - Long Version", "Figures")
os.environ["PATH"] = "/Library/TeX/texbin:" + os.environ.get("PATH", "")
LIMIT = 1800  # time limit per run, in seconds

# HadathSQL is the reference, in black; the four variants use a categorical palette
# validated for all pairs (dataviz validate_palette.js, light mode, white surface);
# its two contrast and color-vision warnings are covered by distinct markers and line
# styles, so no series is identified by color alone.
DRIVERS = [
    ("driver_s", "HadathSQL",                    "#1a1a1a", "o", "-"),
    ("noidx_s",  "without indexes",              "#2a78d6", "s", "-"),
    ("mean_s",   "without summed centroids",     "#e34948", "^", "-"),
    ("noprep_s", "without prepared statements",  "#eda100", "D", "--"),
    ("noopt_s",  "without all three",            "#1baf7a", "v", ":"),
]
DATASETS = [("synthetic_tweets", "Synthetic-Tweets"), ("synthetic_news", "Synthetic-News")]

plt.rcParams.update({
    "text.usetex": True,
    "font.family": "serif",
    "font.size": 8,
    "axes.titlesize": 8,
    "axes.labelsize": 8,
    "legend.fontsize": 7.5,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7,
    "axes.linewidth": 0.5,
    "axes.edgecolor": "#888888",
    "xtick.color": "#555555",
    "ytick.color": "#555555",
    "xtick.major.width": 0.5,
    "ytick.major.width": 0.5,
    "xtick.minor.width": 0.4,
    "ytick.minor.width": 0.4,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "grid.color": "#e6e6e6",
    "grid.linewidth": 0.4,
})


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def kdocs(n):
    return f"{n // 1000}k" if n >= 1000 else str(n)


def style_axis(ax, sizes, th):
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_title(rf"threshold {th}", pad=3)
    ax.grid(True, which="major", axis="y")
    ax.set_xticks([s for s in sizes if s in (125, 500, 2000, 8000, 32000)] or sizes[::2])
    ax.set_xticklabels([kdocs(s) for s in ax.get_xticks()])
    ax.tick_params(which="minor", left=False, bottom=False)


def plot(setting, title):
    rows = list(csv.DictReader(open(os.path.join(HERE, f"results_ablation_{setting}.csv"))))
    thresholds = sorted({r["threshold"] for r in rows}, key=float)
    sizes = sorted({int(r["n"]) for r in rows})
    # y axis from the power of ten below the smallest time of the dataset
    times = [num(r[k]) for r in rows for k, *_ in DRIVERS if num(r[k]) is not None]
    ymin = 10 ** math.floor(math.log10(min(times)))
    # slowdown of a variant: its time divided by the HadathSQL driver's, where both completed
    def slowdown(r, key):
        v, d = num(r[key]), num(r["driver_s"])
        return v / d if v is not None and d else None
    ratios = [slowdown(r, k) for r in rows for k, *_ in DRIVERS[1:]]
    rmax = 10 ** math.ceil(math.log10(max(x for x in ratios if x is not None)))

    # 372 pt text width = 5.15 in; two groups of 2 x 3 panels: time, then slowdown
    fig = plt.figure(figsize=(5.15, 6.2), layout="constrained")
    top, bottom = fig.subfigures(2, 1, hspace=0.04)
    ax_t = top.subplots(2, 3, sharex=True, sharey=True)
    ax_s = bottom.subplots(2, 3, sharex=True, sharey=True)
    top.suptitle("Clustering time", fontsize=8.5)
    bottom.suptitle("Slowdown relative to the HadathSQL driver", fontsize=8.5)

    for ax, th in zip(ax_t.flat, thresholds):
        sub = sorted((r for r in rows if r["threshold"] == th), key=lambda r: int(r["n"]))
        ax.axhline(LIMIT, color="#9a9a9a", linewidth=0.6, linestyle=(0, (4, 2)), zorder=1)
        # the size at which each driver reached the time limit; drivers that reached it
        # at the same size are spread slightly sideways so that every marker shows
        first_out = {key: next((int(r["n"]) for r in sub if r[key] == "TIMEOUT"), None)
                     for key, *_ in DRIVERS}
        for key, label, color, marker, style in DRIVERS:
            # HadathSQL (the reference) is drawn on top of the variants
            z = 5 if key == "driver_s" else 3
            xs = [int(r["n"]) for r in sub if num(r[key]) is not None]
            ys = [num(r[key]) for r in sub if num(r[key]) is not None]
            ax.plot(xs, ys, color=color, marker=marker, linestyle=style, linewidth=1.1,
                    markersize=3.2, markeredgewidth=0.6, markeredgecolor="white", zorder=z)
            if first_out[key] is not None:
                same = [k for k, *_ in DRIVERS if first_out[k] == first_out[key]]
                shift = 1.13 ** (same.index(key) - (len(same) - 1) / 2)
                ax.plot([first_out[key] * shift], [LIMIT], color=color, marker="x",
                        linestyle="none", markersize=4, markeredgewidth=1.1, zorder=z + 1)
        style_axis(ax, sizes, th)
        ax.set_ylim(ymin, 4000)
    ax_t[0, 0].text(sizes[0], LIMIT * 1.25, "limit", fontsize=6.5, color="#777777", va="bottom")

    for ax, th in zip(ax_s.flat, thresholds):
        sub = sorted((r for r in rows if r["threshold"] == th), key=lambda r: int(r["n"]))
        # the HadathSQL driver is the reference: slowdown 1
        ax.axhline(1, color=DRIVERS[0][2], linewidth=1.1, zorder=2)
        for key, label, color, marker, style in DRIVERS[1:]:
            pts = [(int(r["n"]), slowdown(r, key)) for r in sub if slowdown(r, key) is not None]
            ax.plot([x for x, _ in pts], [y for _, y in pts], color=color, marker=marker,
                    linestyle=style, linewidth=1.1, markersize=3.2, markeredgewidth=0.6,
                    markeredgecolor="white", zorder=3)
        style_axis(ax, sizes, th)
        ax.set_ylim(0.7, rmax * 1.5)

    for axes, ylabel in ((ax_t, "time (s)"), (ax_s, "slowdown (times)")):
        for ax in axes[1]:
            ax.set_xlabel("documents")
        for ax in axes[:, 0]:
            ax.set_ylabel(ylabel)

    handles = [Line2D([], [], color=c, marker=m, linestyle=s, linewidth=1.1, markersize=3.5,
                      markeredgecolor="white", markeredgewidth=0.6, label=l)
               for _, l, c, m, s in DRIVERS]
    handles.append(Line2D([], [], color="#555555", marker="x", linestyle="none", markersize=4,
                          markeredgewidth=1.1, label="time limit reached"))
    fig.legend(handles=handles, loc="outside upper center", ncol=3, frameon=False,
               handlelength=2.2, columnspacing=1.2)
    path = os.path.join(OUT, f"ablation_{setting}.pdf")
    fig.savefig(path)
    plt.close(fig)
    print("wrote", os.path.relpath(path, HERE))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for setting, title in DATASETS:
        plot(setting, title)
