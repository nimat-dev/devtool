# syntax=docker/dockerfile:1
#
# DevOps toolbox image — one image, every CLI a senior DevOps engineer needs.
# Layers are ordered stable -> volatile so appending a tool later is a cheap rebuild.
#
# Version policy:
#   - Binary/tarball tools are PINNED via ARG (reproducible; bump one var to upgrade).
#   - apt/script tools (az, terraform, azd, aws) default to LATEST so a stale pin
#     never breaks the build. Pin them by setting the matching ARG (see .env.example).

FROM debian:bookworm-slim

# Fail a RUN if any stage of a pipe fails (needed for the curl | gpg / curl | bash lines).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# Proxy (optional). Leave blank when not behind a corporate proxy.
# NOTE: these are also inherited at runtime, which is usually what you want on
# a locked-down machine that is always behind the same proxy. Blank = no-op.
# ---------------------------------------------------------------------------
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ENV http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    no_proxy="localhost,127.0.0.1,.local" \
    NO_PROXY="localhost,127.0.0.1,.local"

# ---------------------------------------------------------------------------
# Base utilities (most stable layer).
# DL3008 intentionally ignored: a dev toolbox tracks current, security-patched
# base utilities rather than pinning them to exact bookworm point releases.
# ---------------------------------------------------------------------------
# hadolint ignore=DL3008
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      apt-transport-https \
      bash \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      less \
      lsb-release \
      make \
      openssh-client \
      unzip \
      vim-tiny \
      wget \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Corporate root CA (optional). Drop any *.crt into ./certs before building and
# it gets trusted here; with an empty certs/ this is a harmless no-op. This must
# run before the HTTPS downloads below so TLS interception doesn't break them.
# ---------------------------------------------------------------------------
COPY certs/ /usr/local/share/ca-certificates/extra/
RUN if ls -A /usr/local/share/ca-certificates/extra/*.crt >/dev/null 2>&1; then \
      echo "Installing corporate root CA(s)..." && update-ca-certificates; \
    else \
      echo "No corporate CA provided (certs/ has no *.crt) — skipping."; \
    fi

# ---------------------------------------------------------------------------
# Azure CLI (Microsoft apt repo). Optional pin via AZURE_CLI_VERSION.
# DL3008 ignored: version is pinned conditionally via ARG, else latest.
# ---------------------------------------------------------------------------
ARG AZURE_CLI_VERSION=""
# hadolint ignore=DL3008
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/azure-cli.list \
 && DEBIAN_FRONTEND=noninteractive apt-get update \
 && if [ -n "${AZURE_CLI_VERSION}" ]; then \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "azure-cli=${AZURE_CLI_VERSION}-1~$(lsb_release -cs)"; \
    else \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends azure-cli; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Terraform (HashiCorp apt repo). Optional pin via TERRAFORM_VERSION (e.g. 1.9.8).
# DL3008 ignored: version is pinned conditionally via ARG, else latest.
# ---------------------------------------------------------------------------
ARG TERRAFORM_VERSION=""
# hadolint ignore=DL3008
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/hashicorp.list \
 && DEBIAN_FRONTEND=noninteractive apt-get update \
 && if [ -n "${TERRAFORM_VERSION}" ]; then \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "terraform=${TERRAFORM_VERSION}-1"; \
    else \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends terraform; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# kubectl (official binary from dl.k8s.io, checksum-verified). Pinned.
# ---------------------------------------------------------------------------
ARG KUBECTL_VERSION=1.31.4
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
 && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl \
 && rm -f /tmp/kubectl.sha256

# ---------------------------------------------------------------------------
# kubelogin (Azure AD auth plugin for kubectl/AKS — needed for `az aks get-credentials`
# against AAD-enabled clusters). GitHub release zip. Pinned.
# ---------------------------------------------------------------------------
ARG KUBELOGIN_VERSION=0.1.4
RUN curl -fsSLo /tmp/kubelogin.zip "https://github.com/Azure/kubelogin/releases/download/v${KUBELOGIN_VERSION}/kubelogin-linux-amd64.zip" \
 && unzip -q /tmp/kubelogin.zip -d /tmp/kubelogin \
 && install -m 0755 /tmp/kubelogin/bin/linux_amd64/kubelogin /usr/local/bin/kubelogin \
 && rm -rf /tmp/kubelogin /tmp/kubelogin.zip

# ---------------------------------------------------------------------------
# Helm (official get-helm-3 script). Pinned via HELM_VERSION.
# ---------------------------------------------------------------------------
ARG HELM_VERSION=3.16.3
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
      | DESIRED_VERSION="v${HELM_VERSION}" USE_SUDO=false HELM_INSTALL_DIR=/usr/local/bin bash \
 && helm version --short

# ---------------------------------------------------------------------------
# kustomize (GitHub release tarball, direct URL). Pinned via KUSTOMIZE_VERSION.
# The upstream install script resolves the asset through the unauthenticated GitHub
# API, which is rate-limited on shared CI runners and often blocked behind corporate
# proxies, so the release asset is fetched directly instead.
# ---------------------------------------------------------------------------
ARG KUSTOMIZE_VERSION=5.5.0
RUN curl -fsSLo /tmp/kustomize.tar.gz "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/kustomize.tar.gz -C /usr/local/bin kustomize \
 && rm -f /tmp/kustomize.tar.gz \
 && kustomize version

# ---------------------------------------------------------------------------
# Flux CLI (GitHub release tarball, direct URL). Pinned via FLUX_VERSION.
# Same reason as kustomize: the install script goes through the GitHub API.
# ---------------------------------------------------------------------------
ARG FLUX_VERSION=2.4.0
RUN curl -fsSLo /tmp/flux.tar.gz "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/flux.tar.gz -C /usr/local/bin flux \
 && rm -f /tmp/flux.tar.gz \
 && flux --version

# ---------------------------------------------------------------------------
# Azure Developer CLI (azd). Official script, optional pin via AZD_VERSION.
# ---------------------------------------------------------------------------
ARG AZD_VERSION=""
RUN if [ -n "${AZD_VERSION}" ]; then \
      curl -fsSL https://aka.ms/install-azd.sh | bash -s -- --version "${AZD_VERSION}"; \
    else \
      curl -fsSL https://aka.ms/install-azd.sh | bash; \
    fi \
 && azd version

# ---------------------------------------------------------------------------
# AWS CLI v2 (official installer zip — no apt package exists for v2).
# Optional pin via AWSCLI_VERSION (e.g. 2.17.0); blank = latest.
# ---------------------------------------------------------------------------
ARG AWSCLI_VERSION=""
RUN if [ -n "${AWSCLI_VERSION}" ]; then \
      curl -fsSLo /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip"; \
    else \
      curl -fsSLo /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    fi \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscliv2.zip \
 && aws --version

# ---------------------------------------------------------------------------
# yq (GitHub release binary). Pinned via YQ_VERSION.
# ---------------------------------------------------------------------------
ARG YQ_VERSION=4.44.6
RUN curl -fsSLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
 && chmod +x /usr/local/bin/yq \
 && yq --version

# ---------------------------------------------------------------------------
# GitHub CLI (gh) — create repos, open PRs, auth with a token (no browser).
# GitHub release tarball. Pinned via GH_VERSION.
# ---------------------------------------------------------------------------
ARG GH_VERSION=2.63.2
RUN curl -fsSLo /tmp/gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/gh.tar.gz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64" \
 && gh --version

# ---------------------------------------------------------------------------
# Shell env: persist Terraform's provider plugin cache on the mounted /root
# volume so `terraform init` doesn't re-download providers every run.
# ---------------------------------------------------------------------------
ENV TF_PLUGIN_CACHE_DIR=/root/.terraform.d/plugin-cache
RUN mkdir -p /root/.terraform.d/plugin-cache \
 && printf 'plugin_cache_dir = "%s"\n' "${TF_PLUGIN_CACHE_DIR}" > /root/.terraformrc

WORKDIR /work

# ---------------------------------------------------------------------------
# Helper scripts.
#   devtools-entrypoint          keeps Docker Desktop host traffic off the corporate proxy
#   import-docker-desktop-kube   copies the docker-desktop kube context into the toolbox
# sed strips CRs in case Windows git checked the files out with CRLF line endings.
# ---------------------------------------------------------------------------
COPY scripts/devtools-entrypoint.sh /usr/local/bin/devtools-entrypoint
COPY scripts/import-docker-desktop-kube.sh /usr/local/bin/import-docker-desktop-kube
RUN sed -i 's/\r$//' /usr/local/bin/devtools-entrypoint /usr/local/bin/import-docker-desktop-kube \
 && chmod 0755 /usr/local/bin/devtools-entrypoint /usr/local/bin/import-docker-desktop-kube

# ===========================================================================
# ---- EXTRA TOOLS ----
# Append one-off installs below, then rebuild. Kept at the bottom so everything
# above stays cached. Examples (uncomment / adapt):

# kubectx + kubens — fast context / namespace switching for kubectl.
# GitHub release tarballs (ahmetb/kubectx). Pinned via KUBECTX_VERSION.
ARG KUBECTX_VERSION=0.9.5
RUN curl -fsSLo /tmp/kubectx.tar.gz "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubectx_v${KUBECTX_VERSION}_linux_x86_64.tar.gz" \
 && curl -fsSLo /tmp/kubens.tar.gz  "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubens_v${KUBECTX_VERSION}_linux_x86_64.tar.gz" \
 && tar -xzf /tmp/kubectx.tar.gz -C /tmp kubectx \
 && tar -xzf /tmp/kubens.tar.gz  -C /tmp kubens \
 && install -m 0755 /tmp/kubectx /usr/local/bin/kubectx \
 && install -m 0755 /tmp/kubens  /usr/local/bin/kubens \
 && rm -f /tmp/kubectx.tar.gz /tmp/kubens.tar.gz /tmp/kubectx /tmp/kubens \
 && test -x /usr/local/bin/kubectx && test -x /usr/local/bin/kubens

#
# ARG K9S_VERSION=0.32.7
# RUN curl -fsSLo /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
#  && tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s && rm /tmp/k9s.tar.gz
#
# ARG TERRAGRUNT_VERSION=0.69.1
# RUN curl -fsSLo /usr/local/bin/terragrunt "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64" \
#  && chmod +x /usr/local/bin/terragrunt
#
# RUN curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
# ===========================================================================

ENTRYPOINT ["/usr/local/bin/devtools-entrypoint"]
CMD ["bash"]
