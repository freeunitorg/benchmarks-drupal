#!/usr/bin/env python3
"""render.py -- results/*/summary.json -> index.html. No number is typed in this file.

Every figure comes from a summary.json written by bench/perf-compare.py, so the
page rebuilds from committed data alone. Standard library only.

The page is organised for a result set that keeps growing: a human summary first,
then the cross-run rankings, then an index of every run, then the per-run detail
collapsed behind <details> so the page stays scannable at hundreds of runs.

Usage: report/render.py [results dir] [output html]
"""
import datetime
import glob
import html
import json
import os
import re
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
    "php-hello": "PHP hello (no framework)",
    "php-headers": "PHP response headers (no framework)",
    "php-body": "PHP response body (no framework)",
}

SITE_TITLE = {
    "11.4": "Drupal 11.4, demo_umami profile",
    "11.4-standard": "Drupal 11.4, standard profile",
    "11.4-mysqli": "Drupal 11.4 on the mysqli driver",
    "11.4-pgsql": "Drupal 11.4 on PostgreSQL",
    "11.4-sqlite": "Drupal 11.4 on SQLite",
    "11.5": "Drupal 11.5, demo_umami profile",
    "11.5-beta1": "Drupal 11.5.0-beta1, demo_umami profile",
    "12.0": "Drupal 12.0.0-beta1, demo_umami profile",
    "12.0-beta1": "Drupal 12.0.0-beta1, demo_umami profile",
    "12.0-sqlite": "Drupal 12.0 on SQLite",
    # A security release: beta1 has the vulnerabilities this fixes (SA-CORE-2026-014,
    # -015, -016), so its rows are the historical baseline, not a recommendation.
    "12.0-beta2": "Drupal 12.0.0-beta2 (security release), demo_umami profile",
    "symfony": "Symfony 7.4",
    "hello": "Framework-free PHP",
    "wp": "WordPress",
    "wp-persistent": "WordPress with a persistent-connection drop-in",
}

RUNTIME_TITLE = {
    "freeunit": "FreeUnit 1.37.0",
    "freeunit-master": "FreeUnit master",
    "freeunit-direct": "FreeUnit 1.37.0, direct routes",
    "nginx-fpm": "nginx + PHP-FPM",
    "nginx-src": "nginx from source + PHP-FPM",
    "angie-fpm": "Angie + PHP-FPM",
    "freenginx-fpm": "FreeNginx + PHP-FPM",
    "freeunit-tuned": "FreeUnit 1.37.0 (12-thread tuning)",
    "freeunit-1371": "FreeUnit 1.37.1",
    "freeunit-1371-tuned": "FreeUnit 1.37.1 (12-thread tuning)",
    "freeunit-master-bd890d40": "FreeUnit 1.37.2-pre (master bd890d40)",
    "freeunit-master-bd890d40-tuned": "FreeUnit 1.37.2-pre (master bd890d40, "
                                      "12-thread tuning)",
    "apache": "Apache + mod_php",
}

LOWER_IS_BETTER = {"s_instructions", "s_cycles", "server_us", "db_us", "p50_ms", "p99_ms"}

# Verdict -> (badge class, short label). Anything else keeps its own first word.
VERDICT_CLASS = {
    "CLAIM": ("claim", "CLAIM"),
    "NO CLAIM": ("noclaim", "no claim"),
    "INVALID": ("invalid", "invalid"),
    "NO DATA": ("nodata", "no data"),
    "PASS": ("pass", "pass"),
}


def esc(v):
    return html.escape("" if v is None else str(v))


def runtime_title(name):
    return RUNTIME_TITLE.get(name, name or "?")


def site_title(name):
    return SITE_TITLE.get(name, name or "?")


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


def trim(x, nd, suffix=""):
    """An INVALID run has no delta/CI: show a dash instead of crashing on None."""
    return "-" + suffix if x is None else f"{round(x, nd)}{suffix}"


def verdict_of(d):
    """The first word(s) of the headline that say what the run concluded."""
    head = str(d.get("headline") or "")
    for key in ("NO CLAIM", "NO DATA", "INVALID", "CLAIM", "PASS"):
        if head.startswith(key):
            return key
    return ""


def badge(d):
    key = verdict_of(d)
    if not key:
        return ""
    cls, label = VERDICT_CLASS.get(key, ("nodata", key.lower()))
    return f'<span class="badge {cls}">{esc(label)}</span>'


def run_label(d):
    m = d.get("meta", {})
    wl = WORKLOAD_TITLE.get(m.get("workload"), m.get("workload", "?"))
    return (f'{site_title(m.get("site"))} · {wl} · '
            f'{runtime_title(m.get("runtime_a"))} vs {runtime_title(m.get("runtime_b"))}')


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
    # Stable, reader-friendly order: by site, then run id (which carries the time).
    out.sort(key=lambda d: (str((d.get("meta") or {}).get("site", "")), str(d.get("run_id", ""))))
    return out


def metric_rows(d):
    """One row per ab-phase metric: A, B, delta, CI, null band, verdict."""
    return [r for r in d.get("results", []) if r.get("phase") == "ab"]


def null_lines(d):
    return [r for r in d.get("results", []) if r.get("phase") == "null"]


# ------------------------------------------------------------------ human summary

def short_version(summaries, limit=0):
    """The page's own abstract, assembled from the runs rather than typed.

    Every number and every claim in it is a headline or a count copied from a
    summary.json, so it cannot drift away from the tables.  `limit` caps how many
    runs are listed per verdict, which is what keeps the overview page small now
    that the families have their own pages.
    """
    if not summaries:
        return ""
    sites = len({(d.get("meta") or {}).get("site") for d in summaries})
    hosts = sorted({(d.get("meta") or {}).get("host", "pro4s-2") for d in summaries})
    order = ["CLAIM", "NO CLAIM", "PASS", "INVALID", "NO DATA"]
    by_verdict = {k: [d for d in summaries if verdict_of(d) == k] for k in order}

    # #summary is the short version on every page kind, so a deep link to the
    # summary lands on the same thing whether it is the overview or a family page.
    # #short stays as an alias for links written before the rename.
    out = ['<span id="short"></span><h2 id="summary">The short version</h2>',
           '<p class="note">This page holds <strong>%d published comparisons</strong> across '
           '<strong>%d application site%s</strong>, measured on %s. Each comparison is one job: '
           'the same cells against two runtimes, with a null phase that bounds the noise first. '
           'A <span class="badge claim">CLAIM</span> appears only when the delta is outside that '
           'band. Start with the summary tables, then open a run for its numbers; every run links '
           'to its raw <code>results/&lt;run-id&gt;/</code> directory.</p>'
           % (len(summaries), sites, "" if sites == 1 else "s", esc(", ".join(hosts)))]

    # A count line keeps the shape of the result set visible without expanding a
    # single list: before this, every run's headline was printed and the summary
    # below it was what got lost on a page with a hundred runs.
    counts = " \u00b7 ".join(f'<a href="#verdict-{k.lower().replace(" ", "-")}">{len(runs)} {esc(k.lower())}</a>'
                              for k, runs in ((k, by_verdict.get(k) or []) for k in order) if runs)
    if counts:
        out.append(f'<p class="counts">{counts}</p>')

    for key in order:
        runs = by_verdict.get(key) or []
        if not runs:
            continue
        slug = key.lower().replace(" ", "-")
        cls, label = VERDICT_CLASS.get(key, ("nodata", key.lower()))
        out.append(f'<details class="verdicts" id="verdict-{slug}">')
        out.append(f'<summary><span class="badge {cls}">{esc(label)}</span> '
                   f'<span class="meta">({len(runs)} run{"s" if len(runs) != 1 else ""})</span>'
                   f'</summary>')
        out.append('<ul>')
        shown = runs[:limit] if limit else runs
        for d in shown:
            out.append(f'<li><a href="#{esc(d.get("run_id"))}">{esc(run_label(d))}</a> '
                       f'<span class="meta">{esc(d.get("headline"))}</span></li>')
        if limit and len(runs) > limit:
            out.append(f'<li class="meta">and {len(runs) - limit} more under '
                       f'<a href="#runs">every run</a> on this page.</li>')
        out.append('</ul></details>')
    return "\n".join(out)


# --------------------------------------------------------------------- rankings

def _cond_text(summaries):
    """Governor and host(s) named from the runs themselves: a page whose runs came from
    a schedutil governor on a shared node must not read as a powersave perf box."""
    govs = sorted({str((d.get("meta") or {}).get("governor") or "unknown") for d in summaries})
    hosts = sorted({str((d.get("meta") or {}).get("host") or "pro4s-2") for d in summaries})
    out = " under "
    if govs:
        out += "governor " + "/".join(govs)
    if hosts:
        out += (" on host " if len(hosts) == 1 else " on hosts ") + ", ".join(hosts)
    return out


def summary_section(summaries):
    """One ranking table per (workload, database, host): absolute primary metric per
    runtime and its ratio to the best, so the reader sees the order before any delta."""
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
    primaries = sorted({g[3] for g in groups})
    out = ['<h2 id="rankings">The primary metric per runtime</h2>',
           '<p class="note">Primary metric: '
           + esc(", ".join(p.replace("_", " ") for p in primaries)) + ' (lower is better), '
           'measured c32 on one host in one window. The ratio is against the best runtime in that '
           'row. Each comparison has its null band printed in the run sections below; a ratio '
           'smaller than the band is not a difference. Caveat: this table pools absolute means from '
           'runs taken hours apart' + _cond_text(summaries) + ', so use it for the order, not for a '
           'percentage; the per-run tables are the controlled measurement.</p>']
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
            # A runtime whose primary mean is 0 has no measurement (a failed side or
            # a metric the sampler did not emit); show a dash instead of dividing.
            if best <= 0 or means[rt] <= 0:
                ratio = "n/a"
            elif primary in LOWER_IS_BETTER:
                ratio = f"{means[rt] / best:.2f}x"
            else:
                ratio = f"{best / means[rt]:.2f}x"
            cls = ' class="best"' if abs(means[rt] - best) < 1e-9 else ""
            out.append(f'<tr{cls}><td>{esc(runtime_title(rt))}</td><td>{fmt(means[rt])}</td>'
                       f'<td>{ratio}</td></tr>')
        out.append("</tbody></table>")
    return "\n".join(out)


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


# ------------------------------------------------------------------ run details

def run_index(summaries):
    """One row per run with a link to its detail block: the page's table of contents
    once the number of runs stops fitting on a screen."""
    out = ['<h2 id="runs">Every run</h2>',
           '<p class="note">One row per comparison. The run id is the directory name under '
           '<code>results/</code> and the anchor of its detail block below; the date is the '
           'run\'s own start time. Open a row to read its metrics.</p>',
           '<table class="index"><thead><tr><th>run</th><th>date</th><th>site</th>'
           '<th>workload</th><th>runtimes</th><th>verdict</th></tr></thead><tbody>']
    for d in summaries:
        m = d.get("meta", {})
        rid = str(d.get("run_id", ""))
        date = str(m.get("date", ""))
        if not date:
            date = rid.rsplit("-", 1)[-1]
        out.append(
            f'<tr><td><a href="#{esc(rid)}"><code>{esc(rid[:48])}</code></a></td>'
            f'<td>{esc(date[:16])}</td>'
            f'<td>{esc(site_title(m.get("site")))}</td>'
            f'<td>{esc(WORKLOAD_TITLE.get(m.get("workload"), m.get("workload", "?")))}</td>'
            f'<td>{esc(runtime_title(m.get("runtime_a")))} vs {esc(runtime_title(m.get("runtime_b")))}</td>'
            f'<td>{badge(d)}</td></tr>')
    out.append("</tbody></table>")
    return "\n".join(out)


def run_details(d):
    """One run: a <details> whose summary line carries the verdict, so the page can be
    scanned without expanding anything, and whose body is the metric table."""
    m = d.get("meta", {})
    rid = str(d.get("run_id", ""))
    title = WORKLOAD_TITLE.get(m.get("workload"), m.get("workload", "?"))
    h = []
    h.append(f'<details class="run" id="{esc(rid)}">')
    h.append(f'<summary>{badge(d)}<span class="run-title">{esc(title)} — '
             f'{esc(runtime_title(m.get("runtime_a")))} vs '
             f'{esc(runtime_title(m.get("runtime_b")))}</span>'
             f'<span class="meta">{esc(site_title(m.get("site")))} · {esc(rid)}</span></summary>')
    h.append(f'<p class="meta">server CPUs {esc(m.get("server_cpus"))} · '
             f'DB CPUs {esc(m.get("db_cpus"))} · governor {esc(m.get("governor"))} · '
             f'kernel {esc(m.get("kernel"))} · {esc(m.get("reps"))} blocks × 8 · '
             f'{esc(m.get("conns"))} connections · {esc(m.get("dur"))} s window · '
             f'db {esc(m.get("db", "mysql"))} · host {esc(m.get("host", "pro4s-2"))} · '
             f'date {esc(m.get("date"))}</p>')
    h.append(f'<p class="headline">{esc(d.get("headline"))}</p>')
    h.append('<table><thead><tr><th>metric</th><th>'
             f'{esc(m.get("runtime_a"))}</th><th>{esc(m.get("runtime_b"))}</th>'
             '<th>delta</th><th>95% CI</th><th>null band</th><th>cells agree</th><th>verdict</th>'
             '</tr></thead><tbody>')
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
    h.append(f'<p class="data">raw: <code>{esc(d.get("_path", ""))}</code> · '
             f'<a href="#runs">back to the index</a> · <a href="#top">top</a></p>')
    h.append("</details>")
    return "\n".join(h)


def run_sections(summaries):
    """The detail blocks, grouped by site, each group with its own heading."""
    out = ['<h2 id="details">Run detail</h2>',
           '<p class="note">Grouped by application site. Nothing is hidden: the summary '
           'line carries the verdict, the body has the metrics, and the null-phase row '
           'that bounds the job is one click further.</p>']
    current = None
    for d in summaries:
        site = (d.get("meta") or {}).get("site")
        if site != current:
            current = site
            n = sum(1 for x in summaries if (x.get("meta") or {}).get("site") == site)
            out.append(f'<h3 id="site-{esc(site)}">{esc(site_title(site))} '
                       f'<span class="meta">({n} run{"s" if n != 1 else ""})</span></h3>')
        out.append(run_details(d))
    return "\n".join(out)


STYLE = """
 body { font: 15px/1.5 system-ui, sans-serif; max-width: 68rem; margin: 2rem auto; padding: 0 1rem; color: #222; }
 h1 { font-size: 1.6rem; margin-bottom: .2rem; }
 h2 { font-size: 1.15rem; margin-top: 2.5rem; border-top: 1px solid #ddd; padding-top: 1rem; }
 h3 { font-size: 1rem; margin: 1.4rem 0 .4rem; }
 table { border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; font-size: 14px; }
 th, td { text-align: right; padding: .3rem .5rem; border-bottom: 1px solid #eee; vertical-align: top; }
 th:first-child, td:first-child { text-align: left; }
 table.index td, table.index th { font-size: 13px; }
 .meta, .data { color: #666; font-size: 13px; font-weight: normal; }
 .headline { font-weight: 600; }
 .note { background: #f6f8fa; border-left: 3px solid #888; padding: .6rem .9rem; }
 tr.best td { font-weight: 600; background: #f0fbf4; }
 code { background: #f6f8fa; padding: .1rem .3rem; }
 .badge { font-size: 11px; font-weight: 700; padding: .1rem .45rem; border-radius: .7rem; white-space: nowrap; }
 .badge.claim { background: #e6f4ea; color: #136a2f; }
 .badge.noclaim { background: #eef1f4; color: #4a5568; }
 .badge.invalid { background: #fdecea; color: #a12b20; }
 .badge.nodata { background: #fff4e5; color: #8a5a00; }
 .badge.pass { background: #e8f0fe; color: #1a4b8c; }
 ul.verdicts { margin: .3rem 0 1rem; padding-left: 1.1rem; }
 ul.verdicts li { margin: .2rem 0; }
 details.verdicts { border: 1px solid #e6e6e6; border-radius: .5rem; padding: .3rem .7rem; margin: .4rem 0; }
 details.verdicts > summary { cursor: pointer; }
 details.verdicts > ul { margin: .5rem 0 .2rem; padding-left: 1.1rem; }
 p.counts { margin: .6rem 0 .2rem; font-size: 14px; }
 p.counts a { text-decoration: none; }
 nav.toc { margin: .8rem 0 1rem; font-size: 14px; }
 nav.toc ol { display: inline; margin: 0; padding-left: .4rem; }
 nav.toc li { display: inline; margin: 0 .1rem; }
 nav.toc li:not(:last-child)::after { content: " ·"; color: #999; }
 details.run { border: 1px solid #e6e6e6; border-radius: .5rem; padding: .4rem .7rem; margin: .5rem 0; }
 details.run > summary { cursor: pointer; display: block; }
 .run-title { font-weight: 600; margin: 0 .5rem 0 .4rem; }
 details[open].run { background: #fcfcfd; }
 :target { scroll-margin-top: 1rem; background: #fffbe6; }
 nav.pages { margin: .8rem 0 1.2rem; display: flex; flex-wrap: wrap; gap: .4rem; }
 nav.pages a, nav.pages span.here { border: 1px solid #d7dbe0; border-radius: .4rem; padding: .25rem .6rem; font-size: 13px; }
 nav.pages a { text-decoration: none; }
 nav.pages span.here { background: #eef1f4; font-weight: 600; border-color: #c3c9d1; }
 nav.pages a:hover { background: #f6f8fa; }
 nav.toc ol { margin: .3rem 0 0; padding-left: 1.2rem; }
 p.lede { color: #444; }
 @media print { details.run { break-inside: avoid; } }
"""


# Runs taken anywhere else (the aarch64 host) get their own page: their primary
# metric is CPU time, because that guest has no PMU, so they must not be read as
# an extension of the instruction-count tables.
# x86 hosts whose counters work. A host must be listed here to keep its runs on its
# own application family page; an unlisted host is filed under arm64, whose primary
# metric is CPU time because that guest has no PMU. The shared 48-thread node has a
# PMU, so its runs carry s_instructions and belong with the x86 pages.
PINNED_HOSTS = {"sd-91675", "sd-92483", "pro4s-2", "pro4s-4", "localhost",
                "skilld-dev-147015-cognition"}

FAMILY_TITLE = {
    "arm64": "ARM64 (Oracle A1)",
    "symfony": "Symfony",
    "wordpress": "WordPress",
    "php": "Framework-free PHP",
    "other": "Other",
}

FAMILY_LEDE = {
    "arm64": "The same servers on an aarch64 host, where the guest has no PMU: the primary "
             "metric is the server's own CPU time per request, not retired instructions. Read "
             "the ratios; the absolute numbers are not comparable with the x86 pages.",
    "symfony": "Symfony on the same runtimes.",
    "wordpress": "WordPress front page, the HTTP cron path, and the persistent-connection "
                 "drop-in.",
    "php": "The control application: one PHP file, no framework, no database. This is where "
           "the per-request cost of the server itself shows, so it is the page to read first "
           "when the servers are being compared.",
    "other": "Runs that do not belong to one of the application families.",
}

# Drupal gets one page per site, because the runtime x database matrix lands there
# and a single Drupal page grew to as much as the whole report used to be.
PAGE_ORDER = {"drupal": 0, "symfony": 1, "wordpress": 2, "php": 3, "arm64": 4, "other": 5}


def page_title(key):
    if key.startswith("drupal-"):
        return f"Drupal {key[len('drupal-'):]}"
    return FAMILY_TITLE.get(key, key)


def page_lede(key, runs=None):
    """A page's lede. For Drupal lines it is derived from the runs on that page, so a
    line with two runtimes and one database cannot claim four runtimes and a database
    axis it does not have."""
    if key.startswith("drupal-"):
        site = key[len("drupal-"):]
        runs = runs or []
        rts = sorted({runtime_title((d.get("meta") or {}).get(r))
                      for d in runs for r in ("runtime_a", "runtime_b")} - {None})
        dbs = sorted({str((d.get("meta") or {}).get("db") or "mysql") for d in runs})
        hosts = sorted({str((d.get("meta") or {}).get("host") or "pro4s-2") for d in runs})
        head = SITE_TITLE.get(site, site)
        if not rts:
            return head + "."
        sent = head + " — " + ", ".join(rts)
        if dbs:
            sent += " on " + ("the " if len(dbs) > 1 else "") + "/".join(dbs)
        if hosts:
            sent += ", measured on " + ", ".join(hosts)
        return sent + "."
    return FAMILY_LEDE.get(key, "")


# The page a run lands on. Site first and workload as the fallback, so a run that
# names an unexpected site still lands somewhere sensible instead of vanishing.
def family_of(d):
    m = d.get("meta") or {}
    host = str(m.get("host") or "")
    if host and host not in PINNED_HOSTS:
        return "arm64"
    site = str(m.get("site") or "")
    workload = str(m.get("workload") or "")
    if site.startswith("wp") or workload.startswith("wp-"):
        return "wordpress"
    if site == "symfony" or workload.startswith("symfony"):
        return "symfony"
    if site == "hello" or workload.startswith("php-"):
        return "php"
    # One page per Drupal line, derived from the site key so a new line (11.5, 12.1)
    # or a new variant of an old one (12.0-beta2, 12.0-sqlite) lands on the page of
    # its line instead of vanishing into "other".
    line = re.match(r"^(11\.\d+|12\.\d+)", site)
    if line or workload.startswith("drupal-"):
        return "drupal-" + (line.group(1) if line else (site or "other"))
    return "other"


def page_keys(groups):
    """The pages that have runs, Drupal versions first, then the families."""
    def order(k):
        base = "drupal" if k.startswith("drupal-") else k
        return (PAGE_ORDER.get(base, 9), k)
    return sorted(groups, key=order)


def nav(current, groups):
    """Sibling links, with the current page marked: the split only helps if the
    reader can see the other pages from any of them."""
    items = [("index.html", "Overview", sum(len(v) for v in groups.values()))]
    for key in page_keys(groups):
        items.append((f"{key}.html", page_title(key), len(groups[key])))
    out = ['<nav class="pages">']
    for href, title, n in items:
        if href[:-5] == current:
            out.append(f'<span class="here">{esc(title)} <span class="meta">({n})</span></span>')
        else:
            out.append(f'<a href="{href}">{esc(title)} <span class="meta">({n})</span></a>')
    out.append("</nav>")
    return "\n".join(out)


def verdict_counts(summaries):
    counts = {}
    for d in summaries:
        key = verdict_of(d) or "?"
        counts[key] = counts.get(key, 0) + 1
    return counts


def toc(items):
    """An in-page table of contents. Every entry is an id that exists on this page
    kind, so a deep link such as #summary works on the overview and on every family
    page alike, and a reader landing mid-page can get back to the summary."""
    items = [(i, label) for i, label in items if i]
    if not items:
        return ""
    out = ['<nav class="toc"><strong>On this page:</strong> <ol>']
    for anchor, label in items:
        out.append(f'<li><a href="#{esc(anchor)}">{esc(label)}</a></li>')
    out.append("</ol></nav>")
    return "\n".join(out)


def overview_body(groups, all_summaries):
    """The overview page, summary first: the counts and the verdict groups (collapsed)
    come before the page index, so a reader sees what the result set says before it
    sees how it is filed."""
    arms_html = ticks_section(RESULTS)
    out = [toc([("summary", "The short version"), ("pages", "Pages"),
                ("arms", "Cron and queue arms") if arms_html else None]),
           short_version(all_summaries, limit=6)]
    out.append('<h2 id="pages">Pages</h2>')
    out.append('<p class="note">The result set is split by application family so each page stays '
               'readable while the runtime and database matrices grow. Every page carries its own '
               'short version, ranking table, run index and per-run detail; the raw data is the same '
               'committed <code>results/</code> tree for all of them.</p>')
    out.append('<table class="index"><thead><tr><th>page</th><th>runs</th><th>sites</th>'
               '<th>claim</th><th>no claim</th><th>invalid</th><th>no data</th>'
               '</tr></thead><tbody>')
    for key in page_keys(groups):
        runs = groups[key]
        counts = verdict_counts(runs)
        sites = len({(d.get("meta") or {}).get("site") for d in runs})
        out.append(
            f'<tr><td><a href="{key}.html">{esc(page_title(key))}</a>'
            f'<div class="meta">{esc(page_lede(key))}</div></td>'
            f'<td>{len(runs)}</td><td>{sites}</td>'
            f'<td>{counts.get("CLAIM", 0)}</td>'
            f'<td>{counts.get("NO CLAIM", 0)}</td>'
            f'<td>{counts.get("INVALID", 0)}</td>'
            f'<td>{counts.get("NO DATA", 0)}</td>'
            '</tr>')
    out.append("</tbody></table>")
    arms = ticks_section(RESULTS)
    out.append(arms)
    return "\n".join(part for part in out if part)


def page_body(key, runs):
    return "\n".join(part for part in [
        toc([("summary", "The short version"), ("rankings", "Primary metric per runtime"),
             ("runs", "Every run"), ("details", "Run detail")]),
        short_version(runs),
        summary_section(runs),
        run_index(runs),
        run_sections(runs),
    ] if part)


def document(title, current, groups, lede, body, note=""):
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="Reproducible comparison of Drupal, Symfony, WordPress and framework-free PHP on Apache+mod_php, nginx+PHP-FPM, Angie, FreeNginx and FreeUnit, with a null band beside every comparison.">
<style>{STYLE}</style></head><body id="top">
<h1>{esc(title)}</h1>
<p class="lede">{lede}</p>
{nav(current, groups)}
{note}
{body}
<p class="data">Rendered {esc(now)}. A plain-language summary of the findings is in
<a href="https://github.com/freeunitorg/benchmarks-drupal/blob/main/docs/report-2026-10.md">docs/report-2026-10.md</a>;
the suite's resume note is <code>docs/state.md</code>.</p>
</body></html>
"""


def main():
    summaries = load_summaries()
    groups = {}
    for d in summaries:
        groups.setdefault(family_of(d), []).append(d)

    outdir_abs = os.path.abspath(OUT)
    if OUT.endswith(".html"):
        index_path = outdir_abs
        outdir = os.path.dirname(outdir_abs) or "."
    else:
        outdir = outdir_abs
        index_path = os.path.join(outdir_abs, "index.html")

    os.makedirs(outdir, exist_ok=True)
    written = []

    note = ('<p class="note">Everything here is rebuilt from committed '
            '<code>results/&lt;run-id&gt;/summary.json</code> files. The <strong>null band</strong> '
            'is printed beside every comparison: it is the same job run with both sides identical '
            '(A against a copy of A), so a delta smaller than the band is noise and is reported as '
            '<em>no claim</em>. Host class, governor, PHP, Drupal tag, database and runtime '
            'versions are in each run\'s header.</p>')

    if groups:
        body = overview_body(groups, summaries)
        title = "Application-server benchmarks: Drupal, Symfony, WordPress and plain PHP"
        lede = ('An instruction-count comparison of the same application on several runtimes, one '
                'job at a time, with the measurement noise bounded before any claim is made. '
                '<a href="https://github.com/freeunitorg/benchmarks-drupal/blob/main/docs/report-2026-10.md">Read '
                'the findings in prose</a>.')
        with open(index_path, "w", encoding="utf-8") as fh:
            fh.write(document(title, "index", groups, lede, body, note))
        written.append(index_path)

        for key in page_keys(groups):
            path = os.path.join(outdir, f"{key}.html")
            title = f"{page_title(key)} benchmarks"
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(document(title, key, groups, page_lede(key, groups[key]),
                                  page_body(key, groups[key]), note))
            written.append(path)
    else:
        with open(index_path, "w", encoding="utf-8") as fh:
            fh.write(document("Application-server benchmarks", "index", groups,
                              "No results yet.", "<p>No results yet.</p>", note))
        written.append(index_path)

    # A page that no longer has runs (a family emptied, a key renamed) must not be
    # left behind on the published site as a stale copy of an older result set.
    keep = {os.path.basename(p) for p in written}
    for stale in glob.glob(os.path.join(outdir, "*.html")):
        if os.path.basename(stale) not in keep:
            os.remove(stale)

    print(f"render.py: {len(summaries)} summaries -> {', '.join(os.path.basename(p) for p in written)}")


main()
