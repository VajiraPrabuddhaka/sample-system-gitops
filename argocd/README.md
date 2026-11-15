# OpenChoreo with Argo CD

This directory contains everything you need to install OpenChoreo with Argo CD. The `../flux` directory has the same setup for Flux, and you only need one of them.

## Plug In the Repository

Run the following steps from the root of the repository:

1. Install Argo CD **3.x** in the `argocd` namespace by following its [getting started guide](https://argo-cd.readthedocs.io/en/stable/getting_started/).

2. Add the health checks this repository relies on:

   ```bash
   kubectl -n argocd patch configmap argocd-cm --patch-file argocd/argocd-cm-patch.yaml
   ```

   These health checks make the root app wait until each wave is Healthy, and mark a plane registration as Healthy only once its agent connects. Without them, everything still converges through retries, but without any ordering.

   > [!TIP]
   > If you installed Argo CD with Helm, put the same keys under `configs.cm` instead.

3. Apply the root app. It syncs `clusters/k3d-single`, which creates one Application per unit:

   ```bash
   kubectl apply -f argocd/clusters/k3d-single/root-app.yaml
   ```

4. Watch the Applications sync:

   ```bash
   kubectl -n argocd get applications -w
   ```

### One Cluster per Plane (k3d-multi)

To run each plane in its own cluster (`clusters/k3d-multi`), do steps 1 and 2 on each of the four clusters. Then apply that cluster's `clusters/k3d-multi/<plane>/root-app.yaml` using its context. Each cluster's Argo CD manages only its own cluster. Refer to the [multi-cluster section](../README.md#multi-cluster-setup-on-k3d-k3d-multi) of the top-level README for more details.

### Forks and Mirrors

Every Application refers to this repository by its URL. So if you are using a fork or a mirror, run the following command and push the change before step 3:

```bash
scripts/set-git-source.sh <url> [branch]
```

## Conventions

- **Unit** - A directory under `shared/`, `identity/` or `planes/`. Its `application.yaml` holds the Application(s), named `openchoreo-*`, in the `argocd` namespace and the `default` project, with a sync wave. Its `kustomization.yaml` lists only `application.yaml`. The Application reads `values.yaml` and `manifests/` directly from Git.
- **Charts** - Charts come from public OCI registries, declared once in `shared/helm-repositories` as repository Secrets without credentials. This means you do not need to set up any repositories in Argo CD.
- **Per-cluster values** - `clusters/<name>/kustomization.yaml` appends `$values/argocd/clusters/<name>/values/<component>.yaml` to the Application's `valueFiles`.
- **Registration details** - The data plane host and port and the observer URL are `kustomize.patches` that the cluster adds to the registration Applications.
- **Drift from injected CA bundles** - cert-manager and ESO inject CA bundles into some resources. This drift is ignored per Helm Application using `ignoreDifferences` + `RespectIgnoreDifferences=true`.
- **Helm `lookup`** - Helm `lookup` is not available under Argo CD. See `planes/control-plane/install/optional/` for how the `occ remote` signing key is handled instead.
