#!/usr/bin/env bash
# import-docker-desktop-kube
#
# Make Docker Desktop's Kubernetes usable from the toolbox container.
#
# The toolbox keeps its own kubeconfig on the persistent volume (~/.kube/config) and
# cannot see the Windows one. This copies ONE context out of the host kubeconfig
# (mounted read-only at $DD_SRC) into the toolbox kubeconfig and repoints its API
# server at the Docker Desktop host, because "localhost" or kubernetes.docker.internal
# inside a container does not mean the host. TLS is still verified, against the
# original server name (--tls-server-name).
#
# Usage:  import-docker-desktop-kube [context]          (default: docker-desktop)
# Env:    DD_SRC   host kubeconfig path                  (default /hostkube/config)
#         DD_HOST  name that reaches the host from here  (default host.docker.internal)
# Exit:   0 imported and reachable, 1 bad input, 3 imported but API server unreachable
set -euo pipefail

CTX="${1:-docker-desktop}"
SRC="${DD_SRC:-/hostkube/config}"
HOST_ALIAS="${DD_HOST:-host.docker.internal}"
DST="${HOME}/.kube/config"

die() { echo "error: $*" >&2; exit 1; }

[ -f "$SRC" ] || die "no host kubeconfig at $SRC (was it mounted?)"

# Capture first, grep second: piping into `grep -q` under pipefail can SIGPIPE kubectl.
contexts=$(kubectl --kubeconfig "$SRC" config get-contexts -o name)
if ! grep -qxF "$CTX" <<<"$contexts"; then
  {
    echo "error: context '$CTX' not found in the host kubeconfig. Found:"
    while IFS= read -r name; do echo "  $name"; done <<<"$contexts"
    echo "Enable Kubernetes in Docker Desktop (Settings > Kubernetes), wait for Running, retry."
  } >&2
  exit 1
fi

tmp=$(mktemp)
prev=$(mktemp)
merged=$(mktemp)
trap 'rm -f "$tmp" "$prev" "$merged"' EXIT

# 1. Pull out just that context (with its cluster and user), self-contained.
#    Nothing else from the host kubeconfig is read into the volume.
kubectl --kubeconfig "$SRC" config view --minify --flatten --context "$CTX" > "$tmp"
KUBECONFIG="$tmp" kubectl config use-context "$CTX" > /dev/null

# 2. Point the API server at the host; keep verifying TLS against the original name.
cluster=$(KUBECONFIG="$tmp" kubectl config view --minify -o jsonpath='{.clusters[0].name}')
server=$(KUBECONFIG="$tmp" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
authority=${server#*://}
authority=${authority%%/*}
case "$authority" in
  *:*) orig_host=${authority%:*}; port=${authority##*:} ;;
  *)   orig_host=$authority;      port=443 ;;
esac
KUBECONFIG="$tmp" kubectl config set-cluster "$cluster" \
  --server="https://${HOST_ALIAS}:${port}" --tls-server-name="$orig_host" > /dev/null

# 3. Merge into the toolbox kubeconfig. kubectl merges same-named entries FIELD BY
#    FIELD, so a stale server or CA from an earlier import would leak into the new
#    entry. Drop any earlier copy of this context from a scratch copy first, then merge;
#    everything else already in the kubeconfig is kept. $DST is only replaced at the end.
user=$(KUBECONFIG="$tmp" kubectl config view --minify -o jsonpath='{.users[0].name}')
mkdir -p "$(dirname "$DST")"
if [ -f "$DST" ]; then
  cp -p "$DST" "${DST}.bak"
  cp "$DST" "$prev"
  KUBECONFIG="$prev" kubectl config delete-context "$CTX"     > /dev/null 2>&1 || true
  KUBECONFIG="$prev" kubectl config delete-cluster "$cluster" > /dev/null 2>&1 || true
  KUBECONFIG="$prev" kubectl config delete-user "$user"       > /dev/null 2>&1 || true
fi
KUBECONFIG="$tmp:$prev" kubectl config view --flatten > "$merged"
install -m 600 "$merged" "$DST"

echo "Imported '$CTX': https://${HOST_ALIAS}:${port} (TLS name ${orig_host}), now the current context."

# 4. Prove it from inside the container.
if out=$(kubectl --context "$CTX" --request-timeout=10s get --raw /version 2>&1); then
  version=$(sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' <<<"$out" | head -n 1)
  echo "Connected to Kubernetes ${version:-(version unknown)}."
  echo "Try:  kubectl get nodes   |   kubens   |   kubectx"
  exit 0
fi

code=$(curl -sk --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' \
  "https://${HOST_ALIAS}:${port}/version" || true)
{
  echo "Imported, but the API server did not answer from inside the container."
  echo "  kubectl: ${out}"
  echo "  direct probe, no proxy: https://${HOST_ALIAS}:${port}/version -> HTTP ${code}"
  echo "  000 = unreachable: check Kubernetes shows Running in Docker Desktop, and any VPN or firewall."
  echo "  anything else = reachable: the kubectl error above is TLS or a proxy in the way."
} >&2
exit 3
