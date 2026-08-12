#!/usr/bin/env bash
# Post-sync sanity check. Shows the app-of-apps tree, the generated
# ConfigMaps/Secrets, and proves the Vault agent actually injected secrets.
set -uo pipefail

hr() { printf '\n=== %s %s\n' "$1" "$(printf '=%.0s' $(seq 1 $((60 - ${#1}))))"; }

hr "Applications (app-of-apps tree)"
oc get applications -n openshift-gitops \
  -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status'

hr "AppProjects (the platform/application privilege split)"
oc get appprojects -n openshift-gitops \
  -o custom-columns='NAME:.metadata.name,CLUSTER-ALLOWED:.spec.clusterResourceWhitelist[*].kind'

hr "Namespaces created via managedNamespaceMetadata"
# The vault-injection label is what the webhook's namespaceSelector matches.
oc get ns payments-demo inventory-demo -L demo.redhat.com/vault-injection 2>/dev/null

hr "Vault platform"
oc get pods -n vault-demo
echo
oc get jobs -n vault-demo 2>/dev/null
echo
echo "-- seed job log (tail) --"
oc logs -n vault-demo -l app.kubernetes.io/name=vault-seed --tail=25 2>/dev/null \
  || echo "   (hook job already cleaned up - that is normal)"

hr "Kustomize-generated config (note the content hashes)"
for ns in payments-demo inventory-demo; do
  echo "-- $ns --"
  oc get cm,secret -n "$ns" -l app.kubernetes.io/part-of --no-headers 2>/dev/null \
    | awk '{print "   " $1}'
done

hr "Vault injection: containers per pod (app + vault-agent sidecar)"
for ns in payments-demo inventory-demo; do
  oc get pods -n "$ns" \
    -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CONTAINERS:.spec.containers[*].name,INIT:.spec.initContainers[*].name' \
    --no-headers 2>/dev/null
done

hr "Vault injection: the rendered secret files"
check_injected() {
  local ns=$1 app=$2 file=$3 pod
  pod=$(oc get pod -n "$ns" -l "app.kubernetes.io/name=$app" -o name 2>/dev/null | head -1)
  [[ -n "$pod" ]] || { echo "-- $ns/$app: no pod found --"; return; }
  echo "-- $ns/$app $file --"
  oc exec -n "$ns" "$pod" -c app -- cat "$file" 2>/dev/null | sed 's/^/   /' \
    || echo "   could not read - is the pod ready?"
}
check_injected payments-demo  payments-api  /vault/secrets/database.properties
check_injected inventory-demo inventory-web /vault/secrets/api.properties

hr "Images actually running (all should be @sha256 digests)"
for ns in vault-demo payments-demo inventory-demo; do
  oc get pods -n "$ns" -o jsonpath='{range .items[*]}{range .spec.containers[*]}   {.image}{"\n"}{end}{end}' 2>/dev/null
done | sort -u

hr "Routes"
for ns in payments-demo inventory-demo; do
  oc get route -n "$ns" -o jsonpath='{range .items[*]}   https://{.spec.host}{"\n"}{end}' 2>/dev/null
done
echo
