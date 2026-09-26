#!/bin/sh
# IRIS の起動後に実行される（Dockerfile の CMD --after）
echo "[iris-after] runtime setup start"
iris session IRIS -U %SYS < /opt/demo/runtime.script
echo "[iris-after] runtime setup end"
exit 0
