# local-setup2

Experimental local Platform Mesh setup without Flux, OCM, or kro.

## Goal

`local-setup2` keeps the good parts of the old local setup:

- kind-based cluster
- browser access via `https://portal.localhost:8443`
- easy local chart iteration

but drops the indirection layers:

- no Flux
- no HelmReleases
- no OCM transfer/build step
- no in-cluster OCI registry
- no kro bootstrap path

Note: `local-setup2` still applies the **OCM CRDs** because the platform-mesh-operator expects those API types to exist, even though this setup does not create or reconcile OCM objects.

Instead, the setup does this:

1. create/reuse a kind cluster
2. render Helm values from local templates
3. `helm upgrade --install` the required charts directly
4. apply the small amount of non-chart bootstrap config that still exists today

## Important caveat

This is **not** a pure "only Helm and nothing else" setup yet.
A few bootstrap resources are still required outside Helm:

- TLS secrets for the local domain
- bootstrap credentials (Keycloak, DB users, OpenFGA)
- the `PlatformMesh` resource for PM operator bootstrap logic
- the `kcp-webhook-secret` that currently still has to be assembled from the rebac webhook serving CA

So the model is really:

- direct Helm installs for charts
- plus a thin bootstrap script for the remaining imperative glue

That is still dramatically simpler than the current OCM/Flux path.

## Current design

- Base domain: `portal.localhost`
- External/browser port: `8443`
- kind host port mapping: `127.0.0.1:8443 -> nodePort 31000`
- Fixed Service IPs:
  - Traefik: `10.96.188.4`
  - kcp front-proxy: `10.96.0.100`

These fixed IPs are intentional. They allow stable `hostAliases` entries, which are still needed by the current bootstrap topology.

## What still uses the PM operator?

The PM operator is still part of the setup.

That is deliberate: even without Flux/OCM, it still provides important bootstrap behavior such as kcp setup and kubeconfig secret creation. Its deployment-management subroutine remains disabled.

## Usage

```bash
task local-setup2
```

Then open:

- `https://portal.localhost:8443`

## Developer workflow

Once the cluster is up, iterate directly with Helm.

Example:

```bash
helm upgrade --install portal ./charts/portal \
  -n platform-mesh-system \
  -f local-setup2/.generated/values/portal.yaml
```

For external charts, `local-setup2/scripts/start.sh` contains the pinned source/version list used for installation.

## Status

This is an experimental V2 scaffold, not yet a polished replacement for `local-setup/`.
It is meant to prove feasibility and give us a place to evolve the direct-Helm approach.
