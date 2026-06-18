#!/usr/bin/env python3
"""rust-quality.py — measure Rust quality-rule violations + cross-file duplication.

Read-only static analysis to drive the data-plane refactor (less repetition, more
quality). Zero deps (stdlib only). Two reports:

  1. Per-file rule violations vs .claude/rules/refactor-rust.md & refactor-common.md:
       file > 300 lines, fn body > 40 lines, and counts of unwrap/expect/clone/
       unsafe/panic!/#[allow]/TODO. unwrap & expect are split test vs NON-test
       (only non-test unwrap/expect violate the rule).
  2. Cross-file duplication via k-line shingling: consecutive non-blank/non-comment
     lines are whitespace-normalized and hashed in sliding windows of K; windows
     recurring across >=2 distinct locations are reported, ranked by duplicated-line
     volume. This surfaces copy-paste (strip_reserved_top_level, owner_of, ...).

# ponytail: brace/fn-length & test-region detection are depth-counting heuristics
#   (they don't parse strings/char-literals/macros) — a SIGNAL, not a proof. Good
#   enough to rank targets; verify a specific hit by reading the range.

Usage:
  python3 scripts/report/rust-quality.py <dir> [--k 6] [--top 30] [--json OUT]
  python3 scripts/report/rust-quality.py src/data-plane-router/crates/data-plane-pool/src
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict

FN_RE = re.compile(r"^\s*(pub\s*(\([^)]*\)\s*)?)?(async\s+)?(unsafe\s+)?(const\s+)?(extern\s+\"[^\"]*\"\s+)?fn\s+\w+")
SMELLS = {
    "unwrap": re.compile(r"\.unwrap\s*\("),
    "expect": re.compile(r"\.expect\s*\("),
    "clone": re.compile(r"\.clone\s*\("),
    "panic": re.compile(r"\b(panic|unimplemented|todo)\s*!"),
    "unsafe": re.compile(r"\bunsafe\b"),
    "allow": re.compile(r"#\[allow\("),
    "todo": re.compile(r"\b(TODO|FIXME|XXX|HACK)\b"),
}
FILE_MAX, FN_MAX = 300, 40
WS = re.compile(r"\s+")


def rs_files(root):
    if os.path.isfile(root):
        return [root]
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ("target", ".git")]
        out += [os.path.join(dirpath, f) for f in files if f.endswith(".rs")]
    return sorted(out)


def open_brace_delta(line):
    """Net brace depth change on a line (heuristic — ignores strings/comments)."""
    return line.count("{") - line.count("}")


def scan_file(path):
    """Per-file metrics: loc, long functions, and test-split smell counts."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    loc = len(lines)
    counts = defaultdict(int)
    counts_test = defaultdict(int)
    long_fns = []

    depth = 0
    test_floor = None  # brace depth at which a #[cfg(test)] region opened
    pending_test_attr = False
    fn_stack = []  # (name_line, start_line, open_depth)

    for i, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        stripped = line.strip()
        in_test = test_floor is not None

        # smell counts (test vs non-test for unwrap/expect)
        for name, rx in SMELLS.items():
            n = len(rx.findall(line))
            if not n:
                continue
            if name in ("unwrap", "expect") and in_test:
                counts_test[name] += n
            else:
                counts[name] += n

        # track #[cfg(test)] regions
        if "#[cfg(test)]" in stripped:
            pending_test_attr = True

        # function-length tracking (open at the line's first '{')
        if FN_RE.match(line) and "{" in line and test_floor is None:
            fn_name = re.search(r"fn\s+(\w+)", line)
            fn_stack.append((fn_name.group(1) if fn_name else "?", i, depth))

        delta = open_brace_delta(line)
        if delta > 0 and pending_test_attr and "mod" in stripped:
            test_floor = depth  # region body lives above this depth
            pending_test_attr = False
        depth += delta
        if depth < 0:
            depth = 0
        if test_floor is not None and depth <= test_floor:
            test_floor = None

        # close any fns whose body returned to/under their open depth
        while fn_stack and depth <= fn_stack[-1][2]:
            name, start, _ = fn_stack.pop()
            length = i - start + 1
            if length > FN_MAX:
                long_fns.append((name, start, length))

    return {
        "path": path,
        "loc": loc,
        "oversize_file": loc > FILE_MAX,
        "long_fns": sorted(long_fns, key=lambda x: -x[2]),
        "counts": dict(counts),
        "counts_test": dict(counts_test),
    }


def normalized_kept(path):
    """Return [(orig_lineno, normalized_text)] skipping blank & comment-only lines."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        out = []
        for i, raw in enumerate(fh, 1):
            s = raw.strip()
            if not s or s.startswith("//") or s.startswith("/*") or s == "*/" or s.startswith("*"):
                continue
            out.append((i, WS.sub(" ", s)))
        return out


def duplication(files, k):
    """k-line shingles -> groups recurring across >=2 distinct locations."""
    groups = defaultdict(list)  # hash -> [(path, start_line, end_line, text)]
    for path in files:
        kept = normalized_kept(path)
        for i in range(len(kept) - k + 1):
            window = kept[i:i + k]
            text = "\n".join(t for _, t in window)
            if len(text) < k * 6:  # skip windows of near-trivial lines
                continue
            h = hash(text)
            groups[h].append((path, window[0][0], window[-1][0], text))

    blocks = []
    for h, hits in groups.items():
        # require >=2 hits in distinct (file, far-apart-line) spots
        anchors = sorted(set((p, s) for p, s, _, _ in hits))
        if len(anchors) < 2:
            continue
        distinct_files = len(set(p for p, _ in anchors))
        blocks.append({
            "occurrences": len(anchors),
            "distinct_files": distinct_files,
            "span": k,
            "dup_lines": (len(anchors) - 1) * k,
            "anchors": [{"file": p, "start": s, "end": e}
                        for (p, s), (_, _, e, _) in zip(anchors, hits[:len(anchors)])],
            "preview": hits[0][3].split("\n")[0][:90],
        })
    # rank by duplicated-line volume, then greedily drop blocks fully covered by a bigger one
    blocks.sort(key=lambda b: (-b["dup_lines"], -b["occurrences"]))
    covered, out = set(), []
    for b in blocks:
        keyset = {(a["file"], a["start"] // 4) for a in b["anchors"]}  # coarse 4-line buckets
        if keyset and keyset.issubset(covered):
            continue
        covered |= keyset
        out.append(b)
    return out


def short(path):
    i = path.find("/crates/")
    return path[i + 1:] if i >= 0 else path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--k", type=int, default=6)
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--json")
    args = ap.parse_args()

    files = rs_files(args.root)
    if not files:
        sys.exit(f"no .rs files under {args.root}")
    metrics = [scan_file(f) for f in files]
    dups = duplication(files, args.k)

    tot = defaultdict(int)
    tot_test = defaultdict(int)
    for m in metrics:
        for kk, v in m["counts"].items():
            tot[kk] += v
        for kk, v in m["counts_test"].items():
            tot_test[kk] += v
    oversize = [m for m in metrics if m["oversize_file"]]
    longfn_total = sum(len(m["long_fns"]) for m in metrics)

    print(f"== rust-quality :: {short(args.root)} ==")
    print(f"files={len(files)}  loc={sum(m['loc'] for m in metrics)}  "
          f"files>300={len(oversize)}  fns>40={longfn_total}")
    print("non-test smells: " + "  ".join(f"{k}={tot.get(k,0)}" for k in SMELLS))
    print(f"  (unwrap/expect in tests, allowed: unwrap={tot_test.get('unwrap',0)} expect={tot_test.get('expect',0)})")

    print("\n-- worst files (loc, long-fns, non-test unwrap/expect, clone) --")
    rank = sorted(metrics, key=lambda m: (-(m["loc"] > FILE_MAX), -len(m["long_fns"]),
                  -(m["counts"].get("unwrap", 0) + m["counts"].get("expect", 0))))
    for m in rank[:args.top]:
        c = m["counts"]
        flags = []
        if m["oversize_file"]:
            flags.append(f"LOC={m['loc']}")
        if m["long_fns"]:
            flags.append(f"fns>40={len(m['long_fns'])}(max {m['long_fns'][0][2]}L@{m['long_fns'][0][1]})")
        sm = " ".join(f"{k}={c[k]}" for k in ("unwrap", "expect", "clone", "panic", "unsafe", "allow") if c.get(k))
        if flags or sm:
            print(f"  {short(m['path']):52} {' '.join(flags)}  {sm}")

    print(f"\n-- top duplicated blocks (k={args.k} normalized lines) --")
    for b in dups[:args.top]:
        locs = ", ".join(f"{short(a['file']).split('/')[-1]}:{a['start']}" for a in b["anchors"][:6])
        more = "" if b["occurrences"] <= 6 else f" +{b['occurrences']-6}"
        print(f"  x{b['occurrences']} ~{b['dup_lines']}L  [{locs}{more}]  «{b['preview']}»")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"metrics": metrics, "duplication": dups,
                       "totals": dict(tot), "totals_test": dict(tot_test)}, fh, indent=2)
        print(f"\njson -> {args.json}")


if __name__ == "__main__":
    main()
