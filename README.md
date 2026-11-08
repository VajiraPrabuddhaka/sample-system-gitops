# OpenChoreo system GitOps sample

Install and run **OpenChoreo itself** (the control, data, workflow and observability planes plus everything they need) from Git with **Flux or Argo CD**, instead of following the manual Helm and kubectl steps in the install guides. You install the GitOps engine from its own guide, then plug this repo in.

This repo installs the platform. What runs **on** it (projects, components, environments, component types) is managed in a separate repo; start from [openchoreo/sample-gitops](https://github.com/openchoreo/sample-gitops). 

## Layout

`flux/` and `argocd/` are two complete copies of the same thing, one per engine. Use one, ignore (or delete) the other.

```text
flux/        everything for Flux
argocd/      the same for Argo CD: same shape, same values and manifests
  shared/                  what every cluster that runs a plane needs
    gateway-api-crds/  cert-manager/  external-secrets/  kgateway/
    helm-repositories/     (Argo CD only) the OCI Helm registries charts come from
  identity/                ThunderID, the default identity provider (optional)
  planes/
    control-plane/         install/  defaults/
    data-plane/            install/  registration/
    workflow-plane/        install/  templates/  registration/
    observability-plane/   install/  modules/  registration/
  clusters/
    k3d-single/            the example: every unit in one local k3d cluster
scripts/     k3d-up, verify, validate, set-git-source, seed-secrets, ...
```

Each directory under `shared/`, `identity/` and `planes/` is a **unit**: one Flux
Kustomization or one Argo CD Application (a few for multi-chart units). Units hold nothing
specific to a cloud or a cluster, so you plug the ones you need into any cluster.
Everything environment-specific (hostnames, ports, TLS, the secret store backend, the
build registry) lives in `clusters/<name>/`.

| In a unit | Flux | Argo CD |
|---|---|---|
| `values.yaml` | Helm values every cluster gets | the same file |
| `manifests/` | plain manifests (namespaces, ExternalSecrets, trust relay) | the same files |
| engine wiring | `release.yaml` (chart source + HelmRelease) | `application.yaml` |
| `kustomization.yaml` | what Flux applies | lists `application.yaml` |

`values.yaml` and `manifests/` are byte-identical in both trees; `scripts/check-tree.py`
(run by `validate.sh` and CI) fails when they drift.

## Quick start: k3d + Flux

Needs Docker with about 8 GB of RAM, `k3d`, `kubectl` and the `flux` CLI.

```bash
# 0. Until this repo has a permanent home: fork it, point it at your fork, push.
#    (The engines pull from Git, not from your checkout.)
scripts/set-git-source.sh https://github.com/<you>/sample-system-gitops.git main
git commit -am "Point at my fork" && git push

# 1. A local cluster (same definition as OpenChoreo's k3d guide).
scripts/k3d-up.sh

# 2. Flux >= 2.5, from its own guide: https://fluxcd.io/flux/installation/
flux install

# 3. Plug this repo in.
kubectl apply -f flux/clusters/k3d-single/plug.yaml
kubectl -n flux-system get kustomizations -w     # openchoreo-* units go Ready in order
scripts/verify.sh
```

Already run Flux from a fleet repo? Commit `plug.yaml` there instead of `kubectl apply`.

Then open http://openchoreo.localhost:8080 and log in as `admin@openchoreo.dev` / `Admin@123`
(dev users from the ThunderID bootstrap in `clusters/k3d-single/values/thunder.yaml`).

## Quick start: k3d + Argo CD

```bash
# 0. As above: scripts/set-git-source.sh <your fork> <branch>, commit, push.
scripts/k3d-up.sh

# 1. Argo CD 3.x, from its own guide: https://argo-cd.readthedocs.io/en/stable/getting_started/
#    Then the health checks this repo relies on (the one change to a stock install):
kubectl -n argocd patch configmap argocd-cm --patch-file argocd/argocd-cm-patch.yaml

# 2. Plug this repo in.
kubectl apply -f argocd/clusters/k3d-single/root-app.yaml
kubectl -n argocd get applications -w            # openchoreo-* apps sync wave by wave
scripts/verify.sh
```

## How it works

**Order.** Both engines install the units in the same order. Flux chains one Kustomization
per unit with `dependsOn` (`flux/clusters/<name>/units.yaml`); Argo CD uses each
Application's sync wave.

| Wave | Units |
|---|---|
| 0–11 | `shared/`: Gateway API CRDs, cert-manager, External Secrets, kgateway |
| 10–20 | k3d only: OpenBao + ClusterSecretStore `default`, CoreDNS rewrite |
| 30 | `identity/` (ThunderID) |
| 40 | `planes/control-plane/install` |
| 50 | the data, workflow and observability plane `install/` units |
| 60–61 | workflow templates, observability modules (logs, traces, metrics, events, cost) |
| 70 | `registration/` units: `ClusterDataPlane`, `ClusterWorkflowPlane`, `ClusterObservabilityPlane`. Healthy only once that plane's agent is connected |
| 80 | `planes/control-plane/defaults`: default environments, pipeline, component types (upstream, pinned tag) |

**Values.** Two layers, later wins: the unit's `values.yaml`, then
`clusters/<name>/values/<component>.yaml`. Flux reads the cluster file through an optional
ConfigMap `<component>-values`; Argo CD appends it to the Application's `valueFiles`
(a patch in `argocd/clusters/<name>/kustomization.yaml`).
`scripts/render-values.py <cluster> <component>` prints the merged result.

**What a cluster provides.** The units expect a few things they deliberately don't create,
because they depend on where you run:

| Needed | k3d-single provides | Elsewhere |
|---|---|---|
| A `ClusterSecretStore` named `default`, writable, shared by every cluster of the installation | OpenBao in dev mode | any ESO provider; seed the keys `scripts/seed-secrets.sh list` prints |
| Hostnames, ports, TLS for the plane gateways | `*.openchoreo.localhost`, plain HTTP | your domain and certificates, in `values/` |
| A registry for builds | in-cluster registry + k3d `publish-image` template | your registry's `publish-image` template |
| In-cluster resolution of the public hostnames | CoreDNS rewrite | usually real DNS |

**Trust without copying certificates.** The manual install copies the cluster-gateway CA
into every plane and pastes each agent's CA into its plane registration. Here, both sides
publish their CA certificate (public part only) to the secret store with an ESO
`PushSecret` and read the other side's with an `ExternalSecret`. It works the same in one
cluster or many, and re-publishes renewed certificates.

**Secrets.** Everything secret comes from the secret store through External Secrets. The
only secrets you create by hand are the keys `scripts/seed-secrets.sh list` prints; on k3d,
the dev OpenBao seeds itself.

## Your own cluster

1. Copy the example in the engine you use: `cp -r flux/clusters/k3d-single flux/clusters/<name>`
   (or the `argocd/` one), and replace `clusters/k3d-single` with `clusters/<name>` in it.
2. Drop the `k3d/` units and add your own: at least a `ClusterSecretStore` named `default`.
3. Edit `values/`: hostnames, TLS, load balancer settings.
4. Adjust the registration patches (where the data plane serves, where the observer is).
5. `scripts/validate.sh`, commit, push, apply your `plug.yaml` / `root-app.yaml`.

Nothing under `shared/`, `identity/` or `planes/` changes, so new versions of this repo
merge cleanly. The units can be split across clusters (every `registration/` unit stays on
the control-plane cluster), but only the single-cluster example ships for now.

## Scripts

| Script | What it does |
|---|---|
| `scripts/k3d-up.sh` | Create the k3d cluster for `k3d-single` |
| `scripts/set-git-source.sh [url] [branch]` | Point both engines at your fork (Flux `plug.yaml`, every Argo CD source) |
| `scripts/verify.sh` | Unit status, trust relay, plane connections, unhealthy pods |
| `scripts/validate.sh` | Static checks (kustomize, tree parity and references, versions, kubeconform, helm template); CI runs it |
| `scripts/check-tree.py` | The two trees match, and every path, `dependsOn` and patch target exists |
| `scripts/render-values.py <cluster> <c>` | Print the merged Helm values for one component |
| `scripts/seed-secrets.sh <vault\|openbao\|list>` | Write (or list) the secrets contract |
| `scripts/versions.py check\|apply` | Keep every pinned version, in both trees, in sync with `versions.yaml` |
| `scripts/sync-upstream.sh <tag>` | Re-copy the files vendored from openchoreo/openchoreo (both trees) |
