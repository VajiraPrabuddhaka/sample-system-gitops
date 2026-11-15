# OpenChoreo System GitOps Sample

This repository shows how to install and run OpenChoreo itself (the control plane, data plane, workflow plane and observability plane, along with everything they depend on) from Git using either Flux or Argo CD. Instead of following the manual Helm and kubectl steps in the installation guides, you install the GitOps tool of your choice from its own guide and then plug this repository into it.

This repository only covers the platform installation. The resources that run on top of OpenChoreo (projects, components, environments, component types, etc.) are managed in a separate repository. Refer to [openchoreo/sample-gitops](https://github.com/openchoreo/sample-gitops) to get started with those.

## Table of Contents

- [Repository Structure](#repository-structure)
- [Quick Start with k3d and Flux](#quick-start-with-k3d-and-flux)
- [Quick Start with k3d and Argo CD](#quick-start-with-k3d-and-argo-cd)
- [Multi-Cluster Setup on k3d (k3d-multi)](#multi-cluster-setup-on-k3d-k3d-multi)
- [How It Works](#how-it-works)
- [Using Your Own Cluster](#using-your-own-cluster)
- [Scripts](#scripts)
- [Next Steps](#next-steps)

---

## Repository Structure

The `flux/` and `argocd/` directories are two complete copies of the same setup, one for each GitOps tool. You only need one of them, so pick the tool you use and ignore (or delete) the other.

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
    observability-plane/   install/  modules/  collectors/  registration/
  clusters/
    k3d-single/            example: every unit in one local k3d cluster
    k3d-multi/             example: one k3d cluster per plane
      control-plane/  data-plane/  workflow-plane/  observability-plane/
      k3d/                 k3d-only units those four clusters use
scripts/     k3d-up, verify, validate, set-git-source, seed-secrets, ...
```

Each directory under `shared/`, `identity/` and `planes/` is a **unit**. A unit maps to one Flux Kustomization or one Argo CD Application (a few units that install more than one chart have more than one Application). Units do not contain anything specific to a cloud provider or a cluster, which means you can plug the units you need into any cluster. Everything that is environment-specific (hostnames, ports, TLS, the secret store backend, the build registry, etc.) lives in `clusters/<name>/`.

The following table shows what a unit contains in each tree:

| In a unit | Flux | Argo CD |
|---|---|---|
| `values.yaml` | Helm values that every cluster gets | The same file |
| `manifests/` | Plain manifests (namespaces, ExternalSecrets, trust relay) | The same files |
| Engine wiring | `release.yaml` (chart source + HelmRelease) | `application.yaml` |
| `kustomization.yaml` | What Flux applies | Lists `application.yaml` |

> [!NOTE]
> `values.yaml` and `manifests/` are byte-identical in both trees. `scripts/check-tree.py` (run by `scripts/validate.sh` and CI) fails if they drift apart.

---

## Quick Start with k3d and Flux

By following this guide, you will get OpenChoreo installed on a single local k3d cluster, with every unit managed by Flux.

### Prerequisites

Before you begin, ensure you have:

- **Docker** with at least **8 GB RAM** allocated
- **[k3d](https://k3d.io/)** installed
- **[kubectl](https://kubernetes.io/docs/tasks/tools/)** installed
- **[Flux CLI](https://fluxcd.io/flux/installation/)** installed

> [!NOTE]
> If you are using Colima, `scripts/k3d-up.sh` detects it and sets `K3D_FIX_DNS=0` for you. See [k3d-io/k3d#1449](https://github.com/k3d-io/k3d/issues/1449) for more details.

### Step 1: Point the Repository at Your Fork

Flux pulls from Git, not from your local checkout. So until this repository has a permanent home, fork it, point it at your fork and push the change:

```bash
scripts/set-git-source.sh https://github.com/<you>/sample-system-gitops.git main
git commit -am "Point at my fork" && git push
```

### Step 2: Create a Local Cluster

The following command creates a k3d cluster with the same definition as OpenChoreo's k3d guide:

```bash
scripts/k3d-up.sh
```

### Step 3: Install Flux

Install Flux 2.5 or later by following its [installation guide](https://fluxcd.io/flux/installation/):

```bash
flux install
```

### Step 4: Plug This Repository In

```bash
kubectl apply -f flux/clusters/k3d-single/plug.yaml
```

> [!TIP]
> If you already run Flux from a fleet repository, commit `plug.yaml` there instead of running `kubectl apply`.

### Step 5: Verify the Installation

Watch the `openchoreo-*` units become Ready in order:

```bash
kubectl -n flux-system get kustomizations -w
```

Then run the verification script:

```bash
scripts/verify.sh
```

That's it! Open http://openchoreo.localhost:8080 and log in as `admin@openchoreo.dev` / `Admin@123`. These are the dev users created by the ThunderID bootstrap in `clusters/k3d-single/values/thunder.yaml`.

---

## Quick Start with k3d and Argo CD

By following this guide, you will get the same single-cluster installation as above, managed by Argo CD instead of Flux.

### Prerequisites

Before you begin, ensure you have:

- **Docker** with at least **8 GB RAM** allocated
- **[k3d](https://k3d.io/)** installed
- **[kubectl](https://kubernetes.io/docs/tasks/tools/)** installed

### Step 1: Point the Repository at Your Fork

Every Argo CD Application refers to this repository by its URL, so this commit is required before you plug the repository in:

```bash
scripts/set-git-source.sh https://github.com/<you>/sample-system-gitops.git main
git commit -am "Point at my fork" && git push
```

### Step 2: Create a Local Cluster

```bash
scripts/k3d-up.sh
```

### Step 3: Install Argo CD

Install Argo CD 3.x as described in its [getting started guide](https://argo-cd.readthedocs.io/en/stable/getting_started/):

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
```

Then add the health checks this repository relies on. This is the only change to a stock Argo CD installation:

```bash
kubectl -n argocd patch configmap argocd-cm --patch-file argocd/argocd-cm-patch.yaml
```

### Step 4: Plug This Repository In

```bash
kubectl apply -f argocd/clusters/k3d-single/root-app.yaml
```

### Step 5: Verify the Installation

Watch the `openchoreo-*` Applications sync wave by wave:

```bash
kubectl -n argocd get applications -w
```

Then run the verification script:

```bash
scripts/verify.sh
```

Once everything is healthy, open http://openchoreo.localhost:8080 and log in with the same dev users as in the Flux quick start.

---

## Multi-Cluster Setup on k3d (k3d-multi)

The `clusters/k3d-multi/` example runs each plane in its own k3d cluster, similar to OpenChoreo's [multi-cluster k3d guide](https://github.com/openchoreo/openchoreo/tree/v1.4.0-m.1/install/k3d/multi-cluster). Each subdirectory represents one cluster with its own GitOps engine:

| Directory | k3d cluster | What runs there |
|---|---|---|
| `control-plane/` | `openchoreo-cp` | Control plane, ThunderID, every plane registration, the shared trust OpenBao |
| `data-plane/` | `openchoreo-dp` | Data plane, and collectors for its logs, traces, metrics and events |
| `workflow-plane/` | `openchoreo-wp` | Workflow plane, build templates, the k3d registry, and collectors for its logs and events |
| `observability-plane/` | `openchoreo-op` | Observability plane and its modules, receiving the other clusters' telemetry |

### How the Clusters Connect

Every cluster has its own OpenBao behind `ClusterSecretStore default`. Apart from that, there is one more OpenBao on the control-plane cluster, which sits behind `ClusterSecretStore trust` on all four clusters. Only the trust relay's CA certificates go through it. Agents, collectors and secret stores reach the other clusters through the host (`host.k3d.internal` and the ports mapped by k3d).

### Setting Up the Clusters

First, point the repository at your fork and push the change, as in the quick starts above:

```bash
scripts/set-git-source.sh https://github.com/<you>/sample-system-gitops.git main
git commit -am "Point at my fork" && git push
```

Then create the four clusters and plug each one in. The following example uses Flux:

```bash
scripts/k3d-up.sh multi
for c in cp:control-plane dp:data-plane wp:workflow-plane op:observability-plane; do
  flux install --context "k3d-openchoreo-${c%%:*}"
  kubectl --context "k3d-openchoreo-${c%%:*}" apply -f "flux/clusters/k3d-multi/${c#*:}/plug.yaml"
done
scripts/verify.sh --multi
```

> [!NOTE]
> `scripts/k3d-up.sh multi` warns you if Docker's inotify limits are too low for four clusters, and prints the commands to raise them.

If you are using Argo CD, install it on each cluster, patch each cluster's `argocd-cm` as described in the Argo CD quick start, and apply `argocd/clusters/k3d-multi/<directory>/root-app.yaml` using that cluster's context.

You can plug the clusters in any order. A plane keeps retrying until the control plane has published its gateway CA, and each registration on the control-plane cluster becomes Ready once that plane's agent connects. The URLs are the same as in k3d-single.

> [!IMPORTANT]
> Plan for more memory than k3d-single. This setup runs four k3s servers, four GitOps engines, and cert-manager and External Secrets on each cluster.

### Differences from the Upstream Guide

- **An OpenBao on every cluster** - Every cluster has its own OpenBao, plus the shared trust one. The upstream guide runs OpenBao only on the data and observability clusters, and copies the CA certificates between clusters manually.
- **OpenSearch exposed through a TLSRoute** - The observability cluster exposes its single-node OpenSearch to the collectors through a TLSRoute (`k3d/opensearch-route`). The upstream guide switches the logs module to an operator-managed OpenSearch cluster instead. That chart reads a Secret with Helm `lookup`, which Argo CD cannot render.

---

## How It Works

### Installation Order

Both engines install the units in the same order. Flux chains one Kustomization per unit using `dependsOn` (`flux/clusters/<name>/units.yaml`), while Argo CD uses each Application's sync wave.

| Wave | Units |
|---|---|
| 0–11 | `shared/`: Gateway API CRDs, cert-manager, External Secrets, kgateway |
| 10–20 | k3d only: OpenBao + ClusterSecretStores `default` and `trust`, CoreDNS rewrite |
| 30 | `identity/` (ThunderID) |
| 40 | `planes/control-plane/install` |
| 50 | The data, workflow and observability plane `install/` units |
| 60–61 | Workflow templates, observability modules (logs, traces, metrics, events, cost) or, on a cluster without the observability plane, its collectors |
| 70 | `registration/` units: `ClusterDataPlane`, `ClusterWorkflowPlane`, `ClusterObservabilityPlane`. Each one becomes Healthy only once that plane's agent is connected |
| 80 | `planes/control-plane/defaults`: default environments, pipeline, component types (upstream, pinned tag) |

### Helm Values

Helm values are applied in two layers, where the later layer wins:

1. The unit's `values.yaml`
2. The cluster's `clusters/<name>/values/<component>.yaml`

Flux reads the cluster file through an optional ConfigMap named `<component>-values`. Argo CD appends it to the Application's `valueFiles` through a patch in `argocd/clusters/<name>/kustomization.yaml`.

To see the merged values for a component, run the following command:

```bash
scripts/render-values.py <cluster> <component>
```

### What a Cluster Needs to Provide

The units expect a few things that they deliberately do not create, because these depend on where you run OpenChoreo:

| Needed | k3d provides | Elsewhere |
|---|---|---|
| A writable `ClusterSecretStore` named `default`, holding the secrets this cluster's units read. OpenChoreo also writes workload and build secrets here | Each cluster's own OpenBao, in dev mode | Any ESO provider, per cluster or shared. Seed the keys printed by `scripts/seed-secrets.sh list` |
| A writable `ClusterSecretStore` named `trust`, on the same backend for every cluster of the installation, holding the trust relay's CA certificates | k3d-single: the same OpenBao. k3d-multi: a shared OpenBao on the control-plane cluster | Any ESO provider that every cluster can reach. Nothing to seed |
| Hostnames, ports and TLS for the plane gateways | `*.openchoreo.localhost`, plain HTTP | Your domain and certificates, in `values/` |
| A registry for builds | An in-cluster registry + the k3d `publish-image` template | A `publish-image` template for your registry |
| In-cluster resolution of the public hostnames | A CoreDNS rewrite | Usually real DNS |

### Trust Without Copying Certificates

In the manual installation, you copy the cluster gateway CA into every plane and paste each agent's CA into its plane registration. This repository avoids that step. Both sides publish their CA certificate (only the public part) to the `trust` store using an ESO `PushSecret`, and read the other side's certificate using an `ExternalSecret`. This works the same way whether you run one cluster or many, and renewed certificates are re-published automatically.

### Secrets

All secrets come from the secret store through External Secrets. The only secrets you have to create by hand are the keys printed by `scripts/seed-secrets.sh list`. On k3d, the dev OpenBao seeds itself, so there is nothing to create.

---

## Using Your Own Cluster

Follow these steps to set up a cluster of your own:

1. Copy the example for the engine you use, and replace `clusters/k3d-single` with `clusters/<name>` inside the copy:
   ```bash
   cp -r flux/clusters/k3d-single flux/clusters/<name>    # or the argocd/ one
   ```
2. Remove the `k3d/` units and add your own. At a minimum, you need the `ClusterSecretStore`s `default` and `trust`.
3. Update `values/` with your hostnames, TLS and load balancer settings.
4. Adjust the registration patches (where the data plane serves, where the observer is).
5. Run `scripts/validate.sh`, commit, push, and apply your `plug.yaml` (Flux) or `root-app.yaml` (Argo CD).

Since nothing under `shared/`, `identity/` or `planes/` changes, new versions of this repository merge cleanly.

If you run the planes on separate clusters, start from `k3d-multi` instead. This means one directory per cluster, every `registration/` unit on the control-plane cluster, and `planes/observability-plane/collectors` on the clusters that ship their telemetry elsewhere.

---

## Scripts

| Script | What it does |
|---|---|
| `scripts/k3d-up.sh [single\|multi]` | Creates the k3d cluster for `k3d-single`, or the four clusters for `k3d-multi` |
| `scripts/set-git-source.sh [url] [branch]` | Points both engines at your fork (the Flux `plug.yaml` and every Argo CD source) |
| `scripts/verify.sh [--context C]... [--multi]` | Shows unit status, the trust relay, plane connections and unhealthy pods, per cluster |
| `scripts/validate.sh` | Runs the static checks (kustomize, tree parity and references, versions, kubeconform, helm template). CI runs this too |
| `scripts/check-tree.py` | Checks that the two trees match, and that every path, `dependsOn` and patch target exists |
| `scripts/render-values.py <cluster> <c>` | Prints the merged Helm values for one component |
| `scripts/seed-secrets.sh <vault\|openbao\|list>` | Writes (or lists) the secrets that the units expect |
| `scripts/versions.py check\|apply` | Keeps every pinned version, in both trees, in sync with `versions.yaml` |
| `scripts/sync-upstream.sh <tag>` | Re-copies the files vendored from openchoreo/openchoreo into both trees |

---

## Next Steps

Once the platform is up and running, you can manage what runs on top of it (projects, components, environments, etc.) the GitOps way. See [openchoreo/sample-gitops](https://github.com/openchoreo/sample-gitops) to get started.
