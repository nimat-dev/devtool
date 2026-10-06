# DevOps Toolbox (containerized CLIs for a locked-down Windows box)

![CI](https://github.com/nimat-dev/devtool/actions/workflows/ci.yml/badge.svg)

One Docker image with every senior-DevOps CLI baked in, plus PowerShell wrappers
so `az`, `kubectl`, `terraform`, `flux`, `helm`, `kustomize` and `azd` run inside
the container but feel local. Nothing to install on the host except Docker Desktop,
which you already have. Credentials and config persist in a named volume, so you
log in once.

**Tools included:** Azure CLI, azd, kubectl, kubelogin, Helm, Kustomize, Terraform,
Flux CLI, AWS CLI v2, GitHub CLI (gh), kubectx/kubens, plus jq, yq, git, ssh, make.

---

## Prerequisites

- Docker Desktop running (WSL2 or Hyper-V backend — either is fine).
- PowerShell (Windows PowerShell 5.1 or PowerShell 7+).
- No admin rights or other installs required.

## Quick start: one command

Open PowerShell in this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` runs every command from the steps below, in order, and then checks the tools:

1. checks that Docker Desktop is running with Linux containers
2. creates `.env` from `.env.example` (an existing `.env` is kept)
3. builds the image (`docker compose build`)
4. adds the `Import-Module` line to your PowerShell profile (a line left over from a moved
   folder is updated, and a `.bak` copy of the profile is saved first)
5. loads the wrappers
6. runs `az`, `kubectl`, `terraform`, `helm`, `flux`, `kustomize`, `azd`, `gh`, `kubectx` and
   `kubens` once each, in the container, to prove they work

Then it offers the Azure device-code login and the Docker Desktop Kubernetes import. It is safe
to run again whenever you like: every step checks before it changes anything.

| Option | What it does |
| --- | --- |
| `-SkipBuild` | the image is already built |
| `-SkipProfile` | leave your PowerShell profile alone |
| `-SkipVerify` | skip the tool checks |
| `-Login` | run `az login --use-device-code` at the end without asking |
| `-ImportKube` | import Docker Desktop's Kubernetes context at the end without asking |
| `-NoPrompt` | never ask a question (for automation) |
| `-ProfilePath <file>` | edit this profile instead of your all-hosts profile |

Exit code: `0` all good, `1` setup could not finish, `2` setup finished but a tool check failed.

That command runs the script in its own PowerShell process, so open a **new** PowerShell window
afterwards: your profile loads the tools there. (If you start it from your own prompt as
`.\setup.ps1`, after `Set-ExecutionPolicy -Scope Process Bypass`, the tools are loaded in that
window too.) If Group Policy blocks scripts altogether, or PowerShell runs in Constrained
Language Mode, the wrappers cannot work there: build with `docker compose build` and use
`docker compose run --rm dev` for a shell inside the toolbox.

The manual steps, one at a time:

## 1. Build the image

```powershell
cd devtool
copy .env.example .env          # optional; edit versions / proxy / repos path
docker compose build            # or: docker build -t devtools:latest .
```

First build pulls a lot (Azure CLI, Terraform, AWS CLI, etc.) and takes a few
minutes. Rebuilds are cached and fast.

> On a corporate network with TLS interception, the build will fail on
> certificate errors during the HTTPS downloads. See **Troubleshooting**.

## 2. Wire up the PowerShell wrappers

Add one line to your profile so the wrappers load in every new shell:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
notepad $PROFILE
```

Add (adjust the path to where this folder lives):

```powershell
Import-Module 'C:\path\to\devtool\Devtools.psm1' -Force
```

Reopen PowerShell. Now `az`, `kubectl`, `terraform`, etc. are the container
versions. Because there's no local `az` on this machine, these functions simply
become the default — no PATH changes needed. Check what they point at:

```powershell
Get-DevToolsInfo
```

## 3. First login (device code — no browser in the container)

```powershell
az login --use-device-code
```

Opens a code + URL; complete it in any browser. The token lands in `~/.azure`
on the persistent volume, so it survives across every future command and shell.

## Everyday use

```powershell
az account show
terraform init           # runs against the folder you're standing in
terraform plan -out tf.plan
kubectl get pods -A
helm upgrade --install myapp ./chart
flux get kustomizations
```

Your current directory is mounted at `/work` inside the container, so file-based
commands (`terraform`, `kubectl apply -f`, `helm ./chart`) act on the folder
you're in. For a full interactive shell in the toolbox:

```powershell
dev                      # drops you into bash with the same mounts
```

### AKS + kubelogin flow

```powershell
az aks get-credentials --name <cluster> -g <rg> --overwrite-existing
kubectl get nodes        # kubelogin handles the AAD token automatically
```

Both `az` and `kubectl` share the same `/root` volume, so the kubeconfig written
by `get-credentials` and the AAD token cache from `kubelogin` are right there for
every later `kubectl` call.

## Use Docker Desktop's Kubernetes (local cluster)

Instead of AKS, point the toolbox at the cluster built into Docker Desktop.

1. Docker Desktop > Settings > Kubernetes > Enable Kubernetes > Apply. Wait until it
   shows **Running**. (If the option is missing or greyed out, an admin policy has it locked.)
2. Rebuild once so the image has the helper scripts. Only the last layers change:
   ```powershell
   docker compose build
   ```
3. Reload the module and import the context:
   ```powershell
   Import-Module 'C:\path\to\devtool\Devtools.psm1' -Force
   Import-DockerDesktopKube
   ```
   It ends with `Connected to Kubernetes v1.xx` when the container can reach the cluster.
4. Use it like any other context:
   ```powershell
   kubectx docker-desktop
   kubectl get nodes
   kubens
   ```
   (Prefer another name? `kubectl config rename-context docker-desktop local`.)

**Why a helper instead of just copying the kubeconfig?** Two things break inside a container:

- The toolbox keeps its own kubeconfig on the volume and can't see the Windows one.
- Docker Desktop's context points at `kubernetes.docker.internal` / localhost, which inside a
  container is the container itself. `Import-DockerDesktopKube` copies **only** the
  `docker-desktop` context (the rest of your host kubeconfig is never read into the volume),
  repoints it at `host.docker.internal`, and keeps TLS verification on by verifying against
  the original name (`tls-server-name`).

Behind a corporate proxy there is a third trap: kubectl would send `host.docker.internal`
to the proxy, which can't reach your laptop. The image entrypoint appends the Docker Desktop
host names to `NO_PROXY` (existing entries are kept), so this just works.

Re-run `Import-DockerDesktopKube` after *Reset Kubernetes Cluster* (the certificates change).
It is safe to re-run any time; it replaces its own entries and leaves everything else
(AKS contexts, etc.) alone. A backup of the previous file is kept as `~/.kube/config.bak`
on the volume.

If the import says the API server did not answer, it prints a direct probe result:

- `HTTP 000`: nothing reachable. Check Kubernetes shows Running, and any VPN / firewall.
- Any other code: the host is reachable, so the kubectl error above it is TLS or a proxy.

## Adding a new tool

Edit the `# ---- EXTRA TOOLS ----` block at the bottom of the `Dockerfile`
(k9s, terragrunt, tflint, trivy examples are there, commented), then:

```powershell
docker compose build
```

It's at the bottom on purpose — everything above stays cached, so adding a tool
is a quick rebuild. To upgrade a pinned tool, bump its version in `.env`
(or the `ARG` default) and rebuild.

## Using the compose `dev` service instead of per-command wrappers

```powershell
docker compose run --rm dev        # one-off shell
# or keep it up and exec in repeatedly:
docker compose up -d dev
docker compose exec dev bash
```

Set `REPOS_ROOT` in `.env` to an absolute path (e.g. `C:/Users/you/repos`) to
mount your real code at `/repos`; otherwise the project's `./repos` folder is used.

## Putting this on GitHub

This project is already a git repo with an initial commit. Since you can't install
`gh` on the host, use the one baked into the toolbox. From the project folder:

```powershell
docker compose build                 # if you haven't already
gh auth login                        # choose "Paste an authentication token" (a PAT) — no browser needed
gh repo create devtool --private --source . --remote origin --push
```

That creates the repo under your account and pushes `main` in one shot. `gh` prints
the URL. Auth persists in the volume, so you only log in once.

Plain-git alternative (if you'd rather create the empty repo on github.com first):

```powershell
dev                                  # bash shell in the toolbox, project mounted at /work
# inside the container:
git remote add origin https://github.com/<you>/devtool.git
git push -u origin main              # use a PAT as the password when prompted
```

## Tests and CI

Every push runs `.github/workflows/ci.yml` on GitHub's runners (the badge at the top shows the
latest result). It runs three jobs:

- **Lint and PowerShell tests** (Linux): hadolint on the Dockerfile, shellcheck on every shell
  script, `docker compose config`, and two PowerShell test scripts that run against a fake
  `docker`:
  - `tests/Test-Devtools.ps1` runs the real `Devtools.psm1` and checks the exact `docker run`
    line each wrapper produces (mounts, working directory, `-out` / `-o` pass-through, exit
    codes, env overrides).
  - `tests/Test-Setup.ps1` runs `setup.ps1` in a scratch copy of the project, once per situation
    it has to handle: first run, second run, project folder moved, Docker not running, Windows
    containers, docker missing, wrong folder, build failure, no `docker compose`, a broken tool,
    and each option. It checks the exit code, the messages, the docker calls and the profile file.
- **PowerShell on Windows**: both test scripts in Windows PowerShell 5.1 and in PowerShell 7 on a
  Windows runner, with a fake `docker.exe`. Windows runners cannot run Linux containers, so this
  covers the PowerShell side only: 5.1 syntax, parameter binding, native argument passing and
  Windows paths.
- **Build the image and test it** (Linux): a real `docker build`, then
  - `tests/smoke.sh` runs inside the image: every tool starts and reports the version pinned in
    the Dockerfile, the entrypoint extends `NO_PROXY`, the Terraform plugin cache is set up.
  - `tests/e2e-import.sh` starts a fake Kubernetes API on the host with a certificate valid only
    for `kubernetes.docker.internal`, then checks that the container reaches it with TLS verified,
    that only the `docker-desktop` context is imported (a second context's secret never reaches
    the volume), that kubectx and kubens work against it, that a re-import is idempotent, and that
    a dead corporate proxy cannot swallow the host traffic.
  - `setup.ps1` runs for real against the Docker engine of the runner (build, profile, every tool
    in its own container), and then once more to prove a second run changes nothing.

Run the PowerShell tests on your own machine (no Docker needed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Devtools.ps1   # Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Setup.ps1
pwsh -NoProfile -File tests/Test-Devtools.ps1                                 # PowerShell 7, any OS
pwsh -NoProfile -File tests/Test-Setup.ps1
```

The image tests need Linux, macOS or WSL with Docker:

```bash
docker build -t devtools:ci .
docker run --rm -v "$PWD/tests:/tests:ro" devtools:ci bash /tests/smoke.sh
tests/e2e-import.sh devtools:ci                                    # needs openssl and python3
```

What CI cannot prove: how your corporate proxy and TLS inspection behave, and Docker Desktop's
real Kubernetes (the end-to-end test uses a fake API server on Linux). Run
`Import-DockerDesktopKube` on the laptop for that last mile.

---

## Troubleshooting

**Build fails with x509 / certificate errors (corporate proxy or TLS inspection).**
Two things, usually both:
1. Drop your corporate root CA into `certs/` as a `*.crt` (PEM). The Dockerfile
   trusts it before any download. See `certs/README.md`.
2. Set the proxy — in `.env` (`HTTP_PROXY` / `HTTPS_PROXY`) and in Docker Desktop
   under *Settings → Resources → Proxies*. Then `docker compose build`.

**`Import-Module` fails with "running scripts is disabled on this system" (or "not digitally
signed").** PowerShell's execution policy is blocking the module. For your user only, no admin
needed:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
Unblock-File 'C:\path\to\devtool\Devtools.psm1'     # needed if the folder came from a downloaded ZIP
```
If a Group Policy enforces the policy, PowerShell will refuse the change. The module can't load
then; use `docker compose run --rm dev` instead, which gives you the same toolbox in a shell.

**Garbled characters (`â€"`, `Γöé`, broken box lines) in Terraform or `gh` output.** Windows
PowerShell decodes native output with the legacy console code page, but the container prints
UTF-8. Add this line to your `$PROFILE`:
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

**Quotes in an argument (JSON for `kubectl patch -p`, `az --tags`, `terraform -var`).** Type them
naturally, e.g. `kubectl patch deploy web -p '{"spec":{"replicas":3}}'`. Windows PowerShell 5.1
normally strips the double quotes from native command arguments; the wrappers escape them for
you, so don't add backslashes. CI checks this in both Windows PowerShell 5.1 and PowerShell 7.

**`az login` opens nothing / hangs.** Use `az login --use-device-code`. The
container has no browser, so the normal interactive login can't work.

**Output looks garbled, or piping/redirection breaks a command.** The wrappers
only allocate a TTY (`-t`) for genuine interactive use and drop it when output is
piped or captured, which is correct. If you hit an edge case, run the command
inside `dev` instead.

**A version pin 404s during build** (e.g. a kubectl patch that doesn't exist).
Pick a valid version and set it in `.env`, then rebuild.

**`docker was not found on PATH`** from a wrapper. Docker Desktop isn't running,
or `docker` doesn't resolve in a plain shell. Start Docker Desktop and retry.

**Bind mount path issues on Windows.** `docker compose` handles Windows paths in
`REPOS_ROOT`. For the wrappers, the current directory is auto-detected; if a
drive-letter path ever misbehaves, `cd` into the folder and run from there (the
wrappers mount `$PWD`).

## Layout

```
devtool/
├─ Dockerfile            # the image; EXTRA TOOLS block at the bottom
├─ docker-compose.yml    # build + persistent volume + dev service
├─ .env.example          # versions, proxy, repos path (copy to .env)
├─ setup.ps1             # one command: check Docker, build, wire the profile, verify every tool
├─ Devtools.psm1         # PowerShell wrappers (az/kubectl/terraform/... + dev + Import-DockerDesktopKube)
├─ scripts/
│  ├─ devtools-entrypoint.sh         # keeps Docker Desktop host traffic off the proxy
│  └─ import-docker-desktop-kube.sh  # copies the docker-desktop kube context into the toolbox
├─ tests/                # smoke test, importer end-to-end test, PowerShell tests (wrappers, setup.ps1)
├─ .github/workflows/    # CI: lint, build the image, run the tests above
├─ certs/                # drop corporate root CA here (optional)
└─ repos/                # default mount point if REPOS_ROOT is unset
```
