#!/usr/bin/env bash
# End-to-end test of the Docker Desktop Kubernetes import, using the REAL image.
#
#   tests/e2e-import.sh [image]        (default: devtools:ci)
#
# Needs docker, openssl, python3 and curl on the host. The host stands in for Docker
# Desktop:
#   - a fake Kubernetes API server listens on it, with a certificate that is valid ONLY
#     for kubernetes.docker.internal (like Docker Desktop's real one)
#   - a "host kubeconfig" points at that name and also holds an unrelated second context
#     whose secret must never reach the toolbox volume
#   - the container reaches the host as host.docker.internal. Docker Desktop provides
#     that name itself; on a plain Linux daemon --add-host host.docker.internal:host-gateway
#     does the same job.
set -uo pipefail

IMAGE=${1:-devtools:ci}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PORT=${E2E_PORT:-16443}
WORK=$(mktemp -d)
VOL="devtools-e2e-home-$$"
SERVER_PID=""
pass=0
fail=0

cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; fi
  docker volume rm -f "$VOL" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no '$2' in: $(printf '%s' "$3" | head -c 300))"; fi; }

# raw one-shot container that can see the host by name
dr() { docker run --rm --add-host host.docker.internal:host-gateway "$@"; }
# one-shot container against the persistent "toolbox home" volume, like the PowerShell wrappers
tool() { dr -v "$VOL:/root" "$IMAGE" "$@"; }
# the importer, with the host kubeconfig mounted read-only
import() { dr -v "$VOL:/root" -v "$WORK/hostkube/config:/hostkube/config:ro" "$IMAGE" import-docker-desktop-kube docker-desktop; }

# ---- PKI: server certificate valid only for kubernetes.docker.internal --------------
cd "$WORK" || exit 2
{
  openssl genrsa -out ca.key 2048
  openssl req -x509 -new -nodes -key ca.key -subj "/CN=docker-desktop-ca" -days 2 -out ca.crt
  openssl genrsa -out server.key 2048
  openssl req -new -key server.key -subj "/CN=kube-apiserver" -out server.csr
  printf 'subjectAltName=DNS:kubernetes.docker.internal\nextendedKeyUsage=serverAuth\n' > san.cnf
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile san.cnf -out server.crt
  openssl genrsa -out client.key 2048
  openssl req -new -key client.key -subj "/CN=docker-for-desktop" -out client.csr
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -out client.crt
} >/dev/null 2>&1
if [ ! -s client.crt ] || [ ! -s server.crt ]; then echo "PKI setup failed"; exit 2; fi

# ---- host kubeconfig, as Docker Desktop writes it, plus an unrelated secret context --
b64() { base64 -w0 "$1"; }
mkdir -p hostkube
cat > hostkube/config <<EOF
apiVersion: v1
kind: Config
clusters:
- name: docker-desktop
  cluster:
    server: https://kubernetes.docker.internal:$PORT
    certificate-authority-data: $(b64 ca.crt)
- name: minikube-secret
  cluster:
    server: https://192.168.49.2:8443
    certificate-authority-data: $(b64 ca.crt)
users:
- name: docker-desktop
  user:
    client-certificate-data: $(b64 client.crt)
    client-key-data: $(b64 client.key)
- name: minikube-secret
  user:
    token: SECRET-TOKEN-SHOULD-NOT-LEAK
contexts:
- name: docker-desktop
  context: {cluster: docker-desktop, user: docker-desktop}
- name: minikube-secret
  context: {cluster: minikube-secret, user: minikube-secret}
current-context: minikube-secret
EOF

# ---- start the fake API server on the host ---------------------------------------------
python3 "$HERE/fake_apiserver.py" "$PORT" "$WORK/server.crt" "$WORK/server.key" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  if curl -sk -m 2 "https://127.0.0.1:$PORT/version" 2>/dev/null | grep -q fake; then break; fi
  sleep 0.2
done
if ! curl -sk -m 2 "https://127.0.0.1:$PORT/version" 2>/dev/null | grep -q fake; then
  echo "fake API server did not start"; cat "$WORK/server.log"; exit 2
fi
echo "[setup] fake API server up on port $PORT, image under test: $IMAGE"

echo; echo "== A. import =="
out=$(import 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/      | /'
eq  "A1 import exits 0" 0 "$rc"
has "A2 container reached the host API and verified TLS" "Connected to Kubernetes v1.31.4-fake" "$out"

echo; echo "== B. resulting kubeconfig on the volume =="
eq "B1 server rewritten to the host alias" "https://host.docker.internal:$PORT" \
   "$(tool kubectl config view --raw -o 'jsonpath={.clusters[0].cluster.server}' 2>&1)"
eq "B2 tls-server-name keeps the original name" "kubernetes.docker.internal" \
   "$(tool kubectl config view --raw -o 'jsonpath={.clusters[0].cluster.tls-server-name}' 2>&1)"
eq "B3 only the docker-desktop context was imported" "docker-desktop" \
   "$(tool kubectl config get-contexts -o name 2>&1 | tr '\n' ' ' | sed 's/ $//')"
eq "B4 the unrelated context and its secret did not leak" "0" \
   "$(tool sh -c 'grep -c "SECRET-TOKEN\|minikube-secret" /root/.kube/config || true' 2>&1)"
eq "B5 kubeconfig is mode 600" "600" "$(tool stat -c %a /root/.kube/config 2>&1)"

echo; echo "== C. kubectx and kubens from the container =="
eq "C1 kubectx lists the imported context" "docker-desktop" "$(tool kubectx 2>&1)"
eq "C2 kubens lists namespaces from the API (container to host)" "default kube-public kube-system" \
   "$(tool kubens 2>&1 | sort | tr '\n' ' ' | sed 's/ $//')"
tool kubens kube-system >/dev/null 2>&1
eq "C3 kubens kube-system is remembered on the volume" "kube-system" \
   "$(tool kubectl config view --minify -o 'jsonpath={..namespace}' 2>&1)"

echo; echo "== D. re-import is idempotent =="
import >/dev/null 2>&1; rc=$?
eq "D1 second import exits 0" 0 "$rc"
eq "D2 still exactly one context" 1 "$(tool kubectl config get-contexts -o name 2>&1 | wc -l | tr -d ' ')"

echo; echo "== E. the certificate really is strict =="
neg=$(dr -v "$WORK/hostkube/config:/hostkube/config:ro" "$IMAGE" kubectl --kubeconfig /hostkube/config \
      --context docker-desktop --server "https://host.docker.internal:$PORT" get --raw /version 2>&1)
has "E1 without tls-server-name the host alias is rejected" \
    "certificate is valid for kubernetes.docker.internal, not host.docker.internal" "$neg"

echo; echo "== F. corporate proxy trap =="
DEAD=http://127.0.0.1:9
proxy_env=(-e "HTTP_PROXY=$DEAD" -e "HTTPS_PROXY=$DEAD" -e "http_proxy=$DEAD" -e "https_proxy=$DEAD")
if dr -v "$VOL:/root" "${proxy_env[@]}" --entrypoint kubectl "$IMAGE" \
      --context docker-desktop --request-timeout=8s get --raw /version >/dev/null 2>&1; then
  bad "F1 negative control: bypassing the entrypoint should have sent host traffic to the dead proxy"
else
  ok "F1 without the entrypoint, a proxy swallows the host traffic"
fi
out=$(dr -v "$VOL:/root" "${proxy_env[@]}" "$IMAGE" kubectl --context docker-desktop \
      --request-timeout=8s get --raw /version 2>&1)
has "F2 with the entrypoint, the same environment still reaches the host" "v1.31.4-fake" "$out"

echo; echo "== G. API server down =="
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
sleep 1
out=$(import 2>&1); rc=$?
eq  "G1 exits 3 when the API server is unreachable" 3 "$rc"
has "G2 diagnostic reports HTTP 000 (no route to the host API)" "HTTP 000" "$out"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
