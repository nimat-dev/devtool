#!/usr/bin/env bash
# Smoke test that runs INSIDE the built image, through its entrypoint:
#
#   docker run --rm -v "$PWD/tests:/tests:ro" -e EXPECT_KUBECTL=1.31.4 ... \
#       devtools:ci bash /tests/smoke.sh
#
# Every tool must start. Tools pinned in the Dockerfile must report the pinned version
# (the pins arrive as EXPECT_* variables; an empty one means "any version"). Then the
# image plumbing is checked: entrypoint, Terraform plugin cache, helper scripts.
set -u

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# check NAME WANT COMMAND...
#   WANT is a substring the output must contain; empty means exit status 0 is enough.
check() {
  local name=$1 want=$2 out
  shift 2
  if ! out=$("$@" 2>&1); then
    bad "$name: exited non-zero: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
    return
  fi
  if [ -n "$want" ] && ! printf '%s\n' "$out" | grep -qF -- "$want"; then
    bad "$name: wanted '$want', got: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
    return
  fi
  ok "$(printf '%-10s %s' "$name" "$(printf '%s\n' "$out" | head -n 1)")"
}

# "v" + version, or nothing when no pin was passed in
v() { if [ -n "${1:-}" ]; then printf 'v%s' "$1"; fi; }

echo "--- tools ---"
check az        ""                                  az version --query '"azure-cli"' --output tsv
check azd       ""                                  azd version
check kubectl   "$(v "${EXPECT_KUBECTL:-}")"        kubectl version --client
check kubelogin "${EXPECT_KUBELOGIN:-}"             kubelogin --version
check kubectx   ""                                  kubectx -h
check kubens    ""                                  kubens -h
check helm      "$(v "${EXPECT_HELM:-}")"           helm version --short
check kustomize "$(v "${EXPECT_KUSTOMIZE:-}")"      kustomize version
check terraform "${EXPECT_TERRAFORM:-}"             terraform version
check flux      "${EXPECT_FLUX:-}"                  flux --version
check aws       "${EXPECT_AWSCLI:-}"                aws --version
check gh        "${EXPECT_GH:-}"                    gh --version
check yq        "${EXPECT_YQ:-}"                    yq --version
check jq        ""                                  jq --version
check git       ""                                  git --version
check make      ""                                  make --version
check ssh       ""                                  ssh -V
check curl      ""                                  curl --version
check unzip     ""                                  unzip -v

echo
echo "--- image plumbing ---"
case "${NO_PROXY:-}" in
  *host.docker.internal*) ok "entrypoint appends host.docker.internal to NO_PROXY" ;;
  *) bad "NO_PROXY lacks host.docker.internal: '${NO_PROXY:-}'" ;;
esac
case "${no_proxy:-}" in
  *kubernetes.docker.internal*) ok "entrypoint appends kubernetes.docker.internal to no_proxy" ;;
  *) bad "no_proxy lacks kubernetes.docker.internal: '${no_proxy:-}'" ;;
esac
case "${NO_PROXY:-}" in
  *localhost*) ok "entries already in NO_PROXY are kept" ;;
  *) bad "default NO_PROXY entries were lost: '${NO_PROXY:-}'" ;;
esac

if [ "${TF_PLUGIN_CACHE_DIR:-}" = /root/.terraform.d/plugin-cache ] \
   && [ -d "${TF_PLUGIN_CACHE_DIR:-/nonexistent}" ] \
   && grep -q 'plugin_cache_dir' /root/.terraformrc; then
  ok "terraform plugin cache directory exists and is configured"
else
  bad "terraform plugin cache is not set up (TF_PLUGIN_CACHE_DIR='${TF_PLUGIN_CACHE_DIR:-}')"
fi

if [ "$(pwd)" = /work ]; then
  ok "working directory is /work"
else
  bad "working directory is $(pwd), expected /work"
fi

for f in import-docker-desktop-kube devtools-entrypoint; do
  p=/usr/local/bin/$f
  if [ -x "$p" ] && ! grep -q $'\r' "$p"; then
    ok "$f is installed, executable and has LF line endings"
  else
    bad "$f is missing, not executable, or has CRLF line endings"
  fi
done

out=$(import-docker-desktop-kube 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'no host kubeconfig'; then
  ok "import-docker-desktop-kube fails cleanly when no kubeconfig is mounted"
else
  bad "import-docker-desktop-kube without a kubeconfig: rc=$rc output='$out'"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
