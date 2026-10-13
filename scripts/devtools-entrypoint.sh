#!/bin/sh
# Container entrypoint for the devtools image.
#
# 1. Keeps traffic to the Docker Desktop host (its local Kubernetes API, host services)
#    off any corporate proxy by APPENDING to NO_PROXY / no_proxy. Existing values are
#    preserved. Without this, kubectl sends https://host.docker.internal:6443 to the
#    proxy, which cannot reach your laptop.
#
# 2. Trusts your company's certificate authority. The wrappers (and docker-compose.yml) mount the
#    toolbox's certs/ folder at /usr/local/share/devtools-ca; every certificate in it
#    (*.crt, *.cer, *.pem in any case; PEM or the binary form Windows saves) is trusted on top of the system
#    certificates. They are added to a copy of the system bundle, and the tools that take a bundle
#    from the environment are pointed at the copy. Azure CLI needs this most: it has a list of
#    certificates of its own and ignores the system's, so on a network that signs HTTPS again with
#    a company certificate (TLS inspection) az stops with "self-signed certificate in certificate
#    chain". Nothing mounted means nothing changes. No rebuild is needed when a certificate is added.
#    (The tests move the three places with DEVTOOLS_CA_DIR, DEVTOOLS_CA_SYSTEM_BUNDLE, DEVTOOLS_CA_BUNDLE.)
#
# Then runs whatever was asked for (default: bash).

extra="host.docker.internal,kubernetes.docker.internal,gateway.docker.internal"

NO_PROXY="${NO_PROXY:+$NO_PROXY,}$extra"
no_proxy="${no_proxy:+$no_proxy,}$extra"
export NO_PROXY no_proxy

ca_dir=${DEVTOOLS_CA_DIR:-/usr/local/share/devtools-ca}
ca_system=${DEVTOOLS_CA_SYSTEM_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
ca_bundle=${DEVTOOLS_CA_BUNDLE:-/tmp/devtools-ca-bundle.crt}
ca_count=0
if [ -d "$ca_dir" ]; then
  for ca_file in "$ca_dir"/*; do
    [ -f "$ca_file" ] || continue
    case $ca_file in
      *.[cC][rR][tT] | *.[cC][eE][rR] | *.[pP][eE][mM]) ;;   # Windows writes ROOT.CER as often as root.cer
      *) continue ;;
    esac
    # PEM text goes in as it is, without the CRs a Windows editor adds. A binary certificate is converted.
    if grep -q -e '-----BEGIN CERTIFICATE-----' "$ca_file" 2> /dev/null && openssl x509 -noout -in "$ca_file" 2> /dev/null; then
      ca_pem=$(tr -d '\r' < "$ca_file")
    elif ca_pem=$(openssl x509 -inform DER -in "$ca_file" 2> /dev/null); then
      :
    else
      echo "devtools: ${ca_file##*/} in $ca_dir is not a certificate, so it is ignored." >&2
      continue
    fi
    if [ "$ca_count" -eq 0 ] && ! cat "$ca_system" > "$ca_bundle" 2> /dev/null; then
      echo "devtools: could not write $ca_bundle, so the certificates in $ca_dir are not used." >&2
      break
    fi
    printf '\n%s\n' "$ca_pem" >> "$ca_bundle"
    ca_count=$((ca_count + 1))
  done
fi
if [ "$ca_count" -gt 0 ]; then
  REQUESTS_CA_BUNDLE=$ca_bundle
  SSL_CERT_FILE=$ca_bundle
  CURL_CA_BUNDLE=$ca_bundle
  AWS_CA_BUNDLE=$ca_bundle
  GIT_SSL_CAINFO=$ca_bundle
  export REQUESTS_CA_BUNDLE SSL_CERT_FILE CURL_CA_BUNDLE AWS_CA_BUNDLE GIT_SSL_CAINFO
fi

[ "$#" -gt 0 ] || set -- bash
exec "$@"
