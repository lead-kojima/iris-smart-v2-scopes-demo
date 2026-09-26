#!/bin/sh
# 分析アプリをヘッドレスの Chromium で操作するテスト（任意）。
# Playwright の公式イメージ（約 2.4 GB）を使う。イメージにはブラウザだけが入っているので、
# Python の playwright パッケージは実行のたびにコンテナの中に入れる。
# デモを docker compose up で起動してから実行する。
#   使い方: sh tools/browser-test/run.sh
set -eu
cd "$(dirname "$0")/../.."
docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/work" -w /work \
  mcr.microsoft.com/playwright/python:v1.63.0-noble \
  sh -c 'pip install -q --user --break-system-packages playwright==1.63.0 && python3 tools/browser-test/check_app.py'
