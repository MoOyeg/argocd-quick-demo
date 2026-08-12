#!/usr/bin/env bash
# Practice: "Validate manifests via Linting".
#
# Runs the same checks CI runs (.github/workflows/validate.yaml), so problems
# surface in a pull request instead of in a failed sync. Three stages:
#
#   1. render     - kustomize build every kustomization.yaml
#   2. schema     - kubeconform against Kubernetes + CRD schemas (if installed)
#   3. policy     - repo-specific rules the schema check cannot express
#
# Stage 2 is skipped with a warning if kubeconform is not on PATH; stages 1 and
# 3 always run and need nothing but kustomize and python3.
set -uo pipefail

cd "$(dirname "$0")/.."

RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

rc=0
fail() { printf '  FAIL  %s\n' "$1"; rc=1; }
ok()   { printf '  ok    %s\n' "$1"; }

# --- 1. render --------------------------------------------------------------
echo "==> rendering kustomizations"
mapfile -t KFILES < <(find . -name kustomization.yaml -not -path './.git/*' | sort)
for kfile in "${KFILES[@]}"; do
  dir=$(dirname "$kfile")
  out="$RENDER_DIR/$(echo "${dir#./}" | tr '/' '_').yaml"
  if err=$(kustomize build "$dir" -o "$out" 2>&1); then
    n=$(grep -c '^kind:' "$out")
    printf '  ok    %-48s %2d resources\n' "$dir" "$n"
  else
    fail "$dir"
    sed 's/^/          /' <<<"$err"
  fi
done
[[ $rc -eq 0 ]] || { echo; echo "render failed - stopping" >&2; exit 1; }

# --- 2. schema validation ---------------------------------------------------
echo
echo "==> schema validation"
if command -v kubeconform >/dev/null 2>&1; then
  # CRD schemas (Application, AppProject) come from the community catalog;
  # -ignore-missing-schemas keeps anything still unknown non-fatal.
  #
  # Known gap: route.openshift.io/Route is not in the catalog, so the two
  # Routes are reported as "skipped" rather than validated. To close it, run
  # against a live cluster, which validates every kind including OpenShift's:
  #   kustomize build <dir> | oc apply --dry-run=server -f -
  if kubeconform \
      -strict \
      -summary \
      -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$RENDER_DIR"/*.yaml; then
    ok "kubeconform"
  else
    fail "kubeconform"
  fi
else
  echo "  SKIP  kubeconform not installed"
  echo "        go install github.com/yannh/kubeconform/cmd/kubeconform@latest"
  echo "        (CI installs it - see .github/workflows/validate.yaml)"
fi

# --- 3. policy checks -------------------------------------------------------
echo
echo "==> policy checks"
python3 - "$RENDER_DIR" <<'PY'
import glob, os, sys, yaml

render_dir = sys.argv[1]
problems = []
warnings = []
apps = 0

# Load every rendered overlay, keyed by the source directory it came from.
rendered = {}
for path in sorted(glob.glob(os.path.join(render_dir, "*.yaml"))):
    src = os.path.basename(path)[:-5].replace("_", "/")
    with open(path) as fh:
        rendered[src] = [d for d in yaml.safe_load_all(fh) if d]

# Only enforce the image policy on directories an Application actually
# deploys. A base/ is an intermediate artifact - it is never applied to a
# cluster on its own, and pinning digests there would stop overlays from
# choosing their own build. Derive the deployable set from the Applications
# themselves so this stays honest as the repo grows.
deployable = {"apps", "bootstrap"}
for docs in rendered.values():
    for doc in docs:
        if doc.get("kind") == "Application":
            p = doc.get("spec", {}).get("source", {}).get("path")
            if p:
                deployable.add(p.strip("/"))

for src, docs in sorted(rendered.items()):
    is_deployable = src in deployable
    for doc in docs:
        kind = doc.get("kind", "?")
        name = doc.get("metadata", {}).get("name", "?")
        where = f"{src} {kind}/{name}"

        # Every container image must be digest-pinned. "Version manifests".
        specs = []
        if is_deployable and kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
            specs.append(doc["spec"]["template"]["spec"])
        elif is_deployable and kind == "Pod":
            specs.append(doc["spec"])
        for spec in specs:
            for c in spec.get("initContainers", []) + spec.get("containers", []):
                img = c.get("image", "")
                if img.endswith(":latest") or ":" not in img.split("/")[-1]:
                    problems.append(f"{where}: floating image tag {img!r}")
                elif "@sha256:" not in img:
                    problems.append(f"{where}: image not digest-pinned {img!r}")

        if kind == "Application":
            apps += 1
            spec = doc.get("spec", {})
            ann = doc.get("metadata", {}).get("annotations", {}) or {}

            # "Do not use the Default AppProject".
            if spec.get("project", "default") == "default":
                problems.append(f"{where}: uses the default AppProject")

            # "Version manifests" - HEAD tracking is the anti-pattern.
            rev = str(spec.get("source", {}).get("targetRevision", ""))
            if rev.upper() in ("HEAD", "LATEST", ""):
                problems.append(f"{where}: targetRevision {rev!r} tracks HEAD")
            elif rev in ("main", "master", "develop", "trunk"):
                # Not fatal: the quickstart uses a branch so the demo is easy
                # to drive. Still called out - a branch moves under you, and a
                # re-sync months later will not deploy what you tested.
                warnings.append(
                    f"{where}: targetRevision {rev!r} is a branch; "
                    "prefer a git tag or commit SHA")

            # "Monorepo scaling considerations".
            if "argocd.argoproj.io/manifest-generate-paths" not in ann:
                problems.append(f"{where}: missing manifest-generate-paths")

        if kind == "AppProject":
            spec = doc.get("spec", {})
            # "Define Tenant RBAC in AppProject".
            if not spec.get("roles"):
                problems.append(f"{where}: no roles defined")
            # An allow-list of "*" is the same as no allow-list.
            for entry in spec.get("clusterResourceWhitelist", []) or []:
                if entry.get("group") == "*" and entry.get("kind") == "*":
                    problems.append(f"{where}: clusterResourceWhitelist is '*'")

# --- cross-check: does each Application's output fit inside its AppProject? --
# Catches the "resource is not permitted in project X" sync failure at PR time
# rather than at 2am. Kinds are classified by the small hardcoded set below;
# anything not listed is assumed namespaced, which is true for everything this
# repo deploys.
CLUSTER_SCOPED = {
    "Namespace", "ClusterRole", "ClusterRoleBinding",
    "MutatingWebhookConfiguration", "ValidatingWebhookConfiguration",
    "CustomResourceDefinition", "PersistentVolume", "Node",
}

projects = {}
applications = []
for docs in rendered.values():
    for doc in docs:
        if doc.get("kind") == "AppProject":
            projects[doc["metadata"]["name"]] = doc.get("spec", {})
        elif doc.get("kind") == "Application":
            applications.append(doc)

def permitted(spec, group, kind, cluster_scoped):
    tier = "cluster" if cluster_scoped else "namespace"
    allow = spec.get(f"{tier}ResourceWhitelist") or []
    deny = spec.get(f"{tier}ResourceBlacklist") or []
    def matches(rules):
        return any((r.get("group") in (group, "*")) and (r.get("kind") in (kind, "*"))
                   for r in rules)
    if matches(deny):                      # blacklist beats whitelist
        return False
    if not allow:
        # An empty cluster whitelist denies everything; an empty namespace
        # whitelist allows everything. That asymmetry is Argo CD's, not ours.
        return not cluster_scoped
    return matches(allow)

checked = 0
for app in applications:
    spec = app.get("spec", {})
    proj_name = spec.get("project")
    path = (spec.get("source", {}).get("path") or "").strip("/")
    proj = projects.get(proj_name)
    if proj is None or path not in rendered:
        continue                            # project or path defined elsewhere
    checked += 1
    app_name = app["metadata"]["name"]
    for doc in rendered[path]:
        kind = doc.get("kind", "?")
        api = doc.get("apiVersion", "v1")
        group = api.rsplit("/", 1)[0] if "/" in api else ""
        cs = kind in CLUSTER_SCOPED
        if not permitted(proj, group, kind, cs):
            rname = doc.get("metadata", {}).get("name", "?")
            scope = "cluster-scoped" if cs else "namespaced"
            problems.append(
                f"{path} {kind}/{rname} ({scope}, group {group or 'core'!r}): "
                f"not permitted in AppProject {proj_name!r} "
                f"used by Application {app_name!r}")

for w in warnings:
    print(f"  WARN  {w}")

if problems:
    for p in problems:
        print(f"  FAIL  {p}")
    sys.exit(1)

print(f"  ok    images digest-pinned")
print(f"  ok    {apps} Applications: non-default project, generate-paths present")
print(f"  ok    {checked} Applications render only kinds their AppProject permits")
print(f"  ok    AppProjects: tenant roles present, no wildcard cluster allow-list")
PY
[[ $? -eq 0 ]] || rc=1

echo
if [[ $rc -eq 0 ]]; then
  echo "All checks passed."
else
  echo "Some checks failed." >&2
fi
exit $rc
