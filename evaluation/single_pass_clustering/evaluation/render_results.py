#!/usr/bin/env python3
"""Regenerate the results sections of ABLATION.md and COMPARISON.md from the
results_*.csv files.

The section between the RESULTS:BEGIN and RESULTS:END markers is replaced with one
table per (setting, threshold): clustering time in seconds for each method.
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BEGIN, END = "<!-- RESULTS:BEGIN -->", "<!-- RESULTS:END -->"
LIGHT = [("d1_s", "Basic"), ("d2_s", "Mean + indexed"), ("driver_s", "HadathSQL"), ("cte-array_s", "Array CTE (non-standard)"), ("cte-standard_s", "Standard SQL CTE")]
DRIVERS = [("d1_s", "Basic"), ("sum_s", "Summed"), ("sumidx_s", "Summed + indexed"), ("sumidxp_s", "Summed + indexed + prepared"), ("d2_s", "Mean + indexed"), ("driver_s", "HadathSQL")]


def fmt(v):
    if v in ("NA", "", None):
        return "–"
    if v == "TIMEOUT":
        return "> limit"
    try:
        return f"{float(v):.2f}"
    except ValueError:
        return v


# Current setting names first; the runs before 2026-10-22 used "tweets" and "news".
SETTINGS = [("synthetic_tweets", "Synthetic-Tweets"), ("synthetic_news", "Synthetic-News"),
            ("tweets", "Tweets (synthetic)"), ("news", "News (synthetic)")]


def section(prefix, methods, title, note):
    out = []
    for setting, label in SETTINGS:
        path = os.path.join(HERE, f"{prefix}{setting}.csv")
        if not os.path.exists(path):
            continue
        with open(path) as f:
            rows = list(csv.DictReader(f))
        if not rows:
            continue
        if not out:
            out += [f"### {title}\n", note + "\n"]
        out.append(f"#### {label}\n")
        for th in sorted({r["threshold"] for r in rows}, key=float):
            sub = sorted((r for r in rows if r["threshold"] == th), key=lambda r: int(r["n"]))
            out.append(f"**Threshold {th}**\n")
            load = "load_start" in rows[0]
            out.append("| docs | clusters | TF-IDF | " + " | ".join(m for _, m in methods) + " | mismatches |"
                       + (" load (start / end) |" if load else ""))
            out.append("|---:|---:|---:|" + "---:|" * len(methods) + "---:|" + ("---:|" if load else ""))
            for r in sub:
                cells = [r["n"], r["clusters"], fmt(r["tfidf_s"])] + [fmt(r.get(k)) for k, _ in methods] + [r["mismatches"]]
                if load:
                    cells.append(f"{r['load_start']} / {r['load_end']}")
                out.append("| " + " | ".join(cells) + " |")
            out.append("")
    return out


ABLATION = [("driver_s", "HadathSQL"), ("noidx_s", "without indexes"), ("mean_s", "without summed centroids"),
         ("noprep_s", "without prepared statements"),
            ("noopt_s", "without all three")]
CTE = [("cte-standard_s", "Standard SQL CTE"), ("driver_s", "HadathSQL (reference)")]


NOTE3 = "Median of up to 3 runs per point (single run when a run takes 60 s or more)."


def ablation_tables():
    out = section("results_ablation_", ABLATION, "Ablation of the HadathSQL driver",
                  "Settings in ablation.conf. The HadathSQL driver and its ablation variants "
                  "(each without one optimization). " + NOTE3)
    out += section("results_sumidx_prepared_", DRIVERS[2:4], "Preliminary: summed + indexed vs summed + indexed + prepared", NOTE3)
    out += section("results_summed_indexed_", DRIVERS[1:3], "Preliminary: summed vs summed + indexed driver", NOTE3)
    out += section("results_basic_summed_", DRIVERS[:2], "Preliminary: basic vs summed driver", NOTE3)
    out += section("results_drivers_", DRIVERS, "Preliminary: driver experiment (all drivers)",
                   NOTE3 + " Drivers after the changes of 2026-10-18.")
    out += section("results_", LIGHT, "Preliminary: light run (before the changes of 2026-10-18; D3 column omitted)",
                   "Single run per point; measured before the changes of 2026-10-18.")
    return out


def comparison_tables():
    out = section("results_comparison_cte_", CTE, "Standard SQL CTE vs HadathSQL driver",
                  "Settings in comparison_cte.conf (smaller data than the ablation). " + NOTE3)
    out += section("results_cte_laptop_partial_", CTE, "Preliminary: Standard SQL CTE, partial laptop run",
                   "Run on the laptop, 2026-10-20; stopped when the laptop shut down. To be redone on the remote server.")
    return out


FILES = {"ABLATION.md": ablation_tables, "COMPARISON.md": comparison_tables}


def main():
    for name, tables in FILES.items():
        path = os.path.join(HERE, name)
        with open(path) as f:
            text = f.read()
        out = tables()
        a, b = text.index(BEGIN) + len(BEGIN), text.index(END)
        text = text[:a] + "\n" + ("\n".join(out) if out else "_No results yet._") + "\n" + text[b:]
        with open(path, "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()
