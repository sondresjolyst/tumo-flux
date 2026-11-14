# tumo-flux

## Layout

The `flux-system` Kustomization applies `clusters/production`. That holds the
Flux components, the `cluster-versions` ConfigMap in
`clusters/production/versions.yaml` and three layer Kustomizations defined in
`clusters/production/layers.yaml`:

1. `infrastructure-controllers` applies `clusters/production/infrastructure/controllers`.
   It is ready once the traefik HelmRelease and the cert-manager Kustomization are healthy.
2. `infrastructure-configs` applies `clusters/production/infrastructure/configs`
   after the controllers are ready.
3. `apps` applies `clusters/production/apps` after the configs are ready.

Each layer substitutes `${VARIABLE}` from the `cluster-versions` and
`tumo-flux-config` ConfigMaps.

## Adding a version variable

1. Add a line to `data` in `clusters/production/versions.yaml` in the form
   `MY_CHART_VERSION: 1.2.3 # https://artifacthub.io/packages/helm/<repo>/<chart>`.
   The URL comment lets the update workflow find and bump the version.
2. Use `${MY_CHART_VERSION}` in a manifest that one of the layers applies.

Both changes can merge in one PR. The layers read the ConfigMap on every
reconcile, so no manual patch is needed. Leave the value unquoted, because
the update workflow rewrites it as plain text. CI fails if YAML would read it
as a number, such as `1.2`.
