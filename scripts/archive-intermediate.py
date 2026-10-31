#!/usr/bin/env python3
"""Move runs that measured an intermediate FreeUnit build out of results/.

The published page compares releases with each other and with the other servers.
A run is kept in results/ only when both of its runtimes are a release build or a
non-FreeUnit server; any run with a master, tip, PR or bisect image goes to
results-archive/, which the renderer does not read.  Nothing is deleted: the
archive stays in git, and collect.sh will not pull an archived run back.

    scripts/archive-intermediate.py           # list what would move
    scripts/archive-intermediate.py --apply   # git mv it
"""
import glob, json, os, subprocess, sys

# Release FreeUnit builds (tarball of a tag) and the servers it is compared with.
RELEASE = {
    "freeunit", "freeunit-direct", "freeunit-1371", "freeunit-musl",
    "freeunit-python-1370",
    "nginx-fpm", "nginx-src", "angie-fpm", "freenginx-fpm", "apache",
    "gunicorn", "uvicorn",
}

def main():
    apply = "--apply" in sys.argv
    os.makedirs("results-archive", exist_ok=True) if apply else None
    moved = kept = 0
    for p in sorted(glob.glob("results/*/summary.json")):
        run = p.split("/")[1]
        try:
            m = json.load(open(p)).get("meta", {})
        except ValueError:
            continue
        rts = {m.get("runtime_a"), m.get("runtime_b")} - {None, ""}
        other = sorted(rts - RELEASE)
        if not other:
            kept += 1
            continue
        moved += 1
        print(f"archive {run}  ({', '.join(other)})")
        if apply:
            subprocess.run(["git", "mv", f"results/{run}", f"results-archive/{run}"], check=True)
    print(f"{moved} to archive, {kept} kept", file=sys.stderr)

if __name__ == "__main__":
    main()
