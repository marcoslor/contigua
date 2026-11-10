#!/usr/bin/env bash
# Builds the losslab fake-phone image and prints the TLS check it passed.
set -euo pipefail
cd "$(dirname "$0")/../.."
docker build -q -f tools/netem/phone.Dockerfile -t pd-losslab-phone:local . >/dev/null
docker run --rm pd-losslab-phone:local python3 -c \
    'import sys, ssl, OpenSSL; print("python", sys.version.split()[0], "| ssl", ssl.OPENSSL_VERSION, "| pyOpenSSL", OpenSSL.__version__)'
