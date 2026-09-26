#!/bin/sh
# Web Gateway コンテナの起動スクリプト
#   1. 自己署名証明書がなければ作る
#   2. IRIS コンテナ（irisowner）が共有フォルダに書き込めるようにする
#   3. SSL モジュールを有効にして Web Gateway（Apache）を起動する
set -eu

CERT_DIR=/webgateway-shared/certs
HOST="${TLS_HOSTNAME:-localhost}"

mkdir -p "$CERT_DIR"
if [ ! -s "$CERT_DIR/server.crt" ] || [ ! -s "$CERT_DIR/server.key" ]; then
  echo "[webgateway] creating self-signed certificate for $HOST"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
    -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
    -subj "/CN=$HOST" \
    -addext "subjectAltName=DNS:$HOST,IP:127.0.0.1"
  chmod 644 "$CERT_DIR/server.crt"
  chmod 600 "$CERT_DIR/server.key"
fi

mkdir -p /shared
chmod 0777 /shared

exec /startWebGateway -ssl
