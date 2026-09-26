#!/usr/bin/env python3
"""内蔵の認可サーバが SMART v2 の細粒度スコープを発行し、
FHIR リポジトリがスコープに応じて検索結果を絞るかを確かめる。

ブラウザの代わりに、認可コードフロー + PKCE でログインと同意を自動で行い、
スコープを変えたトークンで Observation を検索して件数を比べる。

使い方（プロジェクトのフォルダで実行）:
    python3 checker/check_scopes.py
    python3 checker/check_scopes.py --show-html   # ログイン画面の解析に失敗したとき、画面の HTML を表示する
"""
import argparse
import sys

import smart_client as sc

FINE_GRAINED_SCOPE = "user/Observation.rs?category=laboratory"

PATTERNS = [
    ("A", "検査結果だけ", f"openid fhirUser {FINE_GRAINED_SCOPE}"),
    ("B", "すべての観察データ", "openid fhirUser user/Observation.rs"),
    ("C", "Observation の許可なし", "openid fhirUser user/Patient.rs"),
]

QUERIES = ["Observation?_count=100", "Observation?category=laboratory&_count=100"]


def run_pattern(cfg, meta, key, label, scope, show_html):
    print(f"\n=== パターン {key}: {label}")
    print(f"要求するスコープ: {scope}")
    tokens = sc.get_token(cfg, meta, scope, show_html=show_html)
    access_token = tokens.get("access_token", "")
    jwt = sc.decode_jwt(access_token)
    claims = jwt[1] if jwt else {}
    print(f"トークン応答の scope: {tokens.get('scope')}")
    if not jwt:
        print("アクセストークンは JWT 形式ではありません（IRIS の FHIR リポジトリは JWT 形式のトークンだけを受け付けます）")
    else:
        print(f"アクセストークンの scope クレーム: {claims.get('scope')}")
        print(f"アクセストークンの aud: {claims.get('aud')}  iss: {claims.get('iss')}  sub: {claims.get('sub')}  fhirUser: {claims.get('fhirUser')}")
    searches = []
    for query in QUERIES:
        s = sc.search_all(cfg, access_token, query)
        searches.append(s)
        if s["status"] == 200:
            detail = f"件数 {s['count']}  カテゴリ内訳 {s['categories']}"
        else:
            detail = sc.outcome_text(s["body"])
        print(f"  GET {query} -> HTTP {s['status']}  {detail}")
    return {"claims": claims, "searches": searches}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--show-html", action="store_true", help="ログイン画面と同意画面の HTML を表示する")
    args = parser.parse_args()

    cfg, meta = sc.load_config()
    print(f"発行元: {meta.get('issuer')}")
    print(f"認可エンドポイント: {meta.get('authorization_endpoint')}")
    print(f"トークンエンドポイント: {meta.get('token_endpoint')}")

    results = {}
    for key, label, scope in PATTERNS:
        try:
            results[key] = run_pattern(cfg, meta, key, label, scope, args.show_html)
        except sc.CheckError as e:
            print(f"  失敗: {e}")
            results[key] = None

    print("\n=== 判定")
    a, b = results.get("A"), results.get("B")
    reasons = []
    if not a:
        reasons.append("パターン A でトークンを受け取れなかった")
    else:
        if FINE_GRAINED_SCOPE not in str(a["claims"].get("scope", "")):
            reasons.append("パターン A のトークンに細粒度スコープが残っていない")
        a_all = a["searches"][0]
        if a_all["status"] != 200:
            reasons.append(f"パターン A の検索が HTTP {a_all['status']} になった")
        elif set(a_all["categories"]) - {"laboratory"}:
            reasons.append(f"パターン A の検索に laboratory 以外が含まれた: {a_all['categories']}")
    if not b:
        reasons.append("パターン B でトークンを受け取れなかった")
    elif a and a["searches"][0]["status"] == 200 and b["searches"][0]["status"] == 200:
        if not (a["searches"][0]["count"] < b["searches"][0]["count"]):
            reasons.append("パターン A と B で検索件数に差が出なかった")

    if reasons:
        print("条件を満たしていません。")
        for r in reasons:
            print(f"  - {r}")
        sys.exit(1)
    print("条件を満たしました。内蔵の認可サーバで、細粒度スコープによる絞り込みが動いています。")


if __name__ == "__main__":
    main()
