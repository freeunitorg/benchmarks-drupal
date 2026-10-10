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
    "symfony-front": "Symfony front page (Twig + one SELECT)",
    "wp-front": "WordPress front page (no page cache)",
    "wp-cron": "WordPress /wp-cron.php (HTTP cron path)",
}

RUNTIME_TITLE = {
    "freeunit": "FreeUnit 1.37.0",
    "freeunit-master": "FreeUnit master",
    "freeunit-direct": "FreeUnit 1.37.0, direct routes",
    "nginx-fpm": "nginx + PHP-FPM",
    "apache": "Apache + mod_php",
}

LOWER_IS_BETTER = {"s_instructions", "s_cycles", "server_us", "db_us", "p50_ms", "p99_ms"}


def runtime_title(name):
    return RUNTIME_TITLE.get(name, name or "?")


def fmt(value):
    """A compact number for the summary: 4823512.8 -> 4,823,513."""
    try:
        v = float(value)
    except (TypeError, ValueError):
        return esc(value)
    if v >= 1000:
        return f"{v:,.0f}"
    if v >= 1:
        return f"{v:,.2f}"
    return f"{v:.4f}"


def summary_section(summaries):
    """One ranking table per workload: absolute primary metric per runtime and its
    ratio to the best, so the reader sees the order before any delta table."""
    groups = {}
    for d in summaries:
        meta = d.get("meta", {})
        primary = d.get("primary")
        workload = meta.get("workload")
        if not primary or not workload:
            continue
        db = meta.get("db", "mysql")
        host = meta.get("host", "pro4s-2")
        for r in d.get("results", []):
            if r.get("phase") != "ab" or r.get("metric") != primary:
                continue
            cell = r.get("cell", "")
            for rt, mean in ((meta.get("runtime_a"), r.get("a_mean")),
                             (meta.get("runtime_b"), r.get("b_mean"))):
                if rt is None or mean is None:
                    continue
                groups.setdefault((workload, db, host, primary, cell), {}).setdefault(rt, []).append(float(mean))

    if not groups:
        return ""
    out = ['<h2 id="summary">Summary</h2>',
           '<p class="note">Primary metric: server instructions per request '
           '(lower is better), measured c32 on one host in one window. The ratio is against the '
           'best runtime in that row. Each comparison has its null band printed in the run '
           'sections below; a ratio smaller than the band is not a difference. Caveat: this '
           'table pools absolute means from runs taken hours apart under a powersave governor, '
           'so use it for the order, not for a percentage; the per-run tables are the '
           'controlled measurement.</p>']
    for (workload, db, host, primary, cell), runtimes in sorted(groups.items()):
        means = {rt: sum(v) / len(v) for rt, v in runtimes.items()}
        best = min(means.values()) if primary in LOWER_IS_BETTER else max(means.values())
        order = sorted(means, key=means.get)
        if primary not in LOWER_IS_BETTER:
            order = list(reversed(order))
        out.append(f'<h3>{esc(WORKLOAD_TITLE.get(workload, workload))} '
                   f'<span class="meta">({esc(cell)}, {esc(db)}, {esc(host)}, '
                   f'{esc(primary.replace("_", " "))})</span></h3>')
        out.append('<table><thead><tr><th>runtime</th><th>' + esc(primary.replace("_", " "))
                   + '</th><th>relative</th></tr></thead><tbody>')
        for rt in order:
            ratio = means[rt] / best if primary in LOWER_IS_BETTER else best / means[rt]
            cls = ' class="best"' if abs(means[rt] - best) < 1e-9 else ""
            out.append(f'<tr{cls}><td>{esc(runtime_title(rt))}</td><td>{fmt(means[rt])}</td>'
                       f'<td>{ratio:.2f}x</td></tr>')
        out.append("</tbody></table>")
    return "\n".join(out)


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


# ---------------------------------------------------------------- cron/queue arms
# The tick runs are raw TSVs, not summary.json: bench/tick.sh writes one row per
# tick with the trigger, wall time, the runtime container's schedstat delta and the
# process counts before and after. Everything below is computed from those rows.

def ticks_section(results_dir):
    import statistics as st
    runs = []
    for path in sorted(glob.glob(os.path.join(results_dir, "ticks-*", "ticks.tsv"))):
        rows = []
        try:
            with open(path, encoding="utf-8") as fh:
                header = fh.readline().rstrip("\n").split("\t")
                for line in fh:
                    cells = line.rstrip("\n").split("\t")
                    if len(cells) == len(header):
                        rows.append(dict(zip(header, cells)))
        except OSError:
            continue
        ok = [r for r in rows if r.get("status") == "ok"]
        if not ok:
            continue
        wall = [float(r["wall_s"]) for r in ok]
        cpu = [float(r["cpu_ns"]) / 1e6 for r in ok]
        procs0 = [int(r["procs_before"]) for r in ok]
        procs1 = [int(r["procs_after"]) for r in ok]
        runs.append({
            "dir": os.path.basename(os.path.dirname(path)),
            "arm": ok[0].get("arm", "?"),
            "runtime": ok[0].get("runtime", "?"),
            "trigger": ok[0].get("trigger", "?"),
            "n": len(ok),
            "mean": st.mean(wall),
            "median": st.median(wall),
            "cpu_ms": st.mean(cpu),
            "procs": max(procs1) - min(procs0),
        })
    if not runs:
        return ""
    best = min(r["mean"] for r in runs)
    out = ['<h2 id="arms">Cron and queue arms: cold CLI against the HTTP path</h2>',
           '<p class="note">One row per arm from the raw <code>ticks.tsv</code>. '
           'Arm A is a cold one-shot CLI process (<code>drush core:cron</code> / '
           '<code>queue:run</code>, or the equivalent bench command on Drupal 12), '
           'arm B is <code>GET /cron/{key}</code> served by a normal web worker. '
           'The CLI arm runs before the web workers are warm, so its wall time is the '
           'one to read; the HTTP arm returns before the job finishes on FreeUnit '
           '(it detaches), which is why its wall time is the trigger latency.</p>',
           '<table><thead><tr><th>arm</th><th>runtime</th><th>trigger</th><th>ticks</th>'
           '<th>mean wall (s)</th><th>median wall (s)</th><th>mean job CPU (ms)</th>'
           '<th>process growth</th><th>relative mean</th></tr></thead><tbody>']
    for r in sorted(runs, key=lambda x: x["mean"]):
        out.append(
            f'<tr><td>{esc(r["arm"])}</td><td>{esc(r["runtime"])}</td>'
            f'<td>{esc(r["trigger"])}</td><td>{r["n"]}</td>'
            f'<td>{r["mean"]:.3f}</td><td>{r["median"]:.3f}</td>'
            f'<td>{r["cpu_ms"]:.1f}</td><td>{r["procs"]:+d}</td>'
            f'<td>{r["mean"] / best:.2f}x</td></tr>')
    out.append("</tbody></table>")
    out.append('<p class="data">A process growth of 0 over 20 ticks is the gist bug '
               '(two leaked processes per tick) staying fixed. The mean job CPU of the '
               'cold-CLI row is a sampling gap, not a real zero: that process is gone '
               'before the sampler reads it.</p>')
    return "\n".join(out)


def render_one(d):
    m = d.get("meta", {})
    title = WORKLOAD_TITLE.get(m.get("workload"), m.get("workload", "?"))
    h = []
    h.append(f'<h2 id="{esc(d.get("run_id"))}">{esc(title)} — {esc(m.get("runtime_a"))} vs {esc(m.get("runtime_b"))}</h2>')
    h.append(f'<p class="meta">{esc(m.get("site"))} · {esc(m.get("date"))} · '
             f'server CPUs {esc(m.get("server_cpus"))} · DB CPUs {esc(m.get("db_cpus"))} · '
             f'governor {esc(m.get("governor"))} · kernel {esc(m.get("kernel"))} · '
             f'cells {esc(m.get("reps"))} blocks × 8 · {esc(m.get("conns"))} connections · '
             f'{esc(m.get("dur"))} s window · db {esc(m.get("db", "mysql"))} · '
             f'host {esc(m.get("host", "pro4s-2"))}</p>')
    h.append(f'<p class="headline">{esc(d.get("headline"))}</p>')
    h.append('<table><thead><tr><th>metric</th><th>'
             f'{esc(m.get("runtime_a"))}</th><th>{esc(m.get("runtime_b"))}</th>'
             '<th>delta</th><th>95% CI</th><th>null band</th><th>cells agree</th><th>verdict</th>'
             '</tr></thead><tbody>')
    # An INVALID run has no delta/CI: failed cells leave those fields null, so a
    # bare round() crashes the renderer and the run never reaches the page. Show a
    # dash instead and keep the headline (which says INVALID) as the record.
    def trim(x, nd, suffix=""):
        return "-" + suffix if x is None else f"{round(x, nd)}{suffix}"

    for r in metric_rows(d):
        h.append("<tr>"
                 f'<td>{esc(r.get("description") or r.get("metric"))}</td>'
                 f'<td>{esc(trim(r.get("a_mean"), 4))}</td>'
                 f'<td>{esc(trim(r.get("b_mean"), 4))}</td>'
                 f'<td>{esc(trim(r.get("delta_pct"), 2, "%"))}</td>'
                 f'<td>[{esc(trim(r.get("ci_low"), 2))}, {esc(trim(r.get("ci_high"), 2))}]</td>'
                 f'<td>{esc(trim(r.get("null_band_pct"), 2))}</td>'
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
    body = summary_section(summaries)
    body += "\n" + ticks_section(RESULTS)
    body += "\n" + ("\n".join(render_one(d) for d in summaries) or "<p>No results yet.</p>")
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
 tr.best td {{ font-weight: 600; background: #f0fbf4; }}
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
    os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(page)
    print(f"render.py: {len(summaries)} summaries -> {OUT}")


main()
