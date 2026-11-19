#!/usr/bin/env bash
# Fail if any PodDisruptionBudget in this repo covers a workload that is pinned to a
# single node. Such a budget cannot protect anything — it can only deadlock a drain.
#
# Why this exists. A PDB holds `currentHealthy` above a floor on the assumption that an
# evicted pod reschedules somewhere else and restores the count. A workload whose
# nodeSelector matches exactly one node breaks that assumption: drain the node and the
# replacement pod has nowhere to land, so `currentHealthy` never recovers,
# `disruptionsAllowed` sticks at 0, and every remaining pod refuses eviction with
# `Cannot evict pod as it would violate the pod's disruption budget` until the drain
# times out. codefolio shipped exactly that shape (replicas: 2, nodeSelector
# `kakde.eu/edge`, maxUnavailable: 1) and added a 300 s stall to a public outage during
# the 2026-11-18 K3s upgrade. See deploy/dr/UPGRADE.md U4.1.
#
# UNLIKE EVERY OTHER SCRIPT IN scripts/dr/, THIS ONE IS STATIC. It does not ssh to ms-1
# and never contacts the cluster: it renders the manifests in Git and reasons about them
# against deploy/inventory/nodes.yaml. So it works on a laptop with no VPN, no kubeconfig
# and the cluster down — which is when you most want to ask this question. The flip side
# is that it checks what is *committed*, not what is *running*: a PDB applied by hand is
# invisible to it, and so is a node label added live but never recorded in the inventory.
# `kubectl get pdb -A` is the live counterpart.
#
# Read-only. Exits 0 when no budget is pinned, 1 when one is, 2 on a usage or tool error.
#
# Usage:
#   scripts/dr/check-pdb-pinning.sh [repo-root]
set -euo pipefail

REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
NODES="$REPO/deploy/inventory/nodes.yaml"

for tool in kubectl yq jq; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
[[ -f "$NODES" ]] || { echo "node inventory not found: $NODES" >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
: > "$workdir/docs.ndjson"

# Render every kustomization, tagging each document with the overlay it came from, so a
# base and its overlays are never mistaken for one another.
rendered=0
while IFS= read -r kfile; do
  dir="$(dirname "$kfile")"
  rel="${dir#"$REPO"/}"
  if ! out="$(kubectl kustomize "$dir" 2>&1)"; then
    echo "render failed: $rel" >&2
    printf '%s\n' "$out" | head -3 >&2
    exit 2
  fi
  SRC="$rel" yq -o=json -I0 'select(.kind != null) | . + {"_src": strenv(SRC)}' <<<"$out" \
    >> "$workdir/docs.ndjson"
  rendered=$((rendered + 1))
done < <(find "$REPO/deploy" -name kustomization.yaml | sort)

yq -o=json -I0 '.' "$NODES" > "$workdir/nodes.json"

report="$(jq -r -s -f /dev/stdin \
  --slurpfile inv "$workdir/nodes.json" \
  "$workdir/docs.ndjson" <<'JQ'
# Does a pod spec tolerate one inventory taint, written "key=value:Effect"?
def tolerates($tolerations; $taint):
    ($taint | capture("^(?<key>[^=:]+)(=(?<value>[^:]*))?:(?<effect>.+)$")) as $t
    | any(($tolerations // [])[];
          (.key == null or .key == $t.key)
          and ((.effect // "") == "" or .effect == $t.effect)
          and ((.operator // "Equal") == "Exists"
               or ((.value // "") | tostring) == (($t.value // "") | tostring)));

# Nodes this pod spec could actually land on: labels must match AND every NoSchedule
# taint must be tolerated. Skipping the taint half would count ms-1 and ctb-edge-1 as
# available to ordinary workloads and make this check falsely reassuring.
def eligible($nodes; $selector; $tolerations):
    [ $nodes[]
      | . as $n
      | select( ($selector // {}) | to_entries
                | all( ($n.labels[.key] // null | tostring) == (.value | tostring) ) )
      | select( [ $n.taints[]
                  | select(endswith(":NoSchedule"))
                  | select(tolerates($tolerations; .) | not) ] | length == 0 ) ];

# The Kubernetes node name is doc_name where it differs from the SSH alias: vm-1 is
# ctb-edge-1 in the cluster. Matching the alias alone would silently miss the edge node.
($inv[0].nodes | map({
   name:   (.doc_name // .name),
   labels: ((.k3s.expected_labels // {}) + {"kubernetes.io/hostname": (.doc_name // .name)}),
   taints: (.k3s.expected_taints // [])
 })) as $nodes
| ( map(select(.kind == "Deployment" or .kind == "StatefulSet")
      | { src: ._src, ns: (.metadata.namespace // ""), name: .metadata.name, kind: .kind,
          replicas: (.spec.replicas // 1),
          labels: (.spec.template.metadata.labels // {}),
          nodeSelector: (.spec.template.spec.nodeSelector // {}),
          tolerations: (.spec.template.spec.tolerations // []) }) ) as $workloads
| ( map(select(.kind == "PodDisruptionBudget")
      | { src: ._src, ns: (.metadata.namespace // ""), name: .metadata.name,
          match: (.spec.selector.matchLabels // {}),
          budget: (if .spec.maxUnavailable != null
                   then "maxUnavailable=\(.spec.maxUnavailable)"
                   else "minAvailable=\(.spec.minAvailable)" end) }) ) as $pdbs
| [ $pdbs[]
    | . as $p
    | ( [ $workloads[]
          | . as $w
          | select(.src == $p.src and .ns == $p.ns)
          | select( $p.match | to_entries
                    | all( ($w.labels[.key] // null | tostring) == (.value | tostring) ) ) ]
      ) as $covered
    | if ($covered | length) == 0
      then { verdict: "ORPHAN", pdb: $p, workload: null, nodes: [] }
      else $covered[]
           | . as $w
           | (eligible($nodes; $w.nodeSelector; $w.tolerations)) as $e
           | { verdict: (if ($e | length) < 2 then "DEADLOCK" else "ok" end),
               pdb: $p, workload: $w, nodes: ($e | map(.name)) }
      end ] as $results
| ( $results[]
    | "  [\(if .verdict == "ok" then "ok      " else .verdict end)] \(.pdb.ns)/\(.pdb.name)"
      + "  \(.pdb.budget)  "
      + (if .workload == null then "selector matches no workload"
         else "replicas=\(.workload.replicas)  pinned="
              + (if (.workload.nodeSelector | length) == 0 then "(unpinned)"
                 else (.workload.nodeSelector | tostring) end)
              + "  schedulable=\(.nodes | length) \(.nodes | tostring)"
         end) ),
  "",
  ( [ $results[] | select(.verdict != "ok") ] as $bad
    | if ($bad | length) == 0
      then "PASS: no PodDisruptionBudget covers a single-node-pinned workload."
      else ( "FAIL",
             ( $bad[]
               | if .verdict == "ORPHAN"
                 then "  - PDB \(.pdb.ns)/\(.pdb.name): selector matches no workload (orphan)"
                 else "  - PDB \(.pdb.ns)/\(.pdb.name) (\(.pdb.budget)) covers "
                      + "\(.workload.kind) \(.workload.name) with nodeSelector "
                      + "\(.workload.nodeSelector | tostring), which leaves \(.nodes | length) "
                      + "schedulable node(s). A drain of that node can never satisfy the budget."
                 end ) )
      end )
JQ
)"

pairs="$(grep -c '^  \[' <<<"$report" || true)"
echo "rendered $rendered kustomizations, $pairs budget/workload pair(s)"
printf '%s\n' "$report"
grep -q '^FAIL$' <<<"$report" && exit 1
exit 0
