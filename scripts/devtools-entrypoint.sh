#!/bin/sh
# Container entrypoint for the devtools image.
#
# Keeps traffic to the Docker Desktop host (its local Kubernetes API, host services)
# off any corporate proxy by APPENDING to NO_PROXY / no_proxy. Existing values are
# preserved. Without this, kubectl sends https://host.docker.internal:6443 to the
# proxy, which cannot reach your laptop.
#
# Then runs whatever was asked for (default: bash).

extra="host.docker.internal,kubernetes.docker.internal,gateway.docker.internal"

NO_PROXY="${NO_PROXY:+$NO_PROXY,}$extra"
no_proxy="${no_proxy:+$no_proxy,}$extra"
export NO_PROXY no_proxy

[ "$#" -gt 0 ] || set -- bash
exec "$@"
