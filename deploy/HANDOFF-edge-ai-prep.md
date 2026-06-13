# Handoff — `redistribute/edge-ai-prep`

Branch-scoped working notes. **Delete this file in the commit that deploys the
Gemma model**, once the prep below is applied and verified.

## Why this branch exists

`wk-1` is being set up to co-host **PostgreSQL + a local Gemma inference model**.
The 2026-06-07 wk-1 OOM incident showed the node is memory-contended, so before
the model lands this branch (1) gives the database hard OOM protection, (2) frees
RAM by moving stateless apps off wk-1, and (3) establishes the eviction ladder the
model will sit at the bottom of. **No model is deployed yet** — that is the
remaining work (see below).

## What this branch changed (committed)

| Commit | Change | Sync path |
|--------|--------|-----------|
| `feat(priorityclasses)` | New `data-tier` (1000000) + `ai-workload-low` (-50) classes | **Manual** (`deploy/platform/`) |
| `fix(postgresql)` | Guaranteed QoS (1 CPU / 2Gi, requests==limits) + `priorityClassName: data-tier` | **Manual** (`deploy/platform/`) |
| `refactor(apps)` | `codefolio` (prod overlay) + `likec4` (base) pinned to edge node | **Argo-synced** |
| `chore(whoami)` | Retired manifests for the whoami/oauth2-proxy demo | Manual (was never Argo-tracked) |

Eviction ladder this completes (high → low survives longest):

```
data-tier         1000000   PostgreSQL / stateful data   <-- protect
(default)         0         normal apps (codefolio, cortex, likec4…)
ai-workload-low   -50       Gemma model — bounded + sheddable   (defined, UNUSED until model lands)
go-judge-low      -100      untrusted code — first to die        (in deploy/apps/go-judge/)
```

## Apply / rollout — do these in order

> **Status — applied & verified 2026-06-13.** Steps 1–2 (priority classes,
> PostgreSQL QoS/priority) were already applied by hand on `ms-1` before the
> merge. Step 3 (`codefolio` + `likec4` edge pin) rolled out when this branch
> merged to `main` — Argo rescheduled both onto `ctb-edge-1`. Step 4 (`whoami`)
> has no live resources. Verified: postgres `qos=Guaranteed prio=data-tier` and
> Ready on wk-1, both apps `1/1` on the edge node, `kakde.eu` serving HTTP 200
> with a valid cert. The steps below are retained for rebuild value.
>
> (Verification ran just after a wk-1 reboot — kernel upgrade to `6.17.0-35` at
> 15:42 — which briefly took the node `NotReady`; postgres, go-judge and cortex
> recovered on their own once it rejoined.)

`deploy/platform/` is **not** Argo-synced; apply it by hand from `ms-1`. Order
matters: the PostgreSQL pod references `data-tier`, so the class must exist first
or admission rejects the pod (`no PriorityClass named "data-tier"`).

1. **Priority classes first** (cluster-scoped, no disruption):
   ```bash
   kubectl apply -f deploy/platform/priorityclasses/priorityclasses.yaml
   kubectl get priorityclass data-tier ai-workload-low
   ```
2. **PostgreSQL statefulset** — *rolls the pod* (120s grace). Do it in a quiet
   window; the DB is briefly down during the restart:
   ```bash
   kubectl apply -f deploy/platform/postgresql/6-statefulset.yaml
   # verify Guaranteed QoS + priority took effect:
   kubectl -n databases-prod get pod -l app=postgresql -o \
     'jsonpath={range .items[*]}{.metadata.name}{"  qos="}{.status.qosClass}{"  prio="}{.spec.priorityClassName}{"\n"}{end}'
   # expect: qos=Guaranteed  prio=data-tier
   ```
3. **codefolio + likec4** — Argo-synced. Let auto-sync run (or `argocd app sync
   codefolio likec4`), then confirm both rescheduled onto the edge node:
   ```bash
   kubectl -n apps-prod get pods -o wide | grep -E 'codefolio|likec4'
   # NODE column should be ctb-edge-1 for both
   ```
4. **whoami cleanup** — deleting the files does **not** remove live resources
   (was applied by hand, never Argo-tracked). Remove them manually:
   ```bash
   kubectl -n apps-prod delete deploy,svc,ingress -l app=whoami        # adjust selector if needed
   kubectl -n apps-prod get deploy,svc,ingress | grep -i whoami        # expect: nothing
   ```
   Also retire the public DNS for `whoami.kakde.eu` / `whoami-auth.kakde.eu`.

## Remaining work (not in this branch)

- [ ] **Deploy the Gemma model on wk-1** — the whole point of this prep. It must:
  - land on wk-1 (co-located with the DB): `nodeSelector: { kakde.eu/postgresql: "true" }`
    is the de-facto wk-1 label today. **Decide:** reuse it, or add a dedicated
    `kakde.eu/ai: "true"` label to wk-1 for clarity (recommended — `postgresql`
    reads wrong on a non-DB workload).
  - set `priorityClassName: ai-workload-low`.
  - set a **hard memory limit** so it stays bounded + sheddable (the class assumes this).
- [x] **Re-check edge node capacity** — done 2026-06-13. With Traefik + codefolio
  + likec4 all on `ctb-edge-1`, the node sits at ~12% memory / ~4% CPU
  (`kubectl top node ctb-edge-1`). Not memory-pressured; ample headroom.
- [ ] **likec4 placement style** — edge pinning is in `base`, so it has no per-env
  override. Fine today (no dev overlay exists), but if a `likec4` dev overlay is
  ever added, move the nodeSelector/tolerations to the prod overlay to match the
  `codefolio` pattern and keep dev on the home workers.

## Guardrails honored

- Only **Tier-2 (stateless, non-sensitive)** apps were moved to the **public**
  edge node — consistent with the edge-only ingress model. PostgreSQL and other
  sensitive/stateful services stay on the private home workers.
- `ai-workload-low` uses `preemptionPolicy: Never`: the model can never evict a
  running pod just to schedule itself.
