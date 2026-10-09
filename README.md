# DevOps Toolbox (containerized CLIs for a locked-down Windows box)

![CI](https://github.com/nimat-dev/devtool/actions/workflows/ci.yml/badge.svg)

One Docker image with every senior-DevOps CLI baked in, plus PowerShell wrappers
so `az`, `kubectl`, `terraform`, `flux`, `helm`, `kustomize` and `azd` run inside
the container but feel local. Nothing to install on the host except Docker Desktop,
which you already have. Credentials and config persist in a named volume, so you
log in once. Short commands (`k`, `kgp`, `tfp`, `azl` ...), grey suggestions from your
history and Tab completion come with it, in PowerShell and in the toolbox shell.

**Tools included:** Azure CLI, azd, kubectl, kubelogin, Helm, Kustomize, Terraform,
Flux CLI, AWS CLI v2, GitHub CLI (gh), kubectx/kubens, plus jq, yq, git, ssh, make.

---

## Prerequisites

- Docker Desktop running (WSL2 or Hyper-V backend, either is fine).
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
5. loads the wrappers, the shortcuts, Tab completion and history suggestions (see
   [Shortcuts, history suggestions and Tab completion](#shortcuts-history-suggestions-and-tab-completion)),
   and makes `~/.devtools-aliases.ps1` for your own shortcuts (never overwritten)
6. runs `az`, `kubectl`, `terraform`, `helm`, `flux`, `kustomize`, `azd`, `gh`, `kubectx` and
   `kubens` once each, in the container, to prove they work, and checks that the image has the
   Tab completion helper

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

To undo all of this later, run `uninstall.ps1` (see [Stop and remove it](#stop-and-remove-it-one-command)).

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
become the default, no PATH changes needed. Check what they point at:

```powershell
Get-DevToolsInfo
```

## 3. First login (device code, no browser in the container)

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
dev                      # drops you into zsh with the same mounts (dev bash for bash)
```

### AKS + kubelogin flow

```powershell
az aks get-credentials --name <cluster> -g <rg> --overwrite-existing
kubectl get nodes        # kubelogin handles the AAD token automatically
```

Both `az` and `kubectl` share the same `/root` volume, so the kubeconfig written
by `get-credentials` and the AAD token cache from `kubelogin` are right there for
every later `kubectl` call.

## Shortcuts, history suggestions and Tab completion

All of this loads with the module, so `setup.ps1` turns it on and `uninstall.ps1` turns it off.
The parts that run inside the toolbox come with the image, which `setup.ps1` rebuilds.

### Shortcuts

`Get-DevToolsAlias` lists them. Whatever you type after a shortcut is added at the end, so
`kgp -n kube-system` runs `kubectl get pods -n kube-system`.

| Azure | Runs |
| --- | --- |
| `azl` | `az login --use-device-code` |
| `azwho` | `az account show -o table` |
| `azsubs` | `az account list -o table` |
| `azsub NAME` | `az account set --subscription NAME` |
| `azrg` | `az group list -o table` |
| `azres RG` | `az resource list -o table -g RG` |
| `acrls REGISTRY` | `az acr repository list -o table -n REGISTRY` |

| AKS and kubectl | Runs |
| --- | --- |
| `aksl` | `az aks list -o table` |
| `k` | `kubectl` |
| `kx`, `kn` | `kubectx`, `kubens` |
| `kgp`, `kgpa` | `kubectl get pods`, `kubectl get pods -A` |
| `kgn`, `kgd`, `kgs` | `kubectl get nodes`, `deployments`, `services` |
| `kd` | `kubectl describe` |
| `kl`, `klf` | `kubectl logs`, `kubectl logs -f` |
| `kex POD -- sh` | `kubectl exec -it POD -- sh` |
| `kaf FILE` | `kubectl apply -f FILE` |
| `krr deploy/NAME` | `kubectl rollout restart deploy/NAME` |
| `ktop` | `kubectl top pods` |

| Terraform | Runs |
| --- | --- |
| `tf` | `terraform` |
| `tfi`, `tfv`, `tff` | `terraform init`, `validate`, `fmt -recursive` |
| `tfp` | `terraform plan -out=tfplan` |
| `tfa` | `terraform apply tfplan` (applies exactly the plan you just read) |
| `tfo` | `terraform output` |
| `tfs`, `tfss ADDRESS` | `terraform state list`, `state show ADDRESS` |
| `tfw`, `tfws NAME` | `terraform workspace list`, `workspace select NAME` |
| `tfdestroy` | `terraform destroy` (it still asks you to confirm) |

There is no `-auto-approve` shortcut, on purpose.

Three AKS helpers take the resource group and the cluster name, either typed (`aksc my-rg my-cluster`)
or from two variables that you set once. They stay on your laptop and are not in this repository:

```powershell
$env:AKS_RG = 'my-resource-group'; $env:AKS_NAME = 'my-cluster'
```

| Helper | Runs |
| --- | --- |
| `aksc` | `az aks get-credentials -g RG -n NAME --overwrite-existing` |
| `aksup` | `az aks get-upgrades -g RG -n NAME -o table` |
| `aksx kubectl get nodes` | `az aks command invoke -g RG -n NAME --command "kubectl get nodes"`, which reaches a private cluster through Azure |

PowerShell removes a bare `--` before a function sees it. The wrappers put it back where you typed
it, so `kubectl exec -it web -- ls -la` and `kex web -- sh` work as written.

### Your own shortcuts

`setup.ps1` makes `~/.devtools-aliases.ps1` once and never overwrites it. It is read after the
built-in shortcuts, so what you define there wins:

```powershell
function kgj  { kubectl get pods -o json @args }
function tfpl { terraform plan -out=tfplan @args }
$env:AKS_RG   = 'my-resource-group'
$env:AKS_NAME = 'my-cluster'
```

A mistake in the file shows as a warning and the toolbox still loads. `Get-DevToolsAlias` marks the
shortcuts that are yours. Keep the file somewhere else by setting `$env:DEVTOOLS_ALIASES` before the
import. Inside the toolbox shell the same list exists as shell aliases, and your own go in
`~/.devtools-aliases.sh` (that is on the volume, so it stays).

### History suggestions

As you type, PowerShell shows the rest of an earlier command in grey; the Right arrow accepts it.
That needs PSReadLine 2.1 or newer, which PowerShell 7 has. Windows PowerShell 5.1 ships 2.0, which
cannot show grey text, so there the Up and Down arrows search your history for what you have typed
instead. To get the grey text on 5.1 as well, update PSReadLine once (no admin rights; it needs the
PowerShell Gallery, which some companies block), then open a new window:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module PSReadLine -Scope CurrentUser -Force -SkipPublisherCheck
```

Tab opens a menu of the choices; arrows pick, Enter accepts. Only defaults are replaced: a Tab
binding or a suggestion source you set yourself is left alone, and everything is handed back when
the module is removed. `$env:DEVTOOLS_NO_READLINE = '1'` before the import skips all of it.

### Tab completion

`az`, `kubectl`, `terraform`, `helm`, `flux` (and `kustomize`, `azd`, `gh`) complete their
commands and flags, and so do the shortcuts for them: `kgp -n <Tab>`, `tf wor<Tab>`. In PowerShell
the real tool answers from a short-lived container, so a Tab press takes about a second (a few for
`az`). Names that live in a system, such as pods or resource groups, are offered when the tool can
reach it and you are logged in. If Docker is not running, the image is older than this feature or
the tool takes too long, nothing is offered and file names complete as usual.

### The toolbox shell

`dev` (and `docker compose run --rm dev`) opens zsh: grey suggestions from your history, colours
(green when the command exists, red when it does not), a Tab menu, and the shortcuts above.
`dev bash` opens bash with the same shortcuts and completion. The history is kept in the volume
(`~/.zsh_history`), so it survives between sessions.

| Variable | Effect |
| --- | --- |
| `DEVTOOLS_ALIASES` | the file for your own shortcuts (default `~/.devtools-aliases.ps1`) |
| `DEVTOOLS_NO_READLINE` | `1` leaves PSReadLine alone |
| `AKS_RG`, `AKS_NAME` | your cluster, for `aksc`, `aksup`, `aksx`; `dev` hands them to the shell inside |

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

It's at the bottom on purpose: everything above stays cached, so adding a tool
is a quick rebuild. To upgrade a pinned tool, bump its version in `.env`
(or the `ARG` default) and rebuild.

## Using the compose `dev` service instead of per-command wrappers

```powershell
docker compose run --rm dev        # one-off shell
# or keep it up and exec in repeatedly:
docker compose up -d dev
docker compose exec dev zsh
```

Set `REPOS_ROOT` in `.env` to an absolute path (e.g. `C:/Users/you/repos`) to
mount your real code at `/repos`; otherwise the project's `./repos` folder is used.

## Putting this on GitHub

This project is already a git repo with an initial commit. Since you can't install
`gh` on the host, use the one baked into the toolbox. From the project folder:

```powershell
docker compose build                 # if you haven't already
gh auth login                        # choose "Paste an authentication token" (a PAT), no browser needed
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

## Stop and remove it: one command

`uninstall.ps1` is the undo for `setup.ps1`. In the PowerShell window you use the tools in:

```powershell
.\uninstall.ps1
```

If scripts are blocked, run `powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1`
instead, then `Remove-Module Devtools` in the window you were using. It does this, in order:

1. removes the `Import-Module` line from your PowerShell profile (a `.bak` copy is saved first). It
   looks in the profiles of Windows PowerShell 5.1 and of PowerShell 7, which keep theirs in
   different folders
2. unloads the wrappers from the window it runs in, so `az`, `kubectl` and the rest are the
   programs installed on the PC again (or "not recognized" when there are none)
3. stops and removes the toolbox containers: `docker compose down`, then anything still running
   from the image, such as a `dev` shell open in another window
4. only when you ask: deletes the image and your saved logins

The image takes minutes to build and the volume holds your Azure, GitHub and Kubernetes logins,
so both are **kept** unless you ask. Your project folder and `.env` are never touched, and neither
is your own shortcuts file (`~/.devtools-aliases.ps1`): it holds what you wrote, so the script
only tells you where it is. With the profile line gone, new windows have no shortcuts, Tab
completion or history settings from the toolbox. It works with Docker Desktop stopped (the profile
and the window are cleaned first) and is safe to run again.

| Option | What it does |
| --- | --- |
| `-RemoveImage` | also delete the image `devtools:latest` (`setup.ps1` builds it again) |
| `-RemoveVolume` | also delete the volume with your saved logins. Asks first |
| `-Force` | do not ask before deleting the volume |
| `-SkipProfile` | leave your PowerShell profile alone |
| `-NoPrompt` | never ask a question (for automation); the volume is then deleted only with `-Force` |
| `-ProfilePath <file>` | clean this profile instead of looking for yours |

Exit code: `0` done, `1` could not run (Constrained Language Mode), `2` finished but something
above failed. For everything at once: `.\uninstall.ps1 -RemoveImage -RemoveVolume`.

PowerShell windows that were already open keep the wrappers until you close them or run
`Remove-Module Devtools` in them. Only the default names are handled: the image `devtools:latest`
and the volumes `devtools-home` (used by the wrappers) and `devtools_devtools-home` (the one
`docker compose run` creates, because Compose prefixes volume names with the project name). A name
you chose with `DEVTOOLS_IMAGE` or `DEVTOOLS_VOLUME` is left alone.

## Tests and CI

Every push runs `.github/workflows/ci.yml` on GitHub's runners (the badge at the top shows the
latest result). It runs three jobs:

- **Lint and PowerShell tests** (Linux): hadolint on the Dockerfile, shellcheck on every shell
  script, `docker compose config`, and three PowerShell test scripts that run against a fake
  `docker`:
  - `tests/Test-Devtools.ps1` runs the real `Devtools.psm1` and checks the exact `docker run`
    line each wrapper produces (mounts, working directory, `-out` / `-o` pass-through, exit
    codes, env overrides), every shortcut against its table, the bare `--` that PowerShell
    removes, your own shortcuts file (including a broken one), Tab completion against canned
    answers, and what is done to PSReadLine (new and old versions) and handed back.
  - `tests/Test-Setup.ps1` runs `setup.ps1` in a scratch copy of the project, once per situation
    it has to handle: first run, second run, project folder moved, Docker not running, Windows
    containers, docker missing, wrong folder, build failure, no `docker compose`, a broken tool,
    and each option. It checks the exit code, the messages, the docker calls and the profile file.
  - `tests/Test-Uninstall.ps1` does the same for `uninstall.ps1`, and also runs `setup.ps1` first
    to prove the profile comes back byte for byte as it was. It covers odd profile lines, a locked
    profile, wrappers loaded in the session, containers that will not go, a missing or stopped
    Docker, and each option including the question before the volume is deleted.
  - `tests/pty_shell_test.py pwsh` starts an interactive PowerShell 7 in a pseudo terminal with the
    profile line `setup.ps1` writes, then types like a person: the Tab menu, Tab completion
    through a fake docker, grey suggestions from the history, `kex pod -- ls -la`, and the keys
    coming back when the module is removed.
- **PowerShell on Windows**: all three test scripts in Windows PowerShell 5.1 and in PowerShell 7 on
  a Windows runner, with a fake `docker.exe`. Windows runners cannot run Linux containers, so this
  covers the PowerShell side only: 5.1 syntax, parameter binding, native argument passing and
  Windows paths. The runner is thrown away after the job, so it is also where the real default
  profile folders of both PowerShell editions are tested (and put back afterwards).
- **Build the image and test it** (Linux): a real `docker build`, then
  - `tests/smoke.sh` runs inside the image: every tool starts and reports the version pinned in
    the Dockerfile, the entrypoint extends `NO_PROXY`, the Terraform plugin cache is set up, and
    the interactive shells are in place (zsh and its plugins, the completion scripts, the
    aliases, and the answers `devtools-complete` gives for each tool).
  - `tests/pty_shell_test.py` types into zsh and into bash inside the image, in a pseudo
    terminal: the aliases, the grey suggestion, the colours and Tab completion for flux, gh,
    terraform, kubectl, helm and az.
  - `tests/e2e-import.sh` starts a fake Kubernetes API on the host with a certificate valid only
    for `kubernetes.docker.internal`, then checks that the container reaches it with TLS verified,
    that only the `docker-desktop` context is imported (a second context's secret never reaches
    the volume), that kubectx and kubens work against it, that a re-import is idempotent, and that
    a dead corporate proxy cannot swallow the host traffic.
  - `setup.ps1` runs for real against the Docker engine of the runner (build, profile, every tool
    in its own container), and then once more to prove a second run changes nothing.
  - `uninstall.ps1` runs for real against the same engine, with a container still running from
    the image and both volumes present: it stops the container and takes the profile line out,
    keeps the image and the logins, and then with `-RemoveImage -RemoveVolume -Force` deletes them.

Run the PowerShell tests on your own machine (no Docker needed, and your own profile is not touched):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Devtools.ps1   # Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Uninstall.ps1
pwsh -NoProfile -File tests/Test-Devtools.ps1                                 # PowerShell 7, any OS
pwsh -NoProfile -File tests/Test-Setup.ps1
pwsh -NoProfile -File tests/Test-Uninstall.ps1
```

The image tests need Linux, macOS or WSL with Docker:

```bash
docker build -t devtools:ci .
docker run --rm -v "$PWD/tests:/tests:ro" devtools:ci bash /tests/smoke.sh
tests/e2e-import.sh devtools:ci                                    # needs openssl and python3
python3 tests/pty_shell_test.py zsh --full -- docker run --rm -it devtools:ci zsh
python3 tests/pty_shell_test.py bash --full -- docker run --rm -it devtools:ci bash
python3 tests/pty_shell_test.py pwsh -- pwsh -NoLogo                 # PowerShell 7 on Linux or macOS
```

What CI cannot prove: how your corporate proxy and TLS inspection behave, Docker Desktop's
real Kubernetes (the end-to-end test uses a fake API server on Linux), and how Windows PowerShell
5.1 behaves at a live prompt (CI has no console there, so the grey suggestions, the Tab menu and
the Up and Down search are tested with PowerShell 7 and with stand-ins for PSReadLine 2.0). Run
`Import-DockerDesktopKube` on the laptop for the Kubernetes last mile.

---

## Troubleshooting

**Build fails with x509 / certificate errors (corporate proxy or TLS inspection).**
Two things, usually both:
1. Drop your corporate root CA into `certs/` as a `*.crt` (PEM). The Dockerfile
   trusts it before any download. See `certs/README.md`.
2. Set the proxy in `.env` (`HTTP_PROXY` / `HTTPS_PROXY`) and in Docker Desktop
   under *Settings → Resources → Proxies*. Then `docker compose build`.

**Build fails with "429 Too Many Requests", or Docker Hub is blocked.** The image starts from
`debian:bookworm-slim` on Docker Hub. Put a mirror of the same image in `.env` and rebuild
(`.\setup.ps1`):
```
BASE_IMAGE=registry.corp.example/library/debian:bookworm-slim
```
It has to be Debian 12; the install steps use apt.

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

**Tab does nothing, or is slow, in PowerShell.** Each Tab asks a short-lived container, so it takes
about a second, and the first one after Docker Desktop starts can take longer. Nothing at all means
the answer was empty or late: check that Docker Desktop is running and that the image is current
(`.\setup.ps1` rebuilds it; `Get-DevToolsInfo` shows which image the wrappers use). Names that need
a login or a cluster (pods, resource groups) only complete when the tool can reach them.

**No grey suggestions in Windows PowerShell 5.1.** It ships PSReadLine 2.0, which cannot draw them.
The Up and Down arrows search the history instead; to get the grey text, update PSReadLine as shown
under [History suggestions](#history-suggestions). The shell inside the toolbox (`dev`) has the grey
suggestions either way.

**A warning about your shortcuts file when PowerShell starts.** The module could not read
`~/.devtools-aliases.ps1` (or the file named by `DEVTOOLS_ALIASES`) and went on without the rest of
it. The warning names the file and the error; fix that line, or move the file away.

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
├─ uninstall.ps1         # the undo: stop the containers, remove the wrappers (image and logins only on request)
├─ Devtools.psm1         # PowerShell wrappers (az/kubectl/terraform/... + dev + Import-DockerDesktopKube),
│                        # shortcuts, Tab completion, history suggestions
├─ scripts/
│  ├─ devtools-entrypoint.sh         # keeps Docker Desktop host traffic off the proxy
│  ├─ import-docker-desktop-kube.sh  # copies the docker-desktop kube context into the toolbox
│  ├─ devtools-complete.sh           # answers PowerShell's Tab presses with the real tool's completions
│  └─ shell/                         # the toolbox shell: zshrc, bashrc, aliases.sh, az-completion.sh
├─ tests/                # smoke test, importer end-to-end test, terminal (pty) tests, PowerShell tests
├─ .github/workflows/    # CI: lint, build the image, run the tests above
├─ certs/                # drop corporate root CA here (optional)
└─ repos/                # default mount point if REPOS_ROOT is unset
```
