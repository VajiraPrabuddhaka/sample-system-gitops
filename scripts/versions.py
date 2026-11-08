#!/usr/bin/env python3
"""Keep every pinned version in sync with versions.yaml.

Every pin in the repo is a line ending in `# version: <component>`, for example
    tag: "1.4.0-m.1" # version: control-plane
in a Flux release (flux/), and the matching `targetRevision:` in the Argo CD
Application (argocd/). Both trees are checked, so the two engines can't drift apart.

Usage:
  scripts/versions.py check   # exit 1 if any pin differs from versions.yaml
  scripts/versions.py apply   # rewrite the pins from versions.yaml (then review git diff)

No dependencies beyond the Python 3 standard library.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIN = re.compile(r'^(?P<pre>\s*(?:tag|version|targetRevision):\s*)(?P<q>"?)(?P<val>[^"\s#]+)(?P=q)'
                 r'(?P<post>\s*#\s*version:\s*(?P<name>[\w.-]+)\s*)$')
ENTRY = re.compile(r'^\s+(?P<key>[\w.-]+):\s*"(?P<val>[^"]+)"')


def load_versions():
    want, section, top = {}, None, {}
    for line in open(os.path.join(ROOT, "versions.yaml")):
        if re.match(r'^[a-z]', line):
            section = line.split(":")[0]
            m = re.match(r'^(\w+):\s*"([^"]+)"', line)
            if m:
                top[m.group(1)] = m.group(2)
            continue
        m = ENTRY.match(line)
        if m and section in ("charts", "sources"):
            want[m.group("key")] = m.group("val")
    return want, top


def pinned_files():
    for base in ("flux", "argocd"):
        for d, _, files in os.walk(os.path.join(ROOT, base)):
            for f in files:
                if f.endswith(".yaml"):
                    yield os.path.join(d, f)


def main(mode):
    want, top = load_versions()
    problems, changed, seen = [], [], set()
    oc = top.get("openchoreo")
    if oc:
        for c in ("control-plane", "data-plane", "workflow-plane", "observability-plane"):
            if want.get(c) != oc:
                problems.append(f"versions.yaml: charts.{c} ({want.get(c)}) != openchoreo ({oc})")
        if want.get("platform-defaults") != "v" + oc:
            problems.append(f"versions.yaml: sources.platform-defaults should be v{oc}")
    for path in pinned_files():
        lines = open(path).read().split("\n")
        dirty = False
        for i, line in enumerate(lines):
            m = PIN.match(line)
            if not m:
                continue
            name, val = m.group("name"), m.group("val")
            seen.add(name)
            rel = os.path.relpath(path, ROOT)
            if name not in want:
                problems.append(f"{rel}:{i+1}: '{name}' is not in versions.yaml")
                continue
            if val != want[name]:
                if mode == "apply":
                    lines[i] = f'{m.group("pre")}{m.group("q")}{want[name]}{m.group("q")}{m.group("post")}'
                    dirty = True
                    changed.append(f"{rel}:{i+1}: {name} {val} -> {want[name]}")
                else:
                    problems.append(f"{rel}:{i+1}: {name} is {val}, versions.yaml says {want[name]}")
        if dirty:
            with open(path, "w") as f:
                f.write("\n".join(lines))
    for name in sorted(set(want) - seen):
        problems.append(f"versions.yaml: '{name}' is not pinned anywhere")
    for c in changed:
        print("updated", c)
    for p in problems:
        print("MISMATCH", p)
    if mode == "check" and not problems:
        print(f"ok: {len(seen)} components, every pin matches versions.yaml")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("check", "apply"):
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
