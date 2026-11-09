#!/usr/bin/env python3
"""Figure of the TF-IDF comparison (COMPARISON.md, "TF-IDF stage"):

  tfidf_sizes.pdf    time against the number of documents (log-log) and the lead of
                     HadathSQL (scikit-learn's time / HadathSQL's), one panel per
                     dataset: HadathSQL with PostgreSQL's default parallel workers and
                     scikit-learn, export and import included (results_tfidf_<setting>.csv)

Written into the paper's Figures folder. Needs matplotlib and LaTeX (text.usetex).
"""
import csv
import os

import matplotlib
matplotlib.use("pdf")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "..", "..", "..", "Writeup", "HadathSQL - Long Version", "Figures")
os.environ["PATH"] = "/Library/TeX/texbin:" + os.environ.get("PATH", "")

# Same colors as the ablation figures (plot_ablation.py): HadathSQL in black, the other
# method in the first color of the validated categorical palette; the two series also
# differ in marker and line style, so neither is identified by color alone.
HADATH = dict(color="#1a1a1a", marker="o", linestyle="-")
SKLEARN = dict(color="#2a78d6", marker="s", linestyle="--")
DATASETS = [("synthetic_tweets", "Synthetic-Tweets"), ("synthetic_news", "Synthetic-News")]

plt.rcParams.update({
    "text.usetex": True, "font.family": "serif", "font.size": 8,
    "axes.titlesize": 8, "axes.labelsize": 8, "legend.fontsize": 7.5,
    "xtick.labelsize": 7, "ytick.labelsize": 7,
    "axes.linewidth": 0.5, "axes.edgecolor": "#888888",
    "xtick.color": "#555555", "ytick.color": "#555555",
    "xtick.major.width": 0.5, "ytick.major.width": 0.5,
    "xtick.minor.width": 0.4, "ytick.minor.width": 0.4,
    "axes.spines.top": False, "axes.spines.right": False,
    "grid.color": "#e6e6e6", "grid.linewidth": 0.4,
})


def read(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def kdocs(n):
    return f"{n // 1000}k" if n >= 1000 else str(n)


def series(rows, col):
    return sorted((int(r["n"]), num(r[col])) for r in rows if num(r[col]))


def sizes_figure():
    fig, grid = plt.subplots(2, 2, figsize=(6.3, 3.9), sharex="col",
                             gridspec_kw=dict(height_ratios=[1.6, 1]))
    for col, (key, title) in enumerate(DATASETS):
        ax, rax = grid[0][col], grid[1][col]
        default = read(os.path.join(HERE, f"results_tfidf_{key}.csv"))
        py = dict(series(default, "py_s"))
        lines = [(series(default, "sql_s"), r"\textsc{HadathSQL} (PostgreSQL's default parallel workers)", HADATH),
                 (sorted(py.items()), "scikit-learn (1 thread)", SKLEARN)]
        ns = sorted({n for pts, _, _ in lines for n, _ in pts})
        for pts, label, style in lines:
            if pts:
                ax.plot(*zip(*pts), label=label, linewidth=1.3, markersize=3.5, **style)
        # Lead of HadathSQL: scikit-learn's time divided by HadathSQL's (1 = equal).
        for pts, label, style in lines[:1]:
            lead = [(n, py[n] / t) for n, t in pts if n in py and t]
            if lead:
                rax.plot(*zip(*lead), linewidth=1.3, markersize=3.5, **style)
        rax.axhline(1, color="#888888", linewidth=0.6)
        ax.set_yscale("log")
        ax.set_title(title, pad=3)
        for a_ in (ax, rax):
            a_.set_xscale("log", base=2)
            a_.grid(True, which="major", axis="y")
            a_.tick_params(which="minor", left=False, bottom=False)
        rax.set_ylim(bottom=0)
        ticks = [n for n in ns if n in (125, 1000, 8000, 64000, 256000, 1024000)]
        rax.set_xticks(ticks)
        rax.set_xticklabels([kdocs(n) for n in ticks])
        rax.set_xlabel("documents")
    grid[0][0].set_ylabel("time (s)")
    grid[1][0].set_ylabel("lead of \\textsc{HadathSQL}\n(scikit-learn time / its time)")
    handles, labels = grid[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=2, frameon=False, bbox_to_anchor=(0.5, 1.03))
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(os.path.join(OUT, "tfidf_sizes.pdf"), bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    sizes_figure()
    print("wrote tfidf_sizes.pdf in", os.path.normpath(OUT))
