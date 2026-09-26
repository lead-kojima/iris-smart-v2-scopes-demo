#!/bin/sh
# Synthea で合成患者データ（FHIR R4 のトランザクションバンドル）を作り、iris/data/fhir に置く。
# リポジトリには生成済みのデータが入っているので、作り直すときだけ実行する。
#   前提: Docker（Java は eclipse-temurin の公式イメージを使う）
#   使い方: sh tools/synthea/generate.sh
set -eu

cd "$(dirname "$0")"
SYNTHEA_VERSION=v4.0.0
JAR=synthea-with-dependencies.jar
DATA_DIR=../../iris/data/fhir

# Synthea 本体（約 200 MB）。公式の GitHub リリースから取得する
if [ ! -f "$JAR" ]; then
  curl -fL -o "$JAR.part" "https://github.com/synthetichealth/synthea/releases/download/$SYNTHEA_VERSION/$JAR"
  mv "$JAR.part" "$JAR"
fi

rm -rf output
# -p 人数、-s / -cs 乱数の種、-r 基準日、-a 年齢の範囲。種と基準日を固定しているので、同じデータが再生成される。
# 直近 1 年分だけを出力し、Observation が 200 件程度（8 名分）になるようにしている
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" -w /work eclipse-temurin:21-jre \
  java -jar "$JAR" -p 8 -s 20260918 -cs 20260918 -r 20260901 -a 40-75 \
    --exporter.baseDirectory ./output/ \
    --exporter.years_of_history 1 \
    --exporter.fhir.use_us_core_ig false \
    --exporter.fhir.excluded_resources Claim,ExplanationOfBenefit,Provenance,DocumentReference,Media,ImagingStudy,SupplyDelivery,Device,DiagnosticReport \
    --exporter.metadata.export false \
    --generate.only_alive_patients true \
    Massachusetts

# 参照される側（医療機関と医師）を先に読み込めるよう、フォルダを分けて置く。
# Synthea はファイル名に生成時刻を付けるので、作り直しても差分が出ないよう固定の名前にする
rm -rf "$DATA_DIR/1-synthea-org" "$DATA_DIR/2-synthea-patients"
mkdir -p "$DATA_DIR/1-synthea-org" "$DATA_DIR/2-synthea-patients"
mv output/fhir/hospitalInformation*.json "$DATA_DIR/1-synthea-org/hospitalInformation.json"
mv output/fhir/practitionerInformation*.json "$DATA_DIR/1-synthea-org/practitionerInformation.json"
mv output/fhir/*.json "$DATA_DIR/2-synthea-patients/"
rm -rf output
ls -l "$DATA_DIR/1-synthea-org" "$DATA_DIR/2-synthea-patients"
