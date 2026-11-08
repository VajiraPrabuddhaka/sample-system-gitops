#!/usr/bin/env python3
"""Print the Helm values a cluster gives a component, merged the way both engines do it:
the unit's values.yaml, then clusters/<cluster>/values/<component>.yaml (later wins;
maps merge, lists replace, null deletes a key).

Usage: scripts/render-values.py <cluster> <component> [--engine flux|argocd]
  e.g. scripts/render-values.py k3d-single control-plane
Components: see UNITS below. The engine only picks which tree to read; the files are
identical in both (scripts/check-tree.py enforces it).
Needs PyYAML (pip install pyyaml).
"""
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# component (HelmRelease / Application name without "openchoreo-") -> unit directory
UNITS = {
    "cert-manager": "shared/cert-manager",
    "external-secrets": "shared/external-secrets",
    "kgateway": "shared/kgateway",
    "thunder": "identity",
    "control-plane": "planes/control-plane/install",
    "data-plane": "planes/data-plane/install",
    "workflow-plane": "planes/workflow-plane/install",
    "observability-plane": "planes/observability-plane/install",
    "obs-logs-opensearch": "planes/observability-plane/modules/logs-opensearch",
    "obs-traces-opensearch": "planes/observability-plane/modules/traces-opensearch",
    "obs-metrics-prometheus": "planes/observability-plane/modules/metrics-prometheus",
    "obs-events-otel-collector": "planes/observability-plane/modules/events-otel-collector",
    "obs-finops-opencost": "planes/observability-plane/modules/finops-opencost",
}


def merge(dst, src):
    for k, v in (src or {}).items():
        if v is None:
            dst.pop(k, None)
        elif isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v
    return dst


def render(cluster, component, engine="flux"):
    if component not in UNITS:
        sys.exit(f"unknown component {component}; one of: {', '.join(UNITS)}")
    out, used = {}, []
    for rel in (os.path.join(engine, UNITS[component], "values.yaml"),
                os.path.join(engine, "clusters", cluster, "values", component + ".yaml")):
        path = os.path.join(ROOT, rel)
        if os.path.exists(path):
            with open(path) as f:
                merge(out, yaml.safe_load(f) or {})
            used.append(rel)
    return out, used


if __name__ == "__main__":
    args = sys.argv[1:]
    engine = "flux"
    if "--engine" in args:
        i = args.index("--engine")
        engine = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2 or engine not in ("flux", "argocd"):
        print(__doc__)
        sys.exit(2)
    values, used = render(args[0], args[1], engine)
    print("# layers: " + ", ".join(used))
    print(yaml.safe_dump(values, sort_keys=False, default_flow_style=False), end="")
