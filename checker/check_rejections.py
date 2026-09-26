#!/usr/bin/env python3
"""拒否されるべきリクエストが拒否されることと、患者コンテキストで対象が絞られることを確かめる。

使い方（プロジェクトのフォルダで実行）:
    python3 checker/check_rejections.py
    python3 checker/check_rejections.py --wait-expiry   # アクセストークンの期限切れ（約 5 分待つ）も確かめる
"""
import argparse
import base64
import json
import sys
import time

import requests

import smart_client as sc

results = []


def report(name, expected, ok, actual):
    results.append(ok)
    print(f"[{'OK' if ok else 'NG'}] {name}")
    print(f"     期待: {expected}")
    print(f"     結果: {actual}")


def expect_auth_error(cfg, meta, name, error, description, scope, aud="default"):
    """認可サーバが、トークンを発行せずにエラーを返すことを確かめる"""
    expected = f"認可サーバが {error}（{description}）を返す"
    try:
        tok = sc.get_token(cfg, meta, scope, aud=aud)
        report(name, expected, False, f"トークンが発行された（scope={tok.get('scope')}）")
    except sc.CheckError as e:
        actual_error = e.detail.get("error")
        actual_desc = e.detail.get("error_description", "")
        report(name, expected, actual_error == error and description in actual_desc, f"{actual_error}: {actual_desc or e}")


def expect_status(cfg, name, token, path, status, note=""):
    st, body = sc.fhir_get(cfg, token, path)
    detail = sc.outcome_text(body)
    report(name, f"GET {path} が HTTP {status}{note}", st == status, f"HTTP {st}" + (f"  {detail}" if detail else ""))


def tamper(token, new_scope):
    """ペイロードの scope だけを書き換え、署名はそのまま残す"""
    header, _, signature = token.split(".")
    claims = sc.decode_jwt(token)[1]
    claims["scope"] = new_scope
    payload = base64.urlsafe_b64encode(json.dumps(claims, separators=(",", ":")).encode()).rstrip(b"=").decode()
    return f"{header}.{payload}.{signature}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wait-expiry", action="store_true",
                        help="アクセストークンの期限切れ（発行から約 5 分）まで待ち、拒否されることを確かめる")
    args = parser.parse_args()
    cfg, meta = sc.load_config()

    # 準備: 細粒度でないトークンで、確認に使う Observation と患者を調べる
    all_obs = sc.get_token(cfg, meta, "openid fhirUser user/Observation.rs")["access_token"]
    _, body = sc.fhir_get(cfg, all_obs, "Observation?category=laboratory&_count=1")
    lab = body["entry"][0]["resource"]
    _, body = sc.fhir_get(cfg, all_obs, "Observation?category=vital-signs&_count=1")
    vital = body["entry"][0]["resource"]
    patient_ref = lab["subject"]["reference"]
    patient_id = patient_ref.split("/", 1)[1]
    others = sc.search_all(cfg, all_obs, "Observation?category=laboratory&_count=100")["resources"]
    other_obs = next(o for o in others if o["subject"]["reference"] != patient_ref)
    print(f"確認に使う Observation: 検査 {lab['id']}、バイタル {vital['id']}、別の患者の検査 {other_obs['id']}")
    print(f"確認に使う患者: {patient_ref}\n")

    print("--- トークンの渡し方と中身")
    expect_status(cfg, "トークンなし", None, "Observation?_count=10", 401)
    st, _ = sc.fhir_get(cfg, None, f"Observation?_count=10&access_token={all_obs}")
    report("URL にトークンを入れる", "HTTP 401（トークンは Authorization ヘッダーで渡す必要がある）", st == 401, f"HTTP {st}")
    expect_status(cfg, "改ざんしたトークン（scope を user/*.rs に書き換え）", tamper(all_obs, "openid fhirUser user/*.rs"),
                  "Patient?_count=10", 401, "（署名が合わない）")

    print("\n--- aud（トークンの宛先）")
    other_aud = "https://localhost:8443/fhir/r5"
    wrong_aud = sc.get_token(cfg, meta, "openid fhirUser user/Observation.rs", aud=other_aud)["access_token"]
    aud = sc.decode_jwt(wrong_aud)[1].get("aud")
    report("aud を別の URL にする: 発行", "認可サーバはトークンを発行する", aud == other_aud, f"aud={aud}")
    expect_status(cfg, "aud を別の URL にする: 検索", wrong_aud, "Observation?_count=10", 401,
                  "（FHIR リポジトリが宛先の不一致で拒否する）")
    expect_auth_error(cfg, meta, "aud を省略する", "invalid_request", "No aud was specified",
                      "openid fhirUser user/Observation.rs", aud=None)

    print("\n--- スコープ")
    expect_auth_error(cfg, meta, "登録していないスコープ", "invalid_scope", "An unsupported scope was specified",
                      "openid fhirUser user/Observation.rs?category=social-history")
    expect_auth_error(cfg, meta, "インストーラが登録するワイルドカードのスコープ（user/*.rs、登録から消している）",
                      "invalid_scope", "An unsupported scope was specified", "openid fhirUser user/*.rs")
    expect_auth_error(cfg, meta, "スコープを省略する（既定のスコープを空にしているため）", "invalid_scope",
                      "No scope was specified or configured", None)
    no_resource = sc.get_token(cfg, meta, "openid fhirUser")["access_token"]
    expect_status(cfg, "リソースのスコープがない（openid fhirUser だけ）", no_resource, "Observation?_count=10", 401)

    print("\n--- 細粒度スコープ（検査だけ）")
    lab_only = sc.get_token(cfg, meta, "openid fhirUser user/Observation.rs?category=laboratory")["access_token"]
    expect_status(cfg, "許可されたカテゴリの read", lab_only, f"Observation/{lab['id']}", 200)
    expect_status(cfg, "許可されていないカテゴリの read", lab_only, f"Observation/{vital['id']}", 403)
    expect_status(cfg, "細粒度スコープで vread", lab_only, f"Observation/{lab['id']}/_history/1", 403, "（細粒度スコープでは未対応）")
    expect_status(cfg, "細粒度スコープで history", lab_only, f"Observation/{lab['id']}/_history", 403, "（細粒度スコープでは未対応）")
    expect_status(cfg, "（比較）細粒度でないスコープで vread", all_obs, f"Observation/{lab['id']}/_history/1", 200)

    print("\n--- 患者コンテキスト（patient/ スコープ）")
    no_context = sc.get_token(cfg, meta, "openid fhirUser launch/patient patient/Observation.rs")["access_token"]
    expect_status(cfg, "患者コンテキストなし", no_context, "Observation?_count=10", 401)
    with_context = sc.get_token(cfg, meta, "openid fhirUser launch/patient patient/Observation.rs",
                                extra={"claims": json.dumps({"patient": patient_id})})
    claims = sc.decode_jwt(with_context["access_token"])[1]
    s = sc.search_all(cfg, with_context["access_token"], "Observation?_count=100")
    subjects = sorted({r.get("subject", {}).get("reference") for r in s["resources"]})
    report("患者コンテキストあり: 検索", f"{patient_ref} の Observation だけが返る",
           s["status"] == 200 and subjects == [patient_ref],
           f"patient クレーム={claims.get('patient')}  HTTP {s['status']}  件数 {s['count']}  患者 {subjects}")
    expect_status(cfg, "患者コンテキストあり: 別の患者の read", with_context["access_token"],
                  f"Observation/{other_obs['id']}", 403)

    print("\n--- fhirUser（認可サーバが決めるクレーム）")
    spoof = json.dumps({"fhirUser": "Practitioner/someone-else"})
    no_scope = sc.get_token(cfg, meta, "openid user/Observation.rs", extra={"claims": spoof})
    value = sc.decode_jwt(no_scope["access_token"])[1].get("fhirUser")
    report("アプリが claims で fhirUser を指定する（fhirUser スコープなし）", "トークンに fhirUser が入らない",
           value is None, f"fhirUser={value}")
    with_scope = sc.get_token(cfg, meta, "openid fhirUser user/Observation.rs", extra={"claims": spoof})
    value = sc.decode_jwt(with_scope["access_token"])[1].get("fhirUser")
    report("アプリが claims で fhirUser を指定する（fhirUser スコープあり）", "アプリの指定ではなく、認可サーバの対応表の値が入る",
           value not in (None, "Practitioner/someone-else"), f"fhirUser={value}")

    if args.wait_expiry:
        print("\n--- 期限切れ")
        token = sc.get_token(cfg, meta, "openid fhirUser user/Observation.rs")["access_token"]
        exp = sc.decode_jwt(token)[1]["exp"]
        wait = exp - int(time.time()) + 15
        print(f"有効期限まで待ちます（約 {wait} 秒）")
        time.sleep(max(wait, 0))
        expect_status(cfg, "期限切れのトークン", token, "Observation?_count=10", 401)

    ok = sum(results)
    print(f"\n{ok} / {len(results)} 件が期待どおりでした。")
    sys.exit(0 if ok == len(results) else 1)


if __name__ == "__main__":
    try:
        main()
    except requests.exceptions.ConnectionError as e:
        sys.exit(f"接続できませんでした。docker compose up で起動しているか確認してください。{e}")
