# The fake phone inside a Linux container, with a real kernel TCP underneath.
# Built once; no host package and no host network change.
FROM alpine:3.20
RUN apk add --no-cache python3 py3-openssl ffmpeg iproute2 openssl
RUN python3 -c 'import ssl, OpenSSL, sys; assert sys.version_info[:2] >= (3, 11); assert not ssl.OPENSSL_VERSION.startswith("LibreSSL"); print(sys.version.split()[0], ssl.OPENSSL_VERSION)'
