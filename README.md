# tumo-flux

## Adding a new `postBuild` substitution variable

`clusters/production/postBuild.yaml` is applied as a patch onto the
`flux-system` Kustomization itself, a self-referential bootstrap pattern,
see `clusters/production/flux-system/gotk-sync.yaml` and
`clusters/production/kustomization.yaml`. This means a **new** variable
added here can deadlock Flux on first reconcile after merge:

1. Flux rebuilds `clusters/production`, producing an updated `flux-system`
   Kustomization spec that includes the new variable.
2. Before applying anything, Flux runs `envsubst` against manifests using its
   **current** in-cluster spec, which does not know about the new variable
   yet.
3. `envsubst` fails in strict mode, variable not set, so the apply step
   aborts, and the updated spec with the new variable never gets written to
   the cluster. Repeated reconciles fail the same way indefinitely.

**Fix, one-time, after merging a new variable:** manually patch the live
Kustomization to seed the new variable before reconciling again:

```bash
kubectl -n flux-system patch kustomization flux-system --type merge \
  -p '{"spec":{"postBuild":{"substitute":{"MY_NEW_VARIABLE":"value"}}}}'
flux reconcile kustomization flux-system --with-source
```

After this, git becomes authoritative again and future changes to the
variable's value, not newly adding it, reconcile normally without the
manual patch.
