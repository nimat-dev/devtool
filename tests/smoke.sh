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

for f in import-docker-desktop-kube devtools-entrypoint devtools-complete; do
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

# ---------------------------------------------------------------------------------------------
# The interactive shell (dev): zsh with suggestions and completion, bash with the same aliases.
# tests/pty_shell_test.py types into a real terminal; this checks that everything is in place.
# ---------------------------------------------------------------------------------------------
echo
echo "--- interactive shell ---"

for f in /etc/devtools/aliases.sh /etc/devtools/az-completion.sh /etc/devtools/bashrc /etc/devtools/zdot/.zshrc; do
  if [ -r "$f" ] && ! grep -q $'\r' "$f"; then
    ok "$f is installed with LF line endings"
  else
    bad "$f is missing or has CRLF line endings"
  fi
done

if command -v zsh > /dev/null 2>&1 && [ "${ZDOTDIR:-}" = /etc/devtools/zdot ] && [ -f /etc/devtools/zdot/.zcompdump ]; then
  ok "zsh is installed, reads /etc/devtools/zdot and has a completion cache"
else
  bad "zsh, ZDOTDIR (='${ZDOTDIR:-}') or the completion cache /etc/devtools/zdot/.zcompdump is missing"
fi
for plugin in zsh-autosuggestions/zsh-autosuggestions.zsh zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
  if [ -r "/usr/share/$plugin" ]; then ok "/usr/share/$plugin is installed"; else bad "/usr/share/$plugin is missing"; fi
done

if grep -q '/etc/devtools/bashrc' /etc/bash.bashrc; then
  ok "/etc/bash.bashrc loads the toolbox bash settings"
else
  bad "/etc/bash.bashrc does not load /etc/devtools/bashrc"
fi

for t in kubectl helm flux kustomize azd gh; do
  if [ -s "/usr/share/bash-completion/completions/$t" ] && [ -s "/usr/share/zsh/vendor-completions/_$t" ]; then
    ok "Tab completion scripts for $t (bash and zsh)"
  else
    bad "Tab completion scripts for $t are missing or empty"
  fi
done

# Starting a shell must be silent: no errors from the rc files. Without a terminal bash says
# that it has no job control; that is not an error in the files.
quiet() { grep -v -e 'cannot set terminal process group' -e 'no job control' || true; }
out=$(zsh -ic true 2>&1 < /dev/null | quiet)
if [ -z "$out" ]; then ok "zsh starts without a message"; else bad "zsh printed on start: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"; fi
out=$(bash -ic true 2>&1 < /dev/null | quiet)
if [ -z "$out" ]; then ok "bash starts without a message"; else bad "bash printed on start: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"; fi

zout=$(zsh -ic 'alias kgp; whence -w aksx; print -r -- "HIST=$HISTFILE"; print -r -- "AS=${+functions[_zsh_autosuggest_start]} HL=${ZSH_HIGHLIGHT_VERSION:-none}"; print -r -- "COMPS=${+_comps[kubectl]}${+_comps[helm]}${+_comps[flux]}${+_comps[kustomize]}${+_comps[azd]}${+_comps[gh]}${+_comps[terraform]}${+_comps[az]}"' 2>&1 < /dev/null | quiet)
case "$zout" in *"kgp='kubectl get pods'"*) ok "zsh: the alias kgp is defined" ;; *) bad "zsh: alias kgp missing: $zout" ;; esac
case "$zout" in *"aksx: function"*) ok "zsh: the function aksx is defined" ;; *) bad "zsh: aksx missing: $zout" ;; esac
case "$zout" in *"HIST=/root/.zsh_history"*) ok "zsh: history is kept in /root/.zsh_history (the volume)" ;; *) bad "zsh: wrong history file: $zout" ;; esac
case "$zout" in *"AS=1 HL="*) ;; *) bad "zsh: autosuggestions are not loaded: $zout" ;; esac
case "$zout" in *"HL=none"*) bad "zsh: syntax highlighting is not loaded: $zout" ;; *"AS=1 HL="*) ok "zsh: autosuggestions and syntax highlighting are loaded" ;; esac
case "$zout" in *"COMPS=11111111"*) ok "zsh: Tab completion is set up for kubectl helm flux kustomize azd gh terraform az" ;; *) bad "zsh: some completions are not registered: $zout" ;; esac

bout=$(bash -ic 'alias kgp; type aksx | head -n 1; complete -p k tf terraform az kgp' 2>&1 < /dev/null | quiet)
case "$bout" in *"kgp='kubectl get pods'"*) ok "bash: the alias kgp is defined" ;; *) bad "bash: alias kgp missing: $bout" ;; esac
case "$bout" in *"aksx is a function"*) ok "bash: the function aksx is defined" ;; *) bad "bash: aksx missing: $bout" ;; esac
case "$bout" in *"__start_kubectl k"*) ok "bash: k completes like kubectl" ;; *) bad "bash: k has no completion: $bout" ;; esac
# bash prints the command of "complete -C" with or without quotes depending on its version.
if grep -Eq "^complete -C '?/usr/bin/terraform'? tf\$" <<< "$bout" && grep -Eq "^complete -C '?/usr/bin/terraform'? terraform\$" <<< "$bout"; then
  ok "bash: terraform and tf complete through terraform itself"
else
  bad "bash: terraform/tf have no completion: $bout"
fi
case "$bout" in *"_devtools_complete_alias kgp"*) ok "bash: shortcuts such as kgp complete through the tool" ;; *) bad "bash: kgp has no completion: $bout" ;; esac
case "$bout" in *"_devtools_az_complete az"*) ok "bash: az completes through argcomplete" ;; *) bad "bash: az has no completion: $bout" ;; esac

# devtools-complete is what PowerShell asks on Tab: the real tool in the image answers.
check_complete() {
  local name=$1 want=$2 out
  shift 2
  out=$(devtools-complete "$@" 2>&1)
  if printf '%s\n' "$out" | grep -qE -- "$want"; then
    ok "devtools-complete: $name"
  else
    bad "devtools-complete: $name: wanted '$want', got: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
  fi
}
check_complete "kubectl cre -> create"        '^create'     kubectl   "kubectl cre"
check_complete "helm ins -> install"          '^install'    helm      "helm ins"
check_complete "flux boo -> bootstrap"        '^bootstrap'  flux      "flux boo"
check_complete "gh pr li -> list"             '^list'       gh        "gh pr li"
check_complete "kustomize bui -> build"       '^build'      kustomize "kustomize bui"
check_complete "azd ini -> init"              '^init'       azd       "azd ini"
check_complete "terraform ap -> apply"        '^apply'      terraform "terraform ap"
check_complete "az acc -> account"            '^account'    az        "az acc"
check_complete "kubectl get pods --all-nam"   '^--all-namespaces' kubectl "kubectl get pods --all-nam"
out=$(devtools-complete rm "rm -r" 2>&1; echo "rc=$?")
case "$out" in "rc=0") ok "devtools-complete ignores a tool it does not know" ;; *) bad "devtools-complete rm: $out" ;; esac
out=$(devtools-complete kubectl "kubectl nosuchcommand zzz" 2>&1; echo "rc=$?")
case "$out" in *"rc=0") ok "devtools-complete exits 0 when there is nothing to offer" ;; *) bad "devtools-complete with no answer: $out" ;; esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
