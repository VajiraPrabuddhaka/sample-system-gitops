#!/usr/bin/env python3
"""Structural checks for the two engine trees (validate.sh runs it; no cluster needed).

1. Parity: the engine-neutral files (every values.yaml, everything under a manifests/
   directory, every cluster's values/) exist in both flux/ and argocd/ and are
   byte-identical.
   Edit one, copy it to the other.
2. Units: every unit directory exists in both trees (Flux-only and Argo CD-only
   exceptions are listed below).
3. Clusters: every cluster (a directory under clusters/ holding plug.yaml for Flux or
   root-app.yaml for Argo CD, e.g. k3d-single or k3d-multi/data-plane) exists for both
   engines.
4. References (needs PyYAML and kustomize or kubectl), per cluster:
   - Flux: every unit Kustomization's path exists, every dependsOn names a unit defined
     for that cluster, every values ConfigMap is read by some HelmRelease.
   - Argo CD: every source path and $values file in this repo exists, and every patch in
     the cluster's kustomization.yaml matches an Application (kustomize silently skips
     a patch whose target matches nothing).

Usage: scripts/check-tree.py
"""
import filecmp
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINES = ("flux", "argocd")
# Units that only one engine has, relative to the engine root.
ONLY = {
    "argocd": {"shared/helm-repositories"},  # OCI Helm registries, declared for Argo CD
    "flux": set(),
}
problems = []


def neutral_files(engine):
    base = os.path.join(ROOT, engine)
    out = set()
    for d, _, files in os.walk(base):
        rel_d = os.path.relpath(d, base)
        parts = rel_d.split(os.sep)
        for f in files:
            rel = os.path.normpath(os.path.join(rel_d, f))
            in_values_dir = parts[0] == "clusters" and "values" in parts[2:]
            if f == "values.yaml" or "manifests" in parts or in_values_dir:
                out.add(rel)
    return out


def unit_dirs(engine):
    """Directories holding engine wiring: release.yaml/source.yaml (Flux) or application.yaml (Argo CD)."""
    base = os.path.join(ROOT, engine)
    marker = {"flux": ("release.yaml", "source.yaml"), "argocd": ("application.yaml",)}[engine]
    out = set()
    for d, _, files in os.walk(base):
        if any(m in files for m in marker) or (
                engine == "flux" and "kustomization.yaml" in files and "manifests" in os.listdir(d)
                and os.path.basename(d) != "manifests"):
            out.add(os.path.relpath(d, base))
        if engine == "argocd" and "kustomization.yaml" in files and os.path.basename(d) == "helm-repositories":
            out.add(os.path.relpath(d, base))
    return out


def check_parity():
    f, a = neutral_files("flux"), neutral_files("argocd")
    for p in sorted(f - a):
        problems.append(f"parity: flux/{p} has no argocd/{p}")
    for p in sorted(a - f):
        problems.append(f"parity: argocd/{p} has no flux/{p}")
    for p in sorted(f & a):
        if not filecmp.cmp(os.path.join(ROOT, "flux", p), os.path.join(ROOT, "argocd", p), shallow=False):
            problems.append(f"parity: flux/{p} and argocd/{p} differ")
    return len(f & a)


def check_units():
    f, a = unit_dirs("flux") - ONLY["flux"], unit_dirs("argocd") - ONLY["argocd"]
    for p in sorted(f - a):
        problems.append(f"units: flux/{p} has no Argo CD counterpart argocd/{p}")
    for p in sorted(a - f):
        problems.append(f"units: argocd/{p} has no Flux counterpart flux/{p}")
    return len(f & a)


def clusters(engine):
    """Cluster directories, relative to <engine>/clusters: the ones holding the plug-in manifest."""
    base = os.path.join(ROOT, engine, "clusters")
    marker = {"flux": "plug.yaml", "argocd": "root-app.yaml"}[engine]
    return sorted(os.path.relpath(d, base) for d, _, files in os.walk(base) if marker in files)


def check_clusters():
    f, a = set(clusters("flux")), set(clusters("argocd"))
    for c in sorted(f - a):
        problems.append(f"clusters: flux/clusters/{c} has no argocd/clusters/{c}")
    for c in sorted(a - f):
        problems.append(f"clusters: argocd/clusters/{c} has no flux/clusters/{c}")
    return len(f & a)


def build(path, flux):
    args = ["--load-restrictor", "LoadRestrictionsNone"] if flux else []
    if shutil.which("kustomize"):
        cmd = ["kustomize", "build", *args, path]
    else:
        cmd = ["kubectl", "kustomize", *args, path]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode:
        problems.append(f"build {os.path.relpath(path, ROOT)}: {out.stderr.strip()}")
        return []
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def check_flux(cluster):
    docs = build(os.path.join(ROOT, "flux", "clusters", cluster), flux=True)
    units = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Kustomization"}
    for name, d in units.items():
        path = d["spec"].get("path", "")
        if not os.path.isfile(os.path.join(ROOT, path, "kustomization.yaml")):
            problems.append(f"flux/{cluster}: {name} path {path} has no kustomization.yaml")
        for dep in d["spec"].get("dependsOn", []):
            if dep["name"] not in units:
                problems.append(f"flux/{cluster}: {name} depends on {dep['name']}, which this cluster doesn't define")
    read = set()
    for d, _, files in os.walk(os.path.join(ROOT, "flux")):
        for f in files:
            if f == "release.yaml":
                for doc in yaml.safe_load_all(open(os.path.join(d, f))):
                    if doc and doc["kind"] == "HelmRelease":
                        read |= {v["name"] for v in doc["spec"].get("valuesFrom", [])}
    for d in docs:
        if d["kind"] == "ConfigMap" and d["metadata"]["name"] not in read:
            problems.append(f"flux/{cluster}: ConfigMap {d['metadata']['name']} is not read by any HelmRelease")
    return len(units)


def check_argocd(cluster):
    cdir = os.path.join(ROOT, "argocd", "clusters", cluster)
    docs = build(cdir, flux=False)
    apps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Application"}
    for name, app in apps.items():
        for s in app["spec"].get("sources", []):
            if "sample-system-gitops" not in s.get("repoURL", "") or s.get("ref"):
                pass
            elif s.get("path") and not os.path.isdir(os.path.join(ROOT, s["path"])):
                problems.append(f"argocd/{cluster}: {name} source path {s['path']} does not exist")
            for vf in (s.get("helm") or {}).get("valueFiles", []):
                if vf.startswith("$values/") and not os.path.isfile(os.path.join(ROOT, vf[len("$values/"):])):
                    problems.append(f"argocd/{cluster}: {name} values file {vf} does not exist")
    kust = yaml.safe_load(open(os.path.join(cdir, "kustomization.yaml")))
    for p in kust.get("patches", []):
        t = p.get("target", {})
        if t.get("kind") == "Application" and t.get("name") not in apps:
            problems.append(f"argocd/{cluster}: patch targets Application {t.get('name')}, which this cluster doesn't define")
    return len(apps)


if __name__ == "__main__":
    print(f"parity: {check_parity()} engine-neutral files")
    print(f"units:  {check_units()} units in both trees")
    print(f"clusters: {check_clusters()} clusters in both trees")
    try:
        import yaml  # noqa: E402
    except ImportError:
        print("references: skipped (needs PyYAML)")
        yaml = None
    if yaml and (shutil.which("kustomize") or shutil.which("kubectl")):
        for c in clusters("flux"):
            print(f"flux/{c}: {check_flux(c)} units")
        for c in clusters("argocd"):
            print(f"argocd/{c}: {check_argocd(c)} applications")
    elif yaml:
        print("references: skipped (needs kustomize or kubectl)")
    for p in problems:
        print("PROBLEM", p)
    sys.exit(1 if problems else 0)
