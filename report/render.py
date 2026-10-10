#!/usr/bin/env python3
"""render.py -- results/*/summary.json -> index.html. No number is typed in this file.

Every figure comes from a summary.json written by bench/perf-compare.py, so the
page rebuilds from committed data alone. Standard library only.

Usage: report/render.py [results dir] [output html]
"""
import glob
import html
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "results")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "index.html")

WORKLOAD_TITLE = {
    "drupal-front": "Front page, anonymous (page-cache hit)",
    "drupal-auth": "Front page, authenticated (page cache bypassed)",
}


def esc(v):
    return html.escape("" if v is None else str(v))


def load_summaries():
    out = []
    for path in sorted(glob.glob(os.path.join(RESULTS, "*", "summary.json"))):
        try:
            with open(path, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        d["_path"] = os.path.relpath(path, RESULTS)
        out.append(d)
    return out


def metric_rows(d):
    """One row per ab-phase metric: A, B, delta, CI, null band, verdict."""
    rows = []
    for r in d.get("results", []):
        if r.get("phase") != "ab":
            continue
        rows.append(r)
    return rows


def null_lines(d):
    return [r for r in d.get("results", []) if r.get("phase") == "null"]


def render_one(d):
    m = d.get("meta", {})
    title = WORKLOAD_TITLE.get(m.get("workload"), m.get("workload", "?"))
    h = []
    h.append(f'<h2 id="{esc(d.get("run_id"))}">{esc(title)} — {esc(m.get("runtime_a"))} vs {esc(m.get("runtime_b"))}</h2>')
    h.append(f'<p class="meta">{esc(m.get("site"))} · {esc(m.get("date"))} · '
             f'server CPUs {esc(m.get("server_cpus"))} · DB CPUs {esc(m.get("db_cpus"))} · '
             f'governor {esc(m.get("governor"))} · kernel {esc(m.get("kernel"))} · '
             f'cells {esc(m.get("reps"))} blocks × 8 · {esc(m.get("conns"))} connections · '
             f'{esc(m.get("dur"))} s window</p>')
    h.append(f'<p class="headline">{esc(d.get("headline"))}</p>')
    h.append('<table><thead><tr><th>metric</th><th>'
             f'{esc(m.get("runtime_a"))}</th><th>{esc(m.get("runtime_b"))}</th>'
             '<th>delta</th><th>95% CI</th><th>null band</th><th>cells agree</th><th>verdict</th>'
             '</tr></thead><tbody>')
    for r in metric_rows(d):
        h.append("<tr>"
                 f'<td>{esc(r.get("description") or r.get("metric"))}</td>'
                 f'<td>{esc(round(r.get("a_mean", 0), 4))}</td>'
                 f'<td>{esc(round(r.get("b_mean", 0), 4))}</td>'
                 f'<td>{esc(round(r.get("delta_pct", 0), 2))}%</td>'
                 f'<td>[{esc(round(r.get("ci_low", 0), 2))}, {esc(round(r.get("ci_high", 0), 2))}]</td>'
                 f'<td>{esc(round(r.get("null_band_pct", 0), 2))}</td>'
                 f'<td>{esc(r.get("cells_agree"))}/{esc(r.get("cells_total"))}</td>'
                 f'<td>{esc(r.get("verdict"))}</td></tr>')
    h.append("</tbody></table>")
    nulls = null_lines(d)
    if nulls:
        h.append("<details><summary>null phase (A against a copy of A)</summary><ul>")
        for r in nulls:
            h.append(f'<li>{esc(r.get("line"))}</li>')
        h.append("</ul></details>")
    h.append(f'<p class="data">raw: <code>{esc(d.get("_path", ""))}</code></p>')
    return "\n".join(h)


def main():
    summaries = load_summaries()
    body = "\n".join(render_one(d) for d in summaries) or "<p>No results yet.</p>"
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Drupal on Apache, nginx+PHP-FPM and FreeUnit</title>
<style>
 body {{ font: 15px/1.5 system-ui, sans-serif; max-width: 60rem; margin: 2rem auto; padding: 0 1rem; color: #222; }}
 h1 {{ font-size: 1.6rem; }} h2 {{ font-size: 1.15rem; margin-top: 2.5rem; border-top: 1px solid #ddd; padding-top: 1rem; }}
 table {{ border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; font-size: 14px; }}
 th, td {{ text-align: right; padding: .3rem .5rem; border-bottom: 1px solid #eee; }}
 th:first-child, td:first-child {{ text-align: left; }}
 .meta, .data {{ color: #666; font-size: 13px; }}
 .headline {{ font-weight: 600; }}
 .note {{ background: #f6f8fa; border-left: 3px solid #888; padding: .6rem .9rem; }}
 code {{ background: #f6f8fa; padding: .1rem .3rem; }}
</style></head><body>
<h1>Drupal on Apache, nginx + PHP-FPM and FreeUnit</h1>
<p class="note">Every page is built from committed <code>results/&lt;run-id&gt;/summary.json</code> files.
The null band is printed beside every comparison; a CLAIM only appears when the delta is outside it.
Read the null phase before the delta. Host class, governor, PHP, Drupal tag and runtime versions are in each run's header.</p>
{body}
<p class="data">Rendered {esc(__import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))}.</p>
</body></html>
"""
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(page)
    print(f"render.py: {len(summaries)} summaries -> {OUT}")


main()
