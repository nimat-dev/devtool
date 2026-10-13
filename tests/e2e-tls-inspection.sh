#!/usr/bin/env bash
# End-to-end test of the company-certificate support, with the REAL image and the real tools.
#
#   tests/e2e-tls-inspection.sh [image]        (default: devtools:ci)
#
# Needs docker and openssl on the host, and pwsh for the PowerShell part. A network that signs HTTPS
# again with its own certificate (TLS inspection) is played by a container of the same image that
# runs `openssl s_server` for login.microsoftonline.com, with a certificate issued by a made-up
# company CA. The other containers reach it at the address of the default Docker bridge's gateway:
# by name (--add-host) for the tools, by IP address for the wrapper functions, which cannot add a
# name. What is checked:
#   - az stops with the error from the laptop ("self-signed certificate in certificate chain")
#   - a CA that is only in the system store does not help az (it has a list of its own), which is
#     the reason for all of this; the image's defaults (REQUESTS_CA_BUNDLE and friends) do
#   - a certificate in the certs folder is trusted when the container starts, with no rebuild, by
#     az (also its login, MSAL), curl, git, kubectl, helm and the AWS CLI
#   - devtools-ca finds the CA certificates, and what it prints works as a certs file
#   - the wrappers do it all for real: PowerShell's Add-DevToolsCA and bash's devtools-add-ca
set -uo pipefail

IMAGE=${1:-devtools:ci}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck disable=SC1091
. "$HERE/lib.sh"

WORK=$(mktemp -d)
NAME=tls-interceptor-$$
VOL=devtools-e2e-ca-$$
PKI=$WORK/pki
CERTS=$WORK/certs
mkdir -p "$PKI" "$WORK/www" "$WORK/home-sh" "$WORK/home-ps"

cleanup() {
  docker rm -f "$NAME" > /dev/null 2>&1
  docker volume rm -f "$VOL" > /dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

GW=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2> /dev/null)
if ! [[ $GW =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "FAIL  could not find the gateway address of docker's default bridge (got '$GW')"
  exit 1
fi
echo "image $IMAGE, the company network is at $GW:443"

# ---- the company's CAs and the certificate its network presents ---------------------------------
{
  cd "$PKI" || exit 1
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout corp-root.key -out corp-root.crt \
    -subj '/C=US/O=E2E Corp/CN=E2E Corp Root CA' -days 3 \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash'
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout corp-issuing.key -out corp-issuing.csr \
    -subj '/C=US/O=E2E Corp/CN=E2E Corp Issuing CA'
  printf '%s\n' 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,keyCertSign,cRLSign' 'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid' > issuing.ext
  openssl x509 -req -in corp-issuing.csr -CA corp-root.crt -CAkey corp-root.key -CAcreateserial -days 3 -extfile issuing.ext -out corp-issuing.crt
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=login.microsoftonline.com'
  printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=critical,digitalSignature' 'extendedKeyUsage=serverAuth' \
    "subjectAltName=DNS:login.microsoftonline.com,IP:$GW" 'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid' > leaf.ext
  openssl x509 -req -in leaf.csr -CA corp-issuing.crt -CAkey corp-issuing.key -CAcreateserial -days 3 -extfile leaf.ext -out leaf.crt
  cat corp-issuing.crt corp-root.crt > chain.pem
} > /dev/null 2>&1
if [ ! -s "$PKI/leaf.crt" ] || [ ! -s "$PKI/chain.pem" ]; then
  echo "FAIL  could not make the test certificates"
  exit 1
fi
ROOT_FP=$(openssl x509 -in "$PKI/corp-root.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')
ROOT_SHORT=$(printf '%s' "$ROOT_FP" | tr -d ':' | tr 'A-F' 'a-f' | cut -c1-8)

# What the interceptor serves: a JSON file for az and curl, a chart repository index for helm.
printf '{"ok": true}\n' > "$WORK/www/ok.json"
printf '<html><body>company network</body></html>\n' > "$WORK/www/index.html"
printf 'apiVersion: v1\nentries: {}\ngenerated: "2024-01-01T00:00:00Z"\n' > "$WORK/www/index.yaml"

docker rm -f "$NAME" > /dev/null 2>&1
if ! docker run -d --name "$NAME" -p 443:443 -v "$PKI:/pki:ro" -v "$WORK/www:/srv:ro" -w /srv "$IMAGE" \
  openssl s_server -accept 443 -cert /pki/leaf.crt -key /pki/leaf.key -cert_chain /pki/chain.pem -WWW > /dev/null; then
  echo "FAIL  could not start the container that plays the company network (is port 443 free?)"
  exit 1
fi
for _ in $(seq 1 100); do
  if docker logs "$NAME" 2>&1 | grep -q '^ACCEPT'; then break; fi
  sleep 0.2
done
if ! docker logs "$NAME" 2>&1 | grep -q '^ACCEPT'; then
  echo "FAIL  the container that plays the company network did not start:"
  docker logs "$NAME" 2>&1 | tail -n 20 | sed 's/^/      | /'
  exit 1
fi

# ---- helpers -------------------------------------------------------------------------------------
TLS_ERR='CERTIFICATE_VERIFY_FAILED|SSL certificate problem|certificate signed by unknown authority|SSL validation failed|self-signed certificate|self signed certificate|failed to verify certificate'
AZ_GET=(az rest --skip-authorization-header --method get --url https://login.microsoftonline.com/ok.json)

# A container on "the company network": the name az needs leads to the interceptor.
dr() { docker run --rm --add-host "login.microsoftonline.com:$GW" -e AWS_MAX_ATTEMPTS=1 -e AWS_EC2_METADATA_DISABLED=true "$@"; }
noca() { dr "$IMAGE" "$@"; }
withca() { dr -v "$CERTS:/usr/local/share/devtools-ca:ro" "$IMAGE" "$@"; }

# run COMMAND...   RC = exit code, OUT = everything it printed
run() {
  RC=0
  OUT=$("$@" 2>&1) || RC=$?
  OUT=${OUT//$'\r'/}
}
# run_split COMMAND...   the same, with the error output apart: ERR
run_split() {
  RC=0
  OUT=$("$@" 2> "$WORK/stderr.txt") || RC=$?
  OUT=${OUT//$'\r'/}
  ERR=$(tr -d '\r' < "$WORK/stderr.txt")
}
last_lines() { printf '%s\n' "$OUT" | tail -n 8 | cut -c1-240; }
section() { printf '%s\n' "$OUT" | awk -v n="@@$1" '$0 == n { on = 1; next } /^@@/ { on = 0 } on'; }

# The last run failed because it does not trust the certificate.
fails_tls() {
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE -- "$TLS_ERR"; then
    check_pass "$1"
  else
    check_fail "$1" "exit $RC, wanted a certificate error"$'\n'"$(last_lines)"
  fi
}
# The last run succeeded and printed NEEDLE.
works() {
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF -- "$2"; then
    check_pass "$1"
  else
    check_fail "$1" "exit $RC, wanted '$2'"$'\n'"$(last_lines)"
  fi
}
# The last run has no complaint about the certificate, whatever else it said (the interceptor is no real API).
gets_through() {
  if printf '%s' "$OUT" | grep -qE -- "$TLS_ERR"; then
    check_fail "$1" "$(last_lines)"
  else
    check_pass "$1"
  fi
}

echo "INFO  $(docker run --rm "$IMAGE" az version --query '"azure-cli"' --output tsv 2>&1 | tail -n 1) is the Azure CLI in this image; $(docker run --rm "$IMAGE" openssl version 2>&1 | head -n 1)"

# ---------------------------------------------------------------------------------------------------
echo "== the problem, as on the laptop"
# ---------------------------------------------------------------------------------------------------
run noca "${AZ_GET[@]}"
fails_tls 'without the company certificate az stops with a certificate error'
check_has 'and it is the one from the laptop' "$OUT" 'self-signed certificate in certificate chain'

run noca devtools-ca check "$GW:443"
check_eq 'devtools-ca check says it fails (exit 1)' "$RC" 1
check_has 'devtools-ca check explains TLS inspection' "$OUT" 'TLS inspection'
check_has 'devtools-ca check names the company CA' "$OUT" 'root CA  CN=E2E Corp Root CA,O=E2E Corp,C=US'
check_has 'devtools-ca check shows the fingerprint of the root' "$OUT" "sha256 $ROOT_FP"

# ---------------------------------------------------------------------------------------------------
echo "== a CA in the system store only (the image as it was): az does not look there"
# ---------------------------------------------------------------------------------------------------
run dr -v "$PKI:/pki:ro" "$IMAGE" bash -c '
  cp /pki/corp-root.crt /usr/local/share/ca-certificates/corp-root.crt
  update-ca-certificates > /dev/null 2>&1
  echo "@@curl";     curl -sS https://login.microsoftonline.com/ok.json 2>&1
  echo "@@az-own";   env -u REQUESTS_CA_BUNDLE -u SSL_CERT_FILE -u CURL_CA_BUNDLE az rest --skip-authorization-header --method get --url https://login.microsoftonline.com/ok.json 2>&1
  echo "@@az-image"; az rest --skip-authorization-header --method get --url https://login.microsoftonline.com/ok.json 2>&1
'
check_has 'curl trusts a CA that is in the system store' "$(section curl)" '"ok"'
check_has 'az with only its own list of certificates still refuses it: this is the reason' "$(section az-own)" 'CERTIFICATE_VERIFY_FAILED'
check_has "az with the image's defaults (REQUESTS_CA_BUNDLE is the system store) accepts it: a CA baked in at build time works" "$(section az-image)" '"ok"'

# ---------------------------------------------------------------------------------------------------
echo "== a certificate in the certs folder, trusted as the container starts"
# ---------------------------------------------------------------------------------------------------
mkdir -p "$CERTS"
cp "$PKI/corp-root.crt" "$CERTS/corp-root.crt"

run withca "${AZ_GET[@]}"
works 'az accepts the network after the CA is put in the certs folder' '"ok"'

run noca curl -sS https://login.microsoftonline.com/ok.json
fails_tls 'curl without it fails'
run withca curl -sS https://login.microsoftonline.com/ok.json
works 'curl with it works' '"ok"'

run noca git ls-remote https://login.microsoftonline.com/repo.git
fails_tls 'git without it fails'
run withca git ls-remote https://login.microsoftonline.com/repo.git
gets_through 'git with it gets as far as the server'

run noca kubectl --server=https://login.microsoftonline.com --token=x get --raw /ok.json
fails_tls 'kubectl (Go) without it fails'
run withca kubectl --server=https://login.microsoftonline.com --token=x get --raw /ok.json
works 'kubectl with it works' '"ok"'

run noca helm repo add e2e https://login.microsoftonline.com/
fails_tls 'helm (Go) without it fails'
run withca helm repo add e2e https://login.microsoftonline.com/
gets_through 'helm with it gets as far as the server'

run noca aws --region us-east-1 --endpoint-url https://login.microsoftonline.com sts get-caller-identity --no-sign-request
fails_tls 'the AWS CLI without it fails'
run withca aws --region us-east-1 --endpoint-url https://login.microsoftonline.com sts get-caller-identity --no-sign-request
gets_through 'the AWS CLI with it gets as far as the server'

# The login is a different code path (MSAL, which az brings along), and the one in the laptop's error.
LOGIN=(az login --service-principal -u 00000000-0000-0000-0000-000000000000 -p e2e-secret --tenant 11111111-1111-1111-1111-111111111111)
run noca "${LOGIN[@]}"
fails_tls 'az login without it fails with the same error (MSAL)'
run withca "${LOGIN[@]}"
gets_through 'az login with it gets as far as the server (MSAL)'

# ---------------------------------------------------------------------------------------------------
echo "== devtools-ca in the real image"
# ---------------------------------------------------------------------------------------------------
run withca devtools-ca check "$GW:443"
check_eq 'check with the CA trusted exits 0' "$RC" 0
check_has 'and says so' "$OUT" "ok: HTTPS to $GW verifies"

run_split noca devtools-ca fetch "$GW:443"
check_eq 'fetch exits 0' "$RC" 0
check_eq 'fetch prints the issuing CA and the root, not the server certificate' "$(printf '%s\n' "$OUT" | grep -c -e '-----BEGIN CERTIFICATE-----')" 2
check_has 'fetch comments each certificate with its subject' "$OUT" '# CN=E2E Corp Issuing CA,O=E2E Corp,C=US'
check_has 'and the fingerprint of the root' "$OUT" "# sha256 $ROOT_FP"
check_has 'fetch says on stderr what it found' "$ERR" 'The network signs it with:'
printf '%s\n' "$OUT" > "$WORK/fetched.pem"
mkdir -p "$WORK/certs-fetched"
cp "$WORK/fetched.pem" "$WORK/certs-fetched/fetched.crt"
run dr -v "$WORK/certs-fetched:/usr/local/share/devtools-ca:ro" "$IMAGE" devtools-ca check "$GW:443"
check_eq 'what fetch printed works as a certs file (check exits 0)' "$RC" 0
run dr -v "$WORK/certs-fetched:/usr/local/share/devtools-ca:ro" "$IMAGE" "${AZ_GET[@]}"
works 'and az trusts the network with it' '"ok"'

run withca devtools-ca fetch "$GW:443"
check_eq 'fetch with the CA already trusted exits 10' "$RC" 10

# Windows saves certificates as binary .CER files, often in capitals.
mkdir -p "$WORK/certs-der" "$WORK/certs-mixed"
openssl x509 -in "$PKI/corp-root.crt" -outform DER -out "$WORK/certs-der/ROOT.CER"
run dr -v "$WORK/certs-der:/usr/local/share/devtools-ca:ro" "$IMAGE" "${AZ_GET[@]}"
works 'a binary ROOT.CER (what Windows exports) is trusted too' '"ok"'
run_split dr -v "$WORK/certs-der/ROOT.CER:/devtools-ca-in/cert:ro" "$IMAGE" devtools-ca normalize /devtools-ca-in/cert
check_eq 'normalize turns it into PEM (exit 0)' "$RC" 0
check_has 'with the fingerprint in a comment' "$OUT" "# sha256 $ROOT_FP"

# A file that is not a certificate is named and skipped; the certificates next to it still count.
cp "$PKI/corp-root.crt" "$WORK/certs-mixed/corp-root.crt"
printf 'notes from IT\n' > "$WORK/certs-mixed/notes.pem"
run dr -v "$WORK/certs-mixed:/usr/local/share/devtools-ca:ro" "$IMAGE" "${AZ_GET[@]}"
works 'a folder with a stray file still trusts the certificate' '"ok"'
check_has 'and names the stray file' "$OUT" 'devtools: notes.pem in /usr/local/share/devtools-ca is not a certificate, so it is ignored.'

# docker compose (docker compose run dev) gets the same folder.
run docker compose -f "$ROOT/docker-compose.yml" config
check_has 'docker compose mounts the certs folder where the entrypoint reads it' "$OUT" 'target: /usr/local/share/devtools-ca'
check_has 'read-only' "$OUT" 'read_only: true'

# ---------------------------------------------------------------------------------------------------
echo "== the wrappers, for real: devtools-add-ca (bash) and Add-DevToolsCA (PowerShell)"
# ---------------------------------------------------------------------------------------------------
# The wrappers cannot add a host name, so they use the address: the certificate is valid for it too.
# shellcheck disable=SC2016  # these are expanded by the bash that runs the snippet, not by this one
BASH_SNIPPET='
. "$1"
echo "@@before"; az rest --skip-authorization-header --method get --url "https://$2/ok.json" 2>&1; echo "rc=$?"
echo "@@add";    devtools-add-ca --yes --host "$2:443" 2>&1; echo "rc=$?"
echo "@@after";  az rest --skip-authorization-header --method get --url "https://$2/ok.json" 2>&1; echo "rc=$?"
echo "@@info";   devtools-info
'
run env HOME="$WORK/home-sh" DEVTOOLS_IMAGE="$IMAGE" DEVTOOLS_VOLUME="$VOL" DEVTOOLS_CERTS="$WORK/wrap-certs-sh" \
  bash -c "$BASH_SNIPPET" _ "$ROOT/devtools.sh" "$GW"
check_has 'bash: before, az fails on the certificate' "$(section before)" 'CERTIFICATE_VERIFY_FAILED'
check_has 'bash: devtools-add-ca finds the CA and saves it' "$(section add)" "Saved $WORK/wrap-certs-sh/e2e-corp-root-ca-$ROOT_SHORT.crt"
check_has 'bash: and checks that it helps' "$(section add)" "ok: HTTPS to $GW verifies"
check_has 'bash: and says nothing has to be rebuilt' "$(section add)" 'Nothing has to be rebuilt'
check_has 'bash: it succeeds' "$(section add)" 'rc=0'
check_has 'bash: after, az trusts the network (the next command, nothing rebuilt)' "$(section after)" '"ok"'
check_has 'bash: devtools-info shows the certs folder' "$(section info)" "CertsFolder  $WORK/wrap-certs-sh"
check_has 'bash: and the one certificate file in it' "$(section info)" 'CertFiles    1'
check_eq 'bash: the file holds the issuing CA and the root' "$(grep -c -e '-----BEGIN CERTIFICATE-----' "$WORK/wrap-certs-sh/e2e-corp-root-ca-$ROOT_SHORT.crt" 2> /dev/null)" 2

cat > "$WORK/wrap.ps1" << 'PWSH'
param([string] $Module, [string] $Gw)
Import-Module $Module -Force
Write-Host '@@before'
az rest --skip-authorization-header --method get --url "https://$Gw/ok.json" 2>&1
Write-Host "rc=$LASTEXITCODE"
Write-Host '@@add'
Add-DevToolsCA -Yes -HostName "${Gw}:443" 2>&1
Write-Host '@@after'
az rest --skip-authorization-header --method get --url "https://$Gw/ok.json" 2>&1
Write-Host "rc=$LASTEXITCODE"
Write-Host '@@info'
(Get-DevToolsInfo | Format-List | Out-String).Trim()
PWSH
if command -v pwsh > /dev/null 2>&1; then
  run env HOME="$WORK/home-ps" DEVTOOLS_IMAGE="$IMAGE" DEVTOOLS_VOLUME="$VOL" DEVTOOLS_CERTS="$WORK/wrap-certs-ps" \
    DEVTOOLS_ALIASES="$WORK/no-aliases.ps1" DEVTOOLS_NO_READLINE=1 \
    pwsh -NoProfile -File "$WORK/wrap.ps1" "$ROOT/Devtools.psm1" "$GW"
  check_has 'PowerShell: before, az fails on the certificate' "$(section before)" 'CERTIFICATE_VERIFY_FAILED'
  check_has 'PowerShell: Add-DevToolsCA finds the CA and saves it' "$(section add)" "Saved $WORK/wrap-certs-ps/e2e-corp-root-ca-$ROOT_SHORT.crt"
  check_has 'PowerShell: and checks that it helps' "$(section add)" "ok: HTTPS to $GW verifies"
  check_has 'PowerShell: and says nothing has to be rebuilt' "$(section add)" 'Nothing has to be rebuilt'
  check_has 'PowerShell: after, az trusts the network (the next command, nothing rebuilt)' "$(section after)" '"ok"'
  check_has 'PowerShell: Get-DevToolsInfo shows the certs folder' "$(section info)" "$WORK/wrap-certs-ps"
  check_has 'PowerShell: and the one certificate file in it' "$(section info)" 'CertFiles'
  check_eq 'PowerShell: the file holds the issuing CA and the root' "$(grep -c -e '-----BEGIN CERTIFICATE-----' "$WORK/wrap-certs-ps/e2e-corp-root-ca-$ROOT_SHORT.crt" 2> /dev/null)" 2
else
  check_fail 'PowerShell: pwsh is not installed on this machine'
fi

# ---------------------------------------------------------------------------------------------------
# shellcheck disable=SC2154  # failures comes from lib.sh
if [ "$failures" -gt 0 ]; then
  echo
  echo "INFO  what the company network (openssl s_server) saw:"
  docker logs "$NAME" 2>&1 | tail -n 30 | cut -c1-200 | sed 's/^/      | /'
fi
check_summary
