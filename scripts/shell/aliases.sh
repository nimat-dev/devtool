# Shortcuts for the shell inside the toolbox (bash and zsh). Sourced from bashrc and zshrc.
#
# Arguments you type after a shortcut are appended: "kgp -n kube-system" runs
# "kubectl get pods -n kube-system". The PowerShell side has the same list (Devtools.psm1) and a
# test keeps the two in step, so change both. `alias` prints what is defined here.
# Your own shortcuts go in ~/.devtools-aliases.sh, which is read after this file and wins.

# --- Azure ---------------------------------------------------------------------------------
alias azl='az login --use-device-code'
alias azwho='az account show -o table'
alias azsubs='az account list -o table'
alias azsub='az account set --subscription'
alias azrg='az group list -o table'
alias azres='az resource list -o table -g'
alias acrls='az acr repository list -o table -n'

# --- AKS and kubectl -----------------------------------------------------------------------
alias aksl='az aks list -o table'
alias k='kubectl'
alias kx='kubectx'
alias kn='kubens'
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kgn='kubectl get nodes'
alias kgd='kubectl get deployments'
alias kgs='kubectl get services'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias kex='kubectl exec -it'
alias kaf='kubectl apply -f'
alias krr='kubectl rollout restart'
alias ktop='kubectl top pods'

# --- Terraform -----------------------------------------------------------------------------
alias tf='terraform'
alias tfi='terraform init'
alias tfv='terraform validate'
alias tff='terraform fmt -recursive'
alias tfp='terraform plan -out=tfplan'
alias tfa='terraform apply tfplan'
alias tfo='terraform output'
alias tfs='terraform state list'
alias tfss='terraform state show'
alias tfw='terraform workspace list'
alias tfws='terraform workspace select'
alias tfdestroy='terraform destroy'

# --- AKS helpers ---------------------------------------------------------------------------
# The resource group and cluster name come from the two arguments, or from AKS_RG and AKS_NAME,
# so a private cluster's names never have to be typed or committed anywhere.
#   aksc [RG NAME] [flags]     az aks get-credentials ... --overwrite-existing
#   aksup [RG NAME] [flags]    az aks get-upgrades ... -o table
#   aksx "kubectl get nodes"   az aks command invoke ...  (runs the command inside a private cluster)
aksc() {
  local rg name
  if [ $# -ge 2 ] && [ "${1#-}" = "$1" ] && [ "${2#-}" = "$2" ]; then
    rg=$1 name=$2
    shift 2
  else
    rg=${AKS_RG:-} name=${AKS_NAME:-}
  fi
  if [ -z "$rg" ] || [ -z "$name" ]; then
    echo "aksc: give a resource group and a cluster name (aksc RG NAME), or set AKS_RG and AKS_NAME" >&2
    return 1
  fi
  az aks get-credentials -g "$rg" -n "$name" --overwrite-existing "$@"
}

aksup() {
  local rg name
  if [ $# -ge 2 ] && [ "${1#-}" = "$1" ] && [ "${2#-}" = "$2" ]; then
    rg=$1 name=$2
    shift 2
  else
    rg=${AKS_RG:-} name=${AKS_NAME:-}
  fi
  if [ -z "$rg" ] || [ -z "$name" ]; then
    echo "aksup: give a resource group and a cluster name (aksup RG NAME), or set AKS_RG and AKS_NAME" >&2
    return 1
  fi
  az aks get-upgrades -g "$rg" -n "$name" -o table "$@"
}

aksx() {
  if [ $# -eq 0 ]; then
    echo "aksx: give the command to run, for example  aksx kubectl get nodes" >&2
    return 1
  fi
  if [ -z "${AKS_RG:-}" ] || [ -z "${AKS_NAME:-}" ]; then
    echo "aksx: set AKS_RG and AKS_NAME first (the resource group and the name of the cluster)" >&2
    return 1
  fi
  az aks command invoke -g "$AKS_RG" -n "$AKS_NAME" --command "$*"
}
