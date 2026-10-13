#!/usr/bin/env bash
# Tests for the part of the toolbox that trusts a company's certificate authority (README: "az fails
# with a certificate error"): scripts/devtools-ca.sh and the certificate step of
# scripts/devtools-entrypoint.sh.
#
# A set of throwaway certificate authorities is made first, and local `openssl s_server` processes
# play the network: one that signs HTTPS again with a company CA, the way a firewall that inspects
# TLS does (with and without the root CA in what it sends), and some that are plain wrong (another
# name, expired, signs itself). Nothing leaves the machine and no Docker is needed.
#
#     bash tests/test-ca.sh
#
# Needs OpenSSL 3, python3 and GNU timeout (the tools themselves run in the Debian image). The same
# flow against the real image, with the real Azure CLI, is tests/e2e-tls-inspection.sh.
# shellcheck disable=SC1091,SC2016
set -u
. "$(dirname -- "$0")/lib.sh"

echo "bash $BASH_VERSION on ${OSTYPE:-unknown}"
if ! openssl version 2> /dev/null | grep -q '^OpenSSL 3' || ! command -v python3 > /dev/null 2>&1 || ! command -v timeout > /dev/null 2>&1; then
  check_skip "certificate tests" "they need OpenSSL 3, python3 and timeout"
  check_summary
fi

CA_TOOL=$TEST_ROOT/scripts/devtools-ca.sh
ENTRYPOINT=$TEST_ROOT/scripts/devtools-entrypoint.sh
PROXY_PY=$TEST_ROOT/tests/fake_connect_proxy.py

# Nothing of the machine running the tests may leak into them.
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy \
  REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE AWS_CA_BUNDLE GIT_SSL_CAINFO \
  DEVTOOLS_CA_DIR DEVTOOLS_CA_SYSTEM_BUNDLE DEVTOOLS_CA_BUNDLE DEVTOOLS_CA_AZ_PYTHON

TMP=$(mktemp -d)
PKI=$TMP/pki
mkdir -p "$PKI"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$pid" 2> /dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# The certificates. "public" stands for the certificates every machine trusts; "corp" for the
# company whose network signs HTTPS again.
# ---------------------------------------------------------------------------------------------
KEYOPT=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1)

# new_ca NAME SUBJECT [ISSUER]   NAME.crt and NAME.key; signed by ISSUER, or by itself without one
new_ca() {
  local name=$1 subject=$2 issuer=${3:-}
  if [ -z "$issuer" ]; then
    openssl req -x509 "${KEYOPT[@]}" -nodes -keyout "$PKI/$name.key" -out "$PKI/$name.crt" -subj "$subject" -days 3650 \
      -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash'
  else
    openssl req -new "${KEYOPT[@]}" -nodes -keyout "$PKI/$name.key" -out "$PKI/$name.csr" -subj "$subject"
    printf '%s\n' 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,keyCertSign,cRLSign' \
      'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid' > "$PKI/$name.ext"
    openssl x509 -req -in "$PKI/$name.csr" -CA "$PKI/$issuer.crt" -CAkey "$PKI/$issuer.key" -CAcreateserial \
      -days 3650 -extfile "$PKI/$name.ext" -out "$PKI/$name.crt"
  fi
} 2> /dev/null

# leaf_request NAME SUBJECT SAN   NAME.key, NAME.csr and NAME.ext (what a server certificate needs)
leaf_request() {
  openssl req -new "${KEYOPT[@]}" -nodes -keyout "$PKI/$1.key" -out "$PKI/$1.csr" -subj "$2" 2> /dev/null
  printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=critical,digitalSignature' 'extendedKeyUsage=serverAuth' \
    "subjectAltName=$3" 'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid' > "$PKI/$1.ext"
}

# new_leaf NAME SUBJECT SAN ISSUER
new_leaf() {
  leaf_request "$1" "$2" "$3"
  openssl x509 -req -in "$PKI/$1.csr" -CA "$PKI/$4.crt" -CAkey "$PKI/$4.key" -CAcreateserial -days 825 \
    -extfile "$PKI/$1.ext" -out "$PKI/$1.crt" 2> /dev/null
}

SAN_LOCAL='DNS:localhost,IP:127.0.0.1'
new_ca public-root '/C=US/O=Public Example/CN=Public Test Root CA'
new_ca corp-root '/C=US/O=Example Corp/CN=Example Corp Root CA'
new_ca corp-issuing '/C=US/O=Example Corp/CN=Example Corp Issuing CA' corp-root
new_leaf inspected '/CN=inspected' "$SAN_LOCAL" corp-issuing        # what the inspecting network presents
new_leaf genuine '/CN=genuine' "$SAN_LOCAL" public-root             # a server every machine trusts
new_leaf wrongname '/CN=wrongname' 'DNS:other.example.test' public-root
openssl req -x509 "${KEYOPT[@]}" -nodes -keyout "$PKI/selfsigned.key" -out "$PKI/selfsigned.crt" -subj '/CN=selfsigned' \
  -days 30 -addext "subjectAltName=$SAN_LOCAL" -addext 'basicConstraints=CA:FALSE' 2> /dev/null

# An expired certificate needs `openssl ca`, which can back-date.
leaf_request expired '/CN=expired' "$SAN_LOCAL"
mkdir -p "$PKI/ca-db/newcerts"
: > "$PKI/ca-db/index.txt"
echo 1000 > "$PKI/ca-db/serial"
printf '%s\n' '[ca]' 'default_ca = CA_default' '[CA_default]' "database = $PKI/ca-db/index.txt" \
  "new_certs_dir = $PKI/ca-db/newcerts" "serial = $PKI/ca-db/serial" 'default_md = sha256' 'policy = policy_any' \
  'unique_subject = no' '[policy_any]' 'commonName = supplied' > "$PKI/ca.cnf"
openssl ca -batch -config "$PKI/ca.cnf" -cert "$PKI/public-root.crt" -keyfile "$PKI/public-root.key" \
  -in "$PKI/expired.csr" -out "$PKI/expired.crt" -startdate 20200101000000Z -enddate 20200102000000Z \
  -extfile "$PKI/expired.ext" -notext > /dev/null 2>&1

cat "$PKI/corp-issuing.crt" "$PKI/corp-root.crt" > "$PKI/chain-with-root.pem"
cp "$PKI/corp-issuing.crt" "$PKI/chain-no-root.pem"
cp "$PKI/public-root.crt" "$PKI/system.crt"                          # stands for /etc/ssl/certs/ca-certificates.crt
cat "$PKI/system.crt" "$PKI/corp-root.crt" > "$PKI/system+corp.crt"

for f in public-root corp-root corp-issuing inspected genuine wrongname selfsigned expired; do
  if [ ! -s "$PKI/$f.crt" ]; then
    echo "FAIL  could not make the test certificate $f"
    exit 1
  fi
done

fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^.*=//'; }
ROOT_FP=$(fingerprint "$PKI/corp-root.crt")
ISSUING_FP=$(fingerprint "$PKI/corp-issuing.crt")

# ---------------------------------------------------------------------------------------------
# The network.
# ---------------------------------------------------------------------------------------------
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

server_n=0
# start_server CERT KEY [CHAIN]   a TLS server on a free port (SERVER_PORT) that sends CERT, then the certificates in CHAIN
start_server() {
  local port i log chain=()
  server_n=$((server_n + 1))
  log=$TMP/server-$server_n.log
  if [ -n "${3:-}" ]; then chain=(-cert_chain "$3"); fi
  port=$(free_port)
  openssl s_server -accept "127.0.0.1:$port" -cert "$1" -key "$2" "${chain[@]+"${chain[@]}"}" -www < /dev/null > "$log" 2>&1 &
  PIDS+=("$!")
  for ((i = 0; i < 100; i++)); do
    if grep -q '^ACCEPT' "$log" 2> /dev/null; then
      SERVER_PORT=$port
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL  the test server for $1 did not start:"
  cat "$log"
  exit 1
}

start_server "$PKI/inspected.crt" "$PKI/inspected.key" "$PKI/chain-with-root.pem"
PORT_A=$SERVER_PORT        # inspected, root CA sent
start_server "$PKI/inspected.crt" "$PKI/inspected.key" "$PKI/chain-no-root.pem"
PORT_B=$SERVER_PORT        # inspected, the root CA is not sent
start_server "$PKI/inspected.crt" "$PKI/inspected.key"
PORT_C=$SERVER_PORT        # inspected, only its own certificate is sent
start_server "$PKI/genuine.crt" "$PKI/genuine.key"
PORT_G=$SERVER_PORT        # trusted by the "system" certificates
start_server "$PKI/wrongname.crt" "$PKI/wrongname.key"
PORT_W=$SERVER_PORT        # trusted, but for another name
start_server "$PKI/expired.crt" "$PKI/expired.key"
PORT_X=$SERVER_PORT        # trusted, but out of date
start_server "$PKI/selfsigned.crt" "$PKI/selfsigned.key"
PORT_S=$SERVER_PORT        # signs its own certificate
PORT_CLOSED=$(free_port)   # nothing listens here

# run_ca ARGS...   devtools-ca with $BUNDLE as the certificates it trusts   ->  OUT (stdout), ERR (stderr), RC
BUNDLE=$PKI/system.crt
run_ca() {
  RC=0
  OUT=$(REQUESTS_CA_BUNDLE=$BUNDLE "$BASH" "$CA_TOOL" "$@" 2> "$TMP/err.txt") || RC=$?
  ERR=$(< "$TMP/err.txt")
}

count_certs() { printf '%s\n' "$1" | grep -c -e '-----BEGIN CERTIFICATE-----'; }

# ---------------------------------------------------------------------------------------------
echo "== check"
# ---------------------------------------------------------------------------------------------
run_ca check "127.0.0.1:$PORT_G"
check_eq "check: a server the system trusts, by IP address, exits 0" "$RC" 0
check_has "check: and says so" "$OUT" "ok: HTTPS to 127.0.0.1 verifies"
run_ca check "localhost:$PORT_G"
check_eq "check: the same, by name" "$RC" 0
check_has "check: names the host" "$OUT" "ok: HTTPS to localhost verifies"

run_ca check "127.0.0.1:$PORT_A"
check_eq "check: a network that signs again (root sent) exits 1" "$RC" 1
check_has "check: says it does not verify" "$OUT" "FAILED: HTTPS to 127.0.0.1 does not verify: self-signed certificate in certificate chain"
check_has "check: explains TLS inspection" "$OUT" "TLS inspection"
check_has "check: lists the server's certificate" "$OUT" "server   CN=inspected"
check_has "check: lists the issuing CA" "$OUT" "CA       CN=Example Corp Issuing CA,O=Example Corp,C=US"
check_has "check: lists the root CA" "$OUT" "root CA  CN=Example Corp Root CA,O=Example Corp,C=US"
check_has "check: shows the root's fingerprint" "$OUT" "sha256 $ROOT_FP"
check_has "check: points at the commands that fix it" "$OUT" "Add-DevToolsCA"
check_has "check: and the bash one" "$OUT" "devtools-add-ca"

run_ca check "127.0.0.1:$PORT_B"
check_eq "check: root CA not sent exits 1" "$RC" 1
check_has "check: says the issuer is unknown" "$OUT" "unable to get local issuer certificate"
check_has "check: still explains TLS inspection" "$OUT" "TLS inspection"
run_ca check "127.0.0.1:$PORT_C"
check_eq "check: only the server's own certificate sent exits 1" "$RC" 1
check_has "check: says it does not verify" "$OUT" "FAILED: HTTPS to 127.0.0.1 does not verify"
run_ca check "127.0.0.1:$PORT_S"
check_eq "check: a server that signs itself exits 1" "$RC" 1
check_has "check: says so" "$OUT" "FAILED: HTTPS to 127.0.0.1 does not verify: self-signed certificate"
check_has "check: shows its fingerprint" "$OUT" "(signed by itself)"

run_ca check "127.0.0.1:$PORT_W"
check_eq "check: a certificate for another name exits 1" "$RC" 1
check_has "check: says the name is wrong" "$OUT" "for another name than 127.0.0.1"
run_ca check "localhost:$PORT_W"
check_eq "check: the same by host name" "$RC" 1
check_has "check: says the name is wrong (host name)" "$OUT" "for another name than localhost"
run_ca check "127.0.0.1:$PORT_X"
check_eq "check: an expired certificate exits 1" "$RC" 1
check_has "check: says it has expired" "$OUT" "certificate has expired"
check_has "check: mentions the clock" "$OUT" "Check the clock"

run_ca check "127.0.0.1:$PORT_CLOSED"
check_eq "check: nothing listening exits 2" "$RC" 2
check_has "check: says it could not connect" "$ERR" "Could not connect to 127.0.0.1:$PORT_CLOSED"
check_lacks "check: and nothing about certificates" "$OUT" "FAILED"

BUNDLE=$PKI/system+corp.crt
run_ca check "127.0.0.1:$PORT_A"
check_eq "check: with the company root trusted, root sent: exit 0" "$RC" 0
run_ca check "127.0.0.1:$PORT_B"
check_eq "check: with the company root trusted, root not sent: exit 0" "$RC" 0
run_ca check "localhost:$PORT_C"
check_eq "check: with the company root trusted, only the server sent: exit 1 (the issuing CA is missing)" "$RC" 1
BUNDLE=$PKI/system.crt

# Whose certificates count is REQUESTS_CA_BUNDLE, as it is for az.
OUT=$(REQUESTS_CA_BUNDLE=$PKI/system+corp.crt "$BASH" "$CA_TOOL" check "127.0.0.1:$PORT_A" 2>&1) && RC=0 || RC=$?
check_eq "check: reads the certificates it trusts from REQUESTS_CA_BUNDLE" "$RC" 0

# What az's own Python says counts too. A stand-in for it that refuses, and one that accepts:
printf '%s\n' '#!/bin/sh' 'echo "SSLError: CERTIFICATE_VERIFY_FAILED: Basic Constraints of CA cert not marked critical"' 'exit 3' > "$TMP/python-refuses"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TMP/python-accepts"
chmod +x "$TMP/python-refuses" "$TMP/python-accepts"
RC=0
OUT=$(DEVTOOLS_CA_AZ_PYTHON=$TMP/python-refuses REQUESTS_CA_BUNDLE=$PKI/system.crt "$BASH" "$CA_TOOL" check "127.0.0.1:$PORT_G" 2>&1) || RC=$?
check_eq "check: az's Python refusing a certificate openssl accepts exits 1" "$RC" 1
check_has "check: says whose objection it is" "$OUT" "FAILED: openssl accepts the certificate of 127.0.0.1, but az's own Python does not accept it"
check_has "check: and what it said" "$OUT" "Basic Constraints of CA cert not marked critical"
RC=0
OUT=$(DEVTOOLS_CA_AZ_PYTHON=$TMP/python-accepts REQUESTS_CA_BUNDLE=$PKI/system.crt "$BASH" "$CA_TOOL" check "127.0.0.1:$PORT_G" 2>&1) || RC=$?
check_eq "check: az's Python accepting it exits 0" "$RC" 0
RC=0
OUT=$(DEVTOOLS_CA_AZ_PYTHON=$(command -v python3) REQUESTS_CA_BUNDLE=$PKI/system.crt "$BASH" "$CA_TOOL" check "127.0.0.1:$PORT_G" 2>&1) || RC=$?
check_eq "check: a real Python (with requests, or without) agrees on a good certificate" "$RC" 0
RC=0
OUT=$(DEVTOOLS_CA_AZ_PYTHON=$TMP/does-not-exist REQUESTS_CA_BUNDLE=$PKI/system.crt "$BASH" "$CA_TOOL" check "127.0.0.1:$PORT_G" 2>&1) || RC=$?
check_eq "check: no Azure CLI in the image: nothing more to test, exit 0" "$RC" 0

# ---------------------------------------------------------------------------------------------
echo "== check, usage"
# ---------------------------------------------------------------------------------------------
run_ca
check_eq "no command exits 1" "$RC" 1
check_has "no command prints the usage" "$ERR" "usage: devtools-ca check"
run_ca frobnicate
check_eq "an unknown command exits 1" "$RC" 1
run_ca check 'bad host:notaport'
check_eq "check: a port that is not a number exits 1" "$RC" 1
check_has "check: says what is wrong" "$ERR" "is not HOST or HOST:PORT"
run_ca fetch ':443'
check_eq "fetch: no host exits 1" "$RC" 1
run_ca normalize
check_eq "normalize: no file exits 1" "$RC" 1
check_has "normalize: says there is no file" "$ERR" "there is no file"

# ---------------------------------------------------------------------------------------------
echo "== fetch"
# ---------------------------------------------------------------------------------------------
run_ca fetch "127.0.0.1:$PORT_A"
check_eq "fetch: a network that signs again (root sent) exits 0" "$RC" 0
check_eq "fetch: prints the issuing CA and the root, not the server's own certificate" "$(count_certs "$OUT")" 2
check_has "fetch: comment line with the issuing CA" "$OUT" "# CN=Example Corp Issuing CA,O=Example Corp,C=US"
check_has "fetch: comment line with its fingerprint" "$OUT" "# sha256 $ISSUING_FP"
check_has "fetch: comment line with the root" "$OUT" "# CN=Example Corp Root CA,O=Example Corp,C=US"
check_has "fetch: comment line with its fingerprint" "$OUT" "# sha256 $ROOT_FP"
check_lacks "fetch: no private key anywhere" "$OUT" "PRIVATE KEY"
check_lacks "fetch: no server certificate" "$OUT" "CN=inspected"
check_has "fetch: says on stderr what it found" "$ERR" "The network signs it with:"
check_has "fetch: and which root" "$ERR" "root CA  CN=Example Corp Root CA"
printf '%s\n' "$OUT" > "$TMP/fetched.pem"
cat "$PKI/system.crt" "$TMP/fetched.pem" > "$TMP/system+fetched.crt"
for p in "$PORT_A" "$PORT_B"; do
  RC=0
  REQUESTS_CA_BUNDLE=$TMP/system+fetched.crt "$BASH" "$CA_TOOL" check "127.0.0.1:$p" > /dev/null 2>&1 || RC=$?
  check_eq "fetch: what it printed, added to the trusted certificates, makes check pass (port $p)" "$RC" 0
done
RC=0
REQUESTS_CA_BUNDLE=$TMP/system+fetched.crt "$BASH" "$CA_TOOL" check "localhost:$PORT_C" > /dev/null 2>&1 || RC=$?
check_eq "fetch: and a server that sends only its own certificate verifies too" "$RC" 0

run_ca fetch "127.0.0.1:$PORT_B"
check_eq "fetch: root CA not sent exits 11" "$RC" 11
check_eq "fetch: and prints no certificate" "$OUT" ""
check_has "fetch: says the root was not sent" "$ERR" "did not send the root CA"
check_has "fetch: shows what was sent" "$ERR" "CN=Example Corp Issuing CA"
check_has "fetch: tells where to get the root" "$ERR" "export it from Windows"
run_ca fetch "127.0.0.1:$PORT_C"
check_eq "fetch: only the server's own certificate sent exits 11" "$RC" 11
check_eq "fetch: and prints no certificate" "$OUT" ""

run_ca fetch "127.0.0.1:$PORT_S"
check_eq "fetch: a server that signs itself exits 0" "$RC" 0
check_eq "fetch: prints that one certificate" "$(count_certs "$OUT")" 1
check_has "fetch: with its name" "$OUT" "# CN=selfsigned"
printf '%s\n' "$OUT" > "$TMP/selfsigned-fetched.pem"
RC=0
REQUESTS_CA_BUNDLE=$TMP/selfsigned-fetched.pem "$BASH" "$CA_TOOL" check "localhost:$PORT_S" > /dev/null 2>&1 || RC=$?
check_eq "fetch: and trusting it makes check pass" "$RC" 0

run_ca fetch "127.0.0.1:$PORT_G"
check_eq "fetch: a server that verifies already exits 10" "$RC" 10
check_eq "fetch: and prints nothing" "$OUT" ""
check_has "fetch: says there is nothing to add" "$ERR" "nothing to add"
run_ca fetch "127.0.0.1:$PORT_W"
check_eq "fetch: a wrong name is not a missing CA: exit 1" "$RC" 1
check_eq "fetch: and prints nothing" "$OUT" ""
check_has "fetch: says that is not the reason" "$ERR" "a missing CA certificate is not the reason"
run_ca fetch "127.0.0.1:$PORT_X"
check_eq "fetch: an expired certificate exits 1" "$RC" 1
run_ca fetch "127.0.0.1:$PORT_CLOSED"
check_eq "fetch: nothing listening exits 2" "$RC" 2
check_eq "fetch: and prints nothing" "$OUT" ""

# ---------------------------------------------------------------------------------------------
echo "== through a proxy"
# ---------------------------------------------------------------------------------------------
PROXY_PORT=$(free_port)
PROXY_LOG=$TMP/proxy.log
: > "$PROXY_LOG"
python3 "$PROXY_PY" "$PROXY_PORT" "$PROXY_LOG" > "$TMP/proxy.out" 2>&1 &
PIDS+=("$!")
for ((i = 0; i < 100; i++)); do
  if grep -q '^ready' "$TMP/proxy.out" 2> /dev/null; then break; fi
  sleep 0.1
done
check_has "the test proxy started" "$(cat "$TMP/proxy.out")" "ready"

export HTTPS_PROXY="http://someone:secret@127.0.0.1:$PROXY_PORT"
run_ca check "127.0.0.1:$PORT_A"
check_eq "proxy: check goes through HTTPS_PROXY and sees the company certificate" "$RC" 1
check_has "proxy: the failure is the certificate, not the proxy" "$OUT" "TLS inspection"
check_eq "proxy: the proxy was asked to CONNECT, without the password" "$(cat "$PROXY_LOG")" "CONNECT 127.0.0.1:$PORT_A"
: > "$PROXY_LOG"
run_ca fetch "127.0.0.1:$PORT_A"
check_eq "proxy: fetch works through it too" "$RC" 0
check_eq "proxy: fetch prints the two CA certificates" "$(count_certs "$OUT")" 2
check_eq "proxy: and also asked for a CONNECT" "$(cat "$PROXY_LOG")" "CONNECT 127.0.0.1:$PORT_A"

: > "$PROXY_LOG"
NO_PROXY="localhost, 127.0.0.1" run_ca check "127.0.0.1:$PORT_A"
check_eq "proxy: a host in NO_PROXY is reached directly (still the certificate failure)" "$RC" 1
check_eq "proxy: the proxy saw nothing" "$(cat "$PROXY_LOG")" ""
: > "$PROXY_LOG"
NO_PROXY='*' run_ca check "127.0.0.1:$PORT_A"
check_eq "proxy: NO_PROXY=* means direct" "$RC" 1
check_eq "proxy: the proxy saw nothing (*)" "$(cat "$PROXY_LOG")" ""
: > "$PROXY_LOG"
NO_PROXY='.example.test,localhost' run_ca check "127.0.0.1:$PORT_A"
check_eq "proxy: a NO_PROXY that does not match still uses the proxy" "$RC" 1
check_eq "proxy: the proxy saw it" "$(cat "$PROXY_LOG")" "CONNECT 127.0.0.1:$PORT_A"
unset HTTPS_PROXY

export https_proxy="127.0.0.1:$PROXY_PORT"
: > "$PROXY_LOG"
run_ca check "127.0.0.1:$PORT_A"
check_eq "proxy: https_proxy in lower case, without a scheme, works" "$(cat "$PROXY_LOG")" "CONNECT 127.0.0.1:$PORT_A"
unset https_proxy

export HTTPS_PROXY="http://127.0.0.1:$PORT_CLOSED"
run_ca check "127.0.0.1:$PORT_A"
check_eq "proxy: a proxy that is not there exits 2" "$RC" 2
check_has "proxy: and says it went through the proxy" "$ERR" "through the proxy 127.0.0.1:$PORT_CLOSED"
unset HTTPS_PROXY

# ---------------------------------------------------------------------------------------------
echo "== normalize"
# ---------------------------------------------------------------------------------------------
cat "$PKI/chain-with-root.pem" > "$TMP/two.pem"
openssl x509 -in "$PKI/corp-root.crt" -outform DER -out "$TMP/root.der"
sed 's/$/\r/' "$PKI/corp-root.crt" > "$TMP/root-crlf.crt"
{ echo "Subject: stuff the exporter wrote"; cat "$PKI/corp-issuing.crt"; echo "some notes between"; cat "$PKI/corp-root.crt"; echo "the end"; } > "$TMP/junk-around.pem"
openssl crl2pkcs7 -nocrl -certfile "$TMP/two.pem" -out "$TMP/two.p7b" -outform PEM
openssl crl2pkcs7 -nocrl -certfile "$TMP/two.pem" -out "$TMP/two-der.p7b" -outform DER

run_ca normalize "$PKI/corp-root.crt"
check_eq "normalize: a PEM file exits 0" "$RC" 0
check_has "normalize: with the subject as a comment" "$OUT" "# CN=Example Corp Root CA,O=Example Corp,C=US"
check_has "normalize: and the fingerprint" "$OUT" "# sha256 $ROOT_FP"
check_eq "normalize: one certificate" "$(count_certs "$OUT")" 1
run_ca normalize "$TMP/root-crlf.crt"
check_eq "normalize: a PEM file with Windows line ends exits 0" "$RC" 0
check_has "normalize: same certificate" "$OUT" "# sha256 $ROOT_FP"
check_lacks "normalize: no CR left" "$OUT" $'\r'
run_ca normalize "$TMP/root.der"
check_eq "normalize: a binary (DER) file, what Windows saves as .cer, exits 0" "$RC" 0
check_has "normalize: same certificate" "$OUT" "# sha256 $ROOT_FP"
check_has "normalize: as PEM" "$OUT" "-----BEGIN CERTIFICATE-----"
run_ca normalize "$TMP/two.pem"
check_eq "normalize: a PEM file with two certificates exits 0" "$RC" 0
check_eq "normalize: both come out" "$(count_certs "$OUT")" 2
run_ca normalize "$TMP/junk-around.pem"
check_eq "normalize: text between the certificates is dropped, exit 0" "$RC" 0
check_eq "normalize: both come out (junk)" "$(count_certs "$OUT")" 2
check_lacks "normalize: the text is gone" "$OUT" "some notes between"
run_ca normalize "$TMP/two.p7b"
check_eq "normalize: a PKCS#7 (.p7b) file exits 0" "$RC" 0
check_eq "normalize: both certificates come out" "$(count_certs "$OUT")" 2
check_has "normalize: the root is one of them" "$OUT" "# sha256 $ROOT_FP"
run_ca normalize "$TMP/two-der.p7b"
check_eq "normalize: a binary PKCS#7 file exits 0" "$RC" 0
check_eq "normalize: both certificates come out (binary)" "$(count_certs "$OUT")" 2

cat "$PKI/corp-root.crt" "$PKI/corp-root.key" > "$TMP/cert-and-key.pem"
run_ca normalize "$TMP/cert-and-key.pem"
check_eq "normalize: a file with a certificate and a private key exits 0" "$RC" 0
check_eq "normalize: only the certificate comes out" "$(count_certs "$OUT")" 1
check_lacks "normalize: the private key never does" "$OUT" "PRIVATE KEY"
run_ca normalize "$PKI/corp-root.key"
check_eq "normalize: a private key alone is not a certificate: exit 1" "$RC" 1
check_has "normalize: says so" "$ERR" "is not a certificate file"
check_eq "normalize: and prints nothing" "$OUT" ""
printf 'just some text\n' > "$TMP/text.crt"
run_ca normalize "$TMP/text.crt"
check_eq "normalize: a text file exits 1" "$RC" 1
check_has "normalize: and suggests how to export one" "$ERR" "Base-64 encoded X.509"
: > "$TMP/empty.crt"
run_ca normalize "$TMP/empty.crt"
check_eq "normalize: an empty file exits 1" "$RC" 1
{ echo '-----BEGIN CERTIFICATE-----'; echo 'bm90IGEgY2VydGlmaWNhdGU='; echo '-----END CERTIFICATE-----'; } > "$TMP/damaged.crt"
run_ca normalize "$TMP/damaged.crt"
check_eq "normalize: a damaged certificate exits 1" "$RC" 1
check_has "normalize: says it is damaged" "$ERR" "is damaged"
check_eq "normalize: and prints nothing" "$OUT" ""
run_ca normalize "$TMP/no-such-file.crt"
check_eq "normalize: a missing file exits 1" "$RC" 1
check_has "normalize: says there is no such file" "$ERR" "there is no file"

# ---------------------------------------------------------------------------------------------
echo "== entrypoint: trusting the certificates in certs/"
# ---------------------------------------------------------------------------------------------
# run_entry DIR COMMAND...   devtools-entrypoint with DIR as the folder of company certificates, the one
# system certificate (system.crt) as the system bundle  ->  OUT, ERR, RC
MERGED=$TMP/merged.crt
run_entry() {
  local dir=$1
  shift
  RC=0
  rm -f "$MERGED"
  OUT=$(DEVTOOLS_CA_DIR=$dir DEVTOOLS_CA_SYSTEM_BUNDLE=$PKI/system.crt DEVTOOLS_CA_BUNDLE=${ENTRY_BUNDLE:-$MERGED} \
    sh "$ENTRYPOINT" "$@" 2> "$TMP/err.txt") || RC=$?
  ERR=$(< "$TMP/err.txt")
}
SHOW_ENV='printf "%s\n" "${REQUESTS_CA_BUNDLE-unset}" "${SSL_CERT_FILE-unset}" "${CURL_CA_BUNDLE-unset}" "${AWS_CA_BUNDLE-unset}" "${GIT_SSL_CAINFO-unset}"'
five() { printf '%s\n%s\n%s\n%s\n%s' "$1" "$1" "$1" "$1" "$1"; }

mkdir -p "$TMP/certs-pem" "$TMP/certs-crlf" "$TMP/certs-der" "$TMP/certs-bundle" "$TMP/certs-space" "$TMP/certs-empty" "$TMP/certs-junk" "$TMP/certs-mixed" "$TMP/certs-upper"
cp "$PKI/corp-root.crt" "$TMP/certs-pem/example-corp.crt"
cp "$TMP/root-crlf.crt" "$TMP/certs-crlf/example-corp.crt"
cp "$TMP/root.der" "$TMP/certs-der/example-corp.cer"
cp "$TMP/junk-around.pem" "$TMP/certs-bundle/both.pem"
cp "$PKI/corp-root.crt" "$TMP/certs-space/my company ca.crt"
cp "$TMP/root.der" "$TMP/certs-upper/ROOT.CER"
printf 'These are the certificates of the company.\n' > "$TMP/certs-junk/README.md"
printf 'just some text\n' > "$TMP/certs-junk/notes.pem"
: > "$TMP/certs-junk/empty.crt"
cp "$PKI/corp-root.key" "$TMP/certs-junk/key.pem"
cp "$TMP/two.p7b" "$TMP/certs-junk/chain.cer"
cp "$PKI/corp-root.crt" "$TMP/certs-mixed/good.crt"
printf 'not a certificate\n' > "$TMP/certs-mixed/bad.crt"

run_entry "$TMP/certs-pem" sh -c "$SHOW_ENV"
check_eq "entrypoint: with a certificate, five variables point at the merged bundle" "$OUT" "$(five "$MERGED")"
check_eq "entrypoint: and nothing was said" "$ERR" ""
run_entry "$TMP/certs-pem" cat "$MERGED"
check_eq "entrypoint: the bundle holds the system certificate and the company's" "$(count_certs "$OUT")" 2
SYS_SIZE=$(wc -c < "$PKI/system.crt")
check_ok "entrypoint: it starts with the system bundle, unchanged" cmp -s -n "$SYS_SIZE" "$PKI/system.crt" "$MERGED"
check_eq "entrypoint: the system bundle itself was not touched" "$(count_certs "$(cat "$PKI/system.crt")")" 1

for form in pem crlf der bundle space upper; do
  case $form in
    pem) what="a PEM file" ;;
    crlf) what="a PEM file with Windows line ends" ;;
    der) what="a binary .cer file" ;;
    bundle) what="a PEM file with two certificates and text around them" ;;
    space) what="a file name with spaces" ;;
    upper) what="a binary ROOT.CER in capital letters (how Windows saves it)" ;;
  esac
  run_entry "$TMP/certs-$form" "$BASH" "$CA_TOOL" check "127.0.0.1:$PORT_A"
  check_eq "entrypoint: $what is trusted by devtools-ca" "$RC" 0
  check_lacks "entrypoint: no CR gets into the bundle ($form)" "$(cat "$MERGED")" $'\r'
done
run_entry "$TMP/certs-bundle" cat "$MERGED"
check_eq "entrypoint: both certificates of the bundle file are in it (plus the system one)" "$(count_certs "$OUT")" 3

run_entry "$TMP/certs-junk" sh -c "$SHOW_ENV"
check_eq "entrypoint: only files that are not certificates: the variables stay unset" "$OUT" "$(printf '%s\n%s\n%s\n%s\n%s' unset unset unset unset unset)"
check_has "entrypoint: says notes.pem is not a certificate" "$ERR" "notes.pem in $TMP/certs-junk is not a certificate, so it is ignored."
check_has "entrypoint: says empty.crt is not a certificate" "$ERR" "empty.crt in $TMP/certs-junk is not a certificate"
check_has "entrypoint: a private key is not a certificate either" "$ERR" "key.pem in $TMP/certs-junk is not a certificate"
check_has "entrypoint: a PKCS#7 file is not read here (Add-DevToolsCA converts it)" "$ERR" "chain.cer in $TMP/certs-junk is not a certificate"
check_lacks "entrypoint: README.md is not looked at" "$ERR" "README.md"
check_no "entrypoint: and no bundle is written for nothing" test -e "$MERGED"

run_entry "$TMP/certs-mixed" sh -c "$SHOW_ENV"
check_eq "entrypoint: one good file among bad ones is enough" "$OUT" "$(five "$MERGED")"
check_has "entrypoint: the bad one is named" "$ERR" "bad.crt in $TMP/certs-mixed is not a certificate"
check_lacks "entrypoint: the good one is not" "$ERR" "good.crt"

run_entry "$TMP/certs-empty" sh -c "$SHOW_ENV"
check_eq "entrypoint: an empty folder changes nothing" "$OUT" "$(printf '%s\n%s\n%s\n%s\n%s' unset unset unset unset unset)"
check_eq "entrypoint: and says nothing" "$ERR" ""
run_entry "$TMP/no-such-folder" sh -c "$SHOW_ENV"
check_eq "entrypoint: no folder changes nothing" "$OUT" "$(printf '%s\n%s\n%s\n%s\n%s' unset unset unset unset unset)"
check_eq "entrypoint: and says nothing (no folder)" "$ERR" ""
check_no "entrypoint: and no bundle is written for nothing (no folder)" test -e "$MERGED"

# Values the image sets (ENV in the Dockerfile) stay when there is nothing to add, and give way when there is.
RC=0
OUT=$(REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt DEVTOOLS_CA_DIR=$TMP/certs-empty sh "$ENTRYPOINT" sh -c 'echo "$REQUESTS_CA_BUNDLE"' 2>&1) || RC=$?
check_eq "entrypoint: nothing to add keeps the image's REQUESTS_CA_BUNDLE" "$OUT" "/etc/ssl/certs/ca-certificates.crt"
RC=0
OUT=$(REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt DEVTOOLS_CA_DIR=$TMP/certs-pem DEVTOOLS_CA_SYSTEM_BUNDLE=$PKI/system.crt DEVTOOLS_CA_BUNDLE=$MERGED \
  sh "$ENTRYPOINT" sh -c 'echo "$REQUESTS_CA_BUNDLE"' 2>&1) || RC=$?
check_eq "entrypoint: a certificate to add replaces it" "$OUT" "$MERGED"

ENTRY_BUNDLE=/no-such-folder/merged.crt
run_entry "$TMP/certs-pem" sh -c "$SHOW_ENV; echo still-ran"
check_eq "entrypoint: a bundle that cannot be written leaves the variables alone" "$OUT" "$(printf '%s\n%s\n%s\n%s\n%s\n%s' unset unset unset unset unset still-ran)"
check_has "entrypoint: and says so" "$ERR" "could not write /no-such-folder/merged.crt, so the certificates in $TMP/certs-pem are not used."
unset ENTRY_BUNDLE

# python's ssl module is a client like the others: SSL_CERT_FILE decides what it trusts.
PY_GET='import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=20).read()
except Exception as error:
    print(type(error).__name__, error)
    sys.exit(1)'
RC=0
OUT=$(SSL_CERT_FILE=$PKI/system.crt python3 -c "$PY_GET" "https://127.0.0.1:$PORT_A/" 2>&1) || RC=$?
check_eq "python: without the company certificate the network's certificate is refused" "$RC" 1
check_has "python: for the right reason" "$OUT" "CERTIFICATE_VERIFY_FAILED"
run_entry "$TMP/certs-der" python3 -c "$PY_GET" "https://127.0.0.1:$PORT_A/"
check_eq "python: with the certificate from certs/ (SSL_CERT_FILE) it is accepted" "$RC" 0

# The rest of what the entrypoint does is unchanged.
run_entry "$TMP/certs-empty" sh -c 'exit 7'
check_eq "entrypoint: the command's exit code is passed on" "$RC" 7
run_entry "$TMP/certs-empty" printf '%s|' 'two words' 'x'
check_eq "entrypoint: arguments with spaces stay one argument" "$OUT" "two words|x|"
RC=0
OUT=$(printf 'echo from-the-default-shell\n' | DEVTOOLS_CA_DIR=$TMP/certs-empty sh "$ENTRYPOINT" 2>&1) || RC=$?
check_eq "entrypoint: no command starts bash" "$OUT" "from-the-default-shell"
RC=0
OUT=$(NO_PROXY=intranet.example,10.0.0.0/8 no_proxy=intranet.example DEVTOOLS_CA_DIR=$TMP/certs-empty sh "$ENTRYPOINT" sh -c 'echo "$NO_PROXY"; echo "$no_proxy"' 2>&1) || RC=$?
check_eq "entrypoint: NO_PROXY keeps its entries and gets the Docker Desktop host names" "$OUT" \
  "intranet.example,10.0.0.0/8,host.docker.internal,kubernetes.docker.internal,gateway.docker.internal"$'\n'"intranet.example,host.docker.internal,kubernetes.docker.internal,gateway.docker.internal"
RC=0
OUT=$(DEVTOOLS_CA_DIR=$TMP/certs-empty sh "$ENTRYPOINT" sh -c 'echo "$NO_PROXY"' 2>&1) || RC=$?
check_eq "entrypoint: without a NO_PROXY it starts the list" "$OUT" "host.docker.internal,kubernetes.docker.internal,gateway.docker.internal"

check_summary
