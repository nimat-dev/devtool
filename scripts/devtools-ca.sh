#!/usr/bin/env bash
# devtools-ca: what a network does to HTTPS, and which certificate authority is behind it.
#
# Some company networks open every HTTPS connection and sign it again with their own certificate
# (TLS inspection). Windows trusts the certificate authority behind that, because IT installed it.
# The toolbox does not, so az stops with "self-signed certificate in certificate chain". This
# command shows what the network presents and hands over the CA certificates, so they can be
# trusted (README: "Certificate errors").
#
#   devtools-ca check [HOST[:PORT]]     does HTTPS to HOST verify with what the toolbox trusts?
#                                       exit 0 yes, 1 no, 2 could not connect
#   devtools-ca fetch [HOST[:PORT]]     print (PEM) the CA certificates the server sends, when they
#                                       are not trusted yet; the details go to stderr
#                                       exit 0 printed, 10 nothing to add, 11 the root CA was not
#                                       sent, 2 could not connect, 1 something else is wrong
#   devtools-ca normalize FILE          print a certificate file (PEM, DER or PKCS#7) as PEM
#                                       exit 0, or 1 when the file holds no certificate
#
# HOST defaults to login.microsoftonline.com (what az needs), PORT to 443. HTTPS_PROXY is used the
# way az uses it. What counts as trusted is REQUESTS_CA_BUNDLE, which devtools-entrypoint points at
# the system certificates plus whatever is in certs/. (The tests move the Azure CLI's Python with
# DEVTOOLS_CA_AZ_PYTHON.)
set -u

DEFAULT_HOST=login.microsoftonline.com
BUNDLE=${REQUESTS_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
AZ_PYTHON=${DEVTOOLS_CA_AZ_PYTHON:-/opt/az/bin/python3}

work=$(mktemp -d) || {
  echo "devtools-ca: could not make a temporary folder" >&2
  exit 1
}
trap 'rm -rf "$work"' EXIT

usage() {
  cat >&2 << 'EOF'
usage: devtools-ca check [HOST[:PORT]]
       devtools-ca fetch [HOST[:PORT]]
       devtools-ca normalize FILE
EOF
}

# parse_target [HOST[:PORT]]  ->  HOST and PORT
parse_target() {
  local target=${1:-$DEFAULT_HOST}
  HOST=${target%%:*}
  PORT=443
  case $target in *:*) PORT=${target##*:} ;; esac
  case $PORT in '' | *[!0-9]*) HOST='' ;; esac
  if [ -z "$HOST" ]; then
    echo "devtools-ca: '$target' is not HOST or HOST:PORT" >&2
    exit 1
  fi
}

is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# The HTTPS proxy az would use for HOST, as host:port, or nothing. Credentials in the URL are
# dropped: openssl cannot send them, and a proxy that needs them is reported as a failed connection.
proxy_for() {
  local proxy=${HTTPS_PROXY:-${https_proxy:-}} entry
  local -a skip=()
  [ -n "$proxy" ] || return 0
  IFS=, read -r -a skip <<< "${NO_PROXY:-${no_proxy:-}}"
  for entry in "${skip[@]+"${skip[@]}"}"; do
    entry=${entry// /}
    entry=${entry#.}
    [ -n "$entry" ] || continue
    if [ "$entry" = '*' ] || [ "$1" = "$entry" ] || [[ $1 == *".$entry" ]]; then return 0; fi
  done
  proxy=${proxy#*://}
  proxy=${proxy%%/*}
  proxy=${proxy##*@}
  printf '%s\n' "$proxy"
}

# cert_info FILE  ->  C_SUBJECT C_ISSUER C_SHA256
cert_info() {
  local line
  C_SUBJECT='' C_ISSUER='' C_SHA256=''
  while IFS= read -r line; do
    case $line in
      subject=*) C_SUBJECT=${line#subject=} ;;
      issuer=*) C_ISSUER=${line#issuer=} ;;
      *Fingerprint=*) C_SHA256=${line#*Fingerprint=} ;;
    esac
  done < <(openssl x509 -in "$1" -noout -subject -issuer -fingerprint -sha256 -nameopt RFC2253 2> /dev/null)
}

# emit_pem FILE  prints one certificate as PEM with two lines of comment above it. Every program
# that reads a certificate file skips text before the BEGIN line.
emit_pem() {
  cert_info "$1"
  printf '# %s\n# sha256 %s\n' "$C_SUBJECT" "$C_SHA256"
  openssl x509 -in "$1" -outform PEM
}

# split_pem FILE PREFIX  writes every certificate of a PEM file to PREFIX-01.pem, PREFIX-02.pem ...
# and prints how many there were. Only the certificates are taken, whatever else the file holds.
split_pem() {
  awk -v prefix="$2" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s-%02d.pem", prefix, n); on = 1 }
    on { print > out }
    /-----END CERTIFICATE-----/ { on = 0; close(out) }
    END { print n + 0 }
  ' "$1"
}

# probe: one TLS handshake with HOST:PORT, verified against $BUNDLE the way a client would. Sets
# VERIFY_CODE and VERIFY_TEXT, and leaves the certificates the server sent in $work/chain-NN.pem
# (the server's own first); CHAIN_N is how many. Returns 2 when there was no handshake at all.
probe() {
  local -a args=(-connect "$HOST:$PORT" -showcerts -CAfile "$BUNDLE" -no-CApath -no-CAstore)
  local proxy line
  if is_ip "$HOST"; then
    args+=(-noservername -verify_ip "$HOST")
  else
    args+=(-servername "$HOST" -verify_hostname "$HOST")
  fi
  proxy=$(proxy_for "$HOST")
  if [ -n "$proxy" ]; then args+=(-proxy "$proxy"); fi

  timeout 25 openssl s_client "${args[@]}" < /dev/null > "$work/s_client.txt" 2>&1
  line=$(grep -m1 -E '^[[:space:]]*Verify return code: ' "$work/s_client.txt") || return 2
  VERIFY_CODE=${line#*: }
  VERIFY_CODE=${VERIFY_CODE%% *}
  VERIFY_TEXT=${line#*\(}
  VERIFY_TEXT=${VERIFY_TEXT%)*}

  # Only the "Certificate chain" part: the server's own certificate is printed a second time below it.
  sed -n '/^Certificate chain/,/^---$/p' "$work/s_client.txt" > "$work/chain.txt"
  CHAIN_N=$(split_pem "$work/chain.txt" "$work/chain")
}

say_no_connection() {
  local reason proxy
  reason=$(grep -m1 -iE 'error|refused|timed out|unreachable|resolve|lookup' "$work/s_client.txt" | cut -c1-200)
  proxy=$(proxy_for "$HOST")
  echo "Could not connect to $HOST:$PORT${proxy:+ (through the proxy $proxy)}.${reason:+ $reason}" >&2
  echo "Is the network up, and is this the proxy setting you need (HTTPS_PROXY in .env, then rebuild)?" >&2
}

# print_chain: what the server sent, one line each (and the fingerprint under a CA)
print_chain() {
  local i f label
  for ((i = 1; i <= CHAIN_N; i++)); do
    printf -v f '%s/chain-%02d.pem' "$work" "$i"
    cert_info "$f"
    if [ "$i" -eq 1 ]; then
      label='server'
    elif [ "$C_SUBJECT" = "$C_ISSUER" ]; then
      label='root CA'
    else
      label='CA'
    fi
    printf '  %-8s %s\n' "$label" "$C_SUBJECT"
    if [ "$i" -gt 1 ]; then
      printf '  %-8s sha256 %s\n' '' "$C_SHA256"
    elif [ "$C_SUBJECT" = "$C_ISSUER" ]; then
      printf '  %-8s sha256 %s (signed by itself)\n' '' "$C_SHA256"
    fi
  done
}

# Does az's own Python (it has its own list of certificates, which REQUESTS_CA_BUNDLE replaces) accept
# HOST? Prints the reason when it does not. Nothing to test when this image has no Azure CLI.
az_python_accepts() {
  local url="https://$HOST:$PORT/" out
  [ -x "$AZ_PYTHON" ] || return 0
  out=$("$AZ_PYTHON" - "$url" << 'PY' 2>&1
import sys

try:
    import requests
except ImportError:
    sys.exit(0)                                # not the Azure CLI's Python: nothing to test

try:
    requests.get(sys.argv[1], timeout=20)      # any answer will do: only the certificate is looked at
except requests.exceptions.SSLError as error:
    print(error)
    sys.exit(3)
except Exception:
    pass                                       # not reachable for this client: nothing to say about certificates
PY
  ) || {
    echo "az's own Python does not accept it: $(printf '%s' "$out" | tail -n 1 | cut -c1-300)"
    return 1
  }
}

cmd_check() {
  local rc=0 message
  parse_target "${1:-}"
  probe || rc=$?
  if [ "$rc" -eq 2 ]; then
    say_no_connection
    return 2
  fi
  if [ "$VERIFY_CODE" != 0 ]; then
    echo "FAILED: HTTPS to $HOST does not verify: $VERIFY_TEXT"
    case $VERIFY_CODE in
      18 | 19 | 20 | 21)
        echo "Something on this network opens HTTPS connections and signs them again with its own"
        echo "certificate (TLS inspection), and the toolbox does not trust that certificate yet."
        echo "What the server sent:"
        print_chain
        echo "Trust it with  Add-DevToolsCA  (PowerShell)  or  devtools-add-ca  (bash)  on your computer." ;;
      9 | 10)
        echo "A certificate is not valid yet or has expired. Check the clock: here it is $(date -u '+%Y-%m-%d %H:%M UTC')."
        echo "After the computer sleeps, Docker Desktop's clock can be wrong; restarting Docker Desktop fixes that." ;;
      62 | 64)
        echo "The certificate is for another name than $HOST." ;;
    esac
    return 1
  fi
  if ! message=$(az_python_accepts); then
    echo "FAILED: openssl accepts the certificate of $HOST, but $message"
    return 1
  fi
  echo "ok: HTTPS to $HOST verifies with the certificates the toolbox trusts."
}

cmd_fetch() {
  local rc=0 i f top=0 first=2
  parse_target "${1:-}"
  probe || rc=$?
  if [ "$rc" -eq 2 ]; then
    say_no_connection
    return 2
  fi
  if [ "$VERIFY_CODE" = 0 ]; then
    echo "HTTPS to $HOST already verifies: there is nothing to add." >&2
    return 10
  fi
  case $VERIFY_CODE in
    18 | 19 | 20 | 21) ;;
    *)
      echo "HTTPS to $HOST does not verify ($VERIFY_TEXT), and a missing CA certificate is not the reason." >&2
      return 1 ;;
  esac

  # What to trust: the CA certificates after the server's own, up to the first one that signed itself.
  # A server whose own certificate signs itself (error 18) has nothing else: that one is it.
  for ((i = 1; i <= CHAIN_N; i++)); do
    printf -v f '%s/chain-%02d.pem' "$work" "$i"
    cert_info "$f"
    if [ "$C_SUBJECT" = "$C_ISSUER" ]; then
      top=$i
      break
    fi
  done
  if [ "$top" -eq 0 ]; then
    {
      echo "HTTPS to $HOST does not verify ($VERIFY_TEXT), and the server did not send the root CA:"
      print_chain
      echo "Get the root CA certificate from your IT team, or export it from Windows, and add that file instead."
    } >&2
    return 11
  fi

  {
    echo "HTTPS to $HOST does not verify ($VERIFY_TEXT). The network signs it with:"
    print_chain
  } >&2
  if [ "$top" -eq 1 ]; then first=1; fi
  for ((i = first; i <= top; i++)); do
    printf -v f '%s/chain-%02d.pem' "$work" "$i"
    emit_pem "$f"
  done
}

cmd_normalize() {
  local file=${1:-} count=0 i f
  if [ ! -f "$file" ]; then
    echo "devtools-ca: there is no file $file" >&2
    return 1
  fi
  if grep -q -e '-----BEGIN CERTIFICATE-----' "$file"; then
    count=$(split_pem "$file" "$work/in")
  elif openssl x509 -inform DER -in "$file" -outform PEM > "$work/in-01.pem" 2> /dev/null; then
    count=1
  elif grep -q -e '-----BEGIN PKCS7-----' "$file" && openssl pkcs7 -in "$file" -print_certs > "$work/p7.txt" 2> /dev/null; then
    count=$(split_pem "$work/p7.txt" "$work/in")
  elif openssl pkcs7 -inform DER -in "$file" -print_certs > "$work/p7.txt" 2> /dev/null; then
    count=$(split_pem "$work/p7.txt" "$work/in")
  fi
  if [ "$count" -eq 0 ]; then
    echo "devtools-ca: $file is not a certificate file. Export it from Windows as 'Base-64 encoded X.509 (.CER)' and try again." >&2
    return 1
  fi
  for ((i = 1; i <= count; i++)); do
    printf -v f '%s/in-%02d.pem' "$work" "$i"
    if ! openssl x509 -in "$f" -noout 2> /dev/null; then
      echo "devtools-ca: certificate number $i in $file is damaged." >&2
      return 1
    fi
  done
  for ((i = 1; i <= count; i++)); do
    printf -v f '%s/in-%02d.pem' "$work" "$i"
    emit_pem "$f"
  done
}

case ${1:-} in
  check) cmd_check "${2:-}" ;;
  fetch) cmd_fetch "${2:-}" ;;
  normalize) cmd_normalize "${2:-}" ;;
  *)
    usage
    exit 1 ;;
esac
