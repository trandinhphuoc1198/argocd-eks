# platform/monitoring-configs/

Plain (non-Helm) manifests, grouped by which ArgoCD Application/ApplicationSet
owns them. **One subdirectory = one owner.** Do not add a new manifest to an
existing subdirectory unless it truly belongs to that same owner — and never
reach for `directory.include`/`exclude` in an Application source as a way to
share a directory between owners. That pattern is what caused a Service
ownership collision between `kube-prometheus-stack` and
`cilium-servicemonitors` on hub (see git history) — ArgoCD couldn't tell
which Application was supposed to own `monitoring-hub-prometheus`.

New manifest that doesn't fit `cilium/` or `mesh/`? Give it its own
subdirectory and its own Application/ApplicationSet source path.