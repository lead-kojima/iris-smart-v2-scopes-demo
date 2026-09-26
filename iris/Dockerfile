FROM containers.intersystems.com/intersystems/irishealth-community:2026.1

USER root
RUN mkdir -p /opt/demo && chown irisowner:irisowner /opt/demo
USER irisowner
WORKDIR /opt/demo

# src/sys は %SYS に、src/hssys は認可サーバのカスタマイズ用ネームスペース（HSSYS）に読み込む
COPY --chown=irisowner:irisowner src/ /opt/demo/src/
COPY --chown=irisowner:irisowner data/ /opt/demo/data/
COPY --chown=irisowner:irisowner app/ /opt/demo/app/
COPY --chown=irisowner:irisowner build.script runtime.script after.sh /opt/demo/

# イメージを作るときに、ネームスペース、FHIR リポジトリ、サンプルデータ、
# 内蔵の認可サーバ、クライアントの登録、アプリの Web アプリケーションまで済ませる
RUN iris start IRIS \
 && iris session IRIS < /opt/demo/build.script \
 && iris stop IRIS quietly

# 起動後に、Web Gateway の HTTPS が必要な設定（サーバ定義の検出など）を行う
CMD ["--after", "sh /opt/demo/after.sh"]
