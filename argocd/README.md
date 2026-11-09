# OpenChoreo with Argo CD

Everything here is for Argo CD. `../flux` is the same thing for Flux; you only need one.

## Plug in

1. Install Argo CD **3.x** from its own guide:
   https://argo-cd.readthedocs.io/en/stable/getting_started/ (namespace `argocd`).
2. Add the health checks this repo relies on (installed with Helm? put the same keys under
   `configs.cm` instead):
   ```bash
   kubectl -n argocd patch configmap argocd-cm --patch-file argocd/argocd-cm-patch.yaml
   ```
   They make the root app wait for each wave to be Healthy, and plane registrations
   Healthy only once their agent connects. Without them everything still converges through
   retries, just without ordering.
3. `kubectl apply -f clusters/k3d-single/root-app.yaml`. It syncs `clusters/k3d-single`,
   which creates one Application per unit.
4. Watch: `kubectl -n argocd get applications -w`.

One cluster per plane (`clusters/k3d-multi`): do steps 1 and 2 on each of the four
clusters, then apply that cluster's `clusters/k3d-multi/<plane>/root-app.yaml` with its
context (see the k3d-multi section of the top-level README). Each cluster's Argo CD
manages only its own cluster.

Every Application names this repo, so on a fork or mirror run
`scripts/set-git-source.sh <url> [branch]` and push before step 3.

## Conventions

- **Unit** = a directory under `shared/`, `identity/` or `planes/`. Its `application.yaml`
  holds the Application(s), named `openchoreo-*`, in `argocd`, project `default`, with a
  sync wave. Its `kustomization.yaml` lists only `application.yaml`; `values.yaml` and
  `manifests/` are read by the Application from Git.
- **Charts** come from public OCI registries, declared once in `shared/helm-repositories`
  (repository Secrets, no credentials), so no repository setup in Argo CD is needed.
- **Per-cluster values**: `clusters/<name>/kustomization.yaml` appends
  `$values/argocd/clusters/<name>/values/<component>.yaml` to the Application's `valueFiles`.
- **Registration details** (data plane host/port, observer URL) are `kustomize.patches` the
  cluster adds to the registration Applications.
- **Drift from injected CA bundles** (cert-manager, ESO) is ignored per Helm Application
  (`ignoreDifferences` + `RespectIgnoreDifferences=true`).
- **Helm `lookup`** isn't available under Argo CD: see `planes/control-plane/install/optional/`
  for the `occ remote` signing key.
