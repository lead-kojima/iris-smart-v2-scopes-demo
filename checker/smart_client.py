"""確認スクリプトが共通で使う処理。

ブラウザの代わりに、認可コードフロー + PKCE でログインと同意を行い、
アクセストークンを受け取って FHIR リポジトリを検索する。
"""
import base64
import hashlib
import html.parser
import json
import os
import secrets
import urllib.parse

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_FILE = os.path.join(ROOT, "shared", "demo-config.json")
CERT_FILE = os.path.join(ROOT, "webgateway", "certs", "server.crt")


class CheckError(Exception):
    """認可サーバやトークンエンドポイントがエラーを返したときに使う"""

    def __init__(self, message, detail=None):
        super().__init__(message)
        self.detail = detail or {}


class FormParser(html.parser.HTMLParser):
    """画面の HTML から form と input を取り出す"""

    def __init__(self):
        super().__init__()
        self.forms = []
        self._form = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self._form = {"action": a.get("action") or "", "method": (a.get("method") or "get").lower(), "fields": []}
            self.forms.append(self._form)
        elif tag in ("input", "button") and self._form is not None:
            default_type = "submit" if tag == "button" else "text"
            self._form["fields"].append({
                "type": (a.get("type") or default_type).lower(),
                "name": a.get("name"),
                "value": a.get("value") or "",
            })

    def handle_endtag(self, tag):
        if tag == "form":
            self._form = None


def load_config():
    """IRIS が起動後に書き出す設定と、認可サーバのメタデータを読み込む"""
    if not os.path.exists(CONFIG_FILE):
        raise SystemExit(f"{CONFIG_FILE} がありません。docker compose up のあと、IRIS の起動後の設定が終わるまで待ってください。")
    if not os.path.exists(CERT_FILE):
        raise SystemExit(f"{CERT_FILE} がありません。Web Gateway が起動しているか確認してください。")
    with open(CONFIG_FILE, encoding="utf-8") as f:
        cfg = json.load(f)
    meta = requests.get(cfg["issuer"] + "/.well-known/openid-configuration", verify=CERT_FILE).json()
    return cfg, meta


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decode_jwt(token):
    """JWT のヘッダーとペイロードを返す（署名は確かめない）。JWT でなければ None"""
    parts = (token or "").split(".")
    if len(parts) != 3:
        return None

    def dec(s):
        return json.loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))

    return dec(parts[0]), dec(parts[1])


def pick_submit(fields):
    """同意やログインを進めるボタンを選ぶ（キャンセル系は避ける）"""
    submits = [f for f in fields if f["type"] in ("submit", "image") and f["name"]]
    negative = ("cancel", "deny", "reject", "キャンセル", "拒否")
    positive = ("accept", "allow", "approve", "login", "log in", "sign in", "submit", "ok", "許可", "ログイン")
    for f in submits:
        text = (f["name"] + " " + f["value"]).lower()
        if any(p in text for p in positive) and not any(n in text for n in negative):
            return f
    for f in submits:
        text = (f["name"] + " " + f["value"]).lower()
        if not any(n in text for n in negative):
            return f
    return None


def authorize(cfg, meta, scope=None, aud="default", extra=None, show_html=False):
    """認可コードフロー + PKCE でログインと同意を行い、(session, code, verifier) を返す。

    scope=None なら scope パラメータを送らない。aud=None なら aud パラメータを送らない。
    """
    session = requests.Session()
    session.verify = CERT_FILE
    verifier = b64url(secrets.token_bytes(48))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    state = secrets.token_urlsafe(16)
    params = {
        "response_type": "code",
        "client_id": cfg["clientId"],
        "redirect_uri": cfg["redirectUri"],
        "state": state,
        "nonce": secrets.token_urlsafe(16),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if scope is not None:
        params["scope"] = scope
    if aud == "default":
        params["aud"] = cfg["fhirBaseUrl"]
    elif aud is not None:
        params["aud"] = aud
    params.update(extra or {})
    url = meta["authorization_endpoint"] + "?" + urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    resp = session.get(url, allow_redirects=False)

    for _ in range(12):
        if resp.status_code in (301, 302, 303, 307, 308):
            location = urllib.parse.urljoin(resp.url, resp.headers.get("Location", ""))
            if location.startswith(cfg["redirectUri"]):
                parsed = urllib.parse.urlparse(location)
                # IRIS はエラーをフラグメント（# 以降）で返すことがあるので、両方を見る
                result = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
                result.update({k: v[0] for k, v in urllib.parse.parse_qs(parsed.fragment).items()})
                if "error" in result:
                    raise CheckError(f"認可サーバがエラーを返しました: {result.get('error')} {result.get('error_description', '')}", result)
                if result.get("state") != state:
                    raise CheckError("state が一致しません", result)
                if "code" not in result:
                    raise CheckError(f"認可コードがありません: {location}", result)
                return session, result["code"], verifier
            resp = session.get(location, allow_redirects=False)
            continue

        if resp.status_code != 200:
            raise CheckError(f"認可エンドポイントが HTTP {resp.status_code} を返しました: {resp.text[:800]}")

        if show_html:
            print("----- 画面の HTML -----")
            print(resp.text)
            print("-----------------------")
        parser = FormParser()
        parser.feed(resp.text)
        if not parser.forms:
            raise CheckError("画面にフォームが見つかりません。--show-html で HTML を確認してください。" + resp.text[:500])

        form = parser.forms[0]
        data = {}
        for field in form["fields"]:
            name = field["name"]
            if not name:
                continue
            if field["type"] == "password":
                data[name] = cfg["password"]
            elif field["type"] in ("text", "email"):
                data[name] = cfg["username"] if not field["value"] else field["value"]
            elif field["type"] in ("checkbox", "radio"):
                data[name] = field["value"] or "on"
            elif field["type"] in ("submit", "image", "button", "reset"):
                continue
            else:
                data[name] = field["value"]
        submit = pick_submit(form["fields"])
        if submit:
            data[submit["name"]] = submit["value"]
        action = urllib.parse.urljoin(resp.url, form["action"]) if form["action"] else resp.url
        if form["method"] == "post":
            resp = session.post(action, data=data, allow_redirects=False)
        else:
            resp = session.get(action, params=data, allow_redirects=False)

    raise CheckError("認可コードを受け取れませんでした（画面の遷移が想定より多い）")


def exchange_token(session, cfg, meta, code, verifier):
    """認可コードと code_verifier をトークンに交換する（public クライアントなので秘密鍵は送らない）"""
    resp = session.post(meta["token_endpoint"], data={
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": cfg["redirectUri"],
        "client_id": cfg["clientId"],
        "code_verifier": verifier,
    })
    if resp.status_code != 200:
        raise CheckError(f"トークンエンドポイントが HTTP {resp.status_code} を返しました: {resp.text[:800]}")
    return resp.json()


def get_token(cfg, meta, scope=None, aud="default", extra=None, show_html=False):
    """ログインと同意からトークン交換までを行い、トークン応答（dict）を返す"""
    session, code, verifier = authorize(cfg, meta, scope, aud, extra, show_html)
    return exchange_token(session, cfg, meta, code, verifier)


def get_json(url, token):
    """GET して (HTTP ステータス, JSON または None) を返す。token が空ならトークンを付けない"""
    headers = {"Accept": "application/fhir+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    resp = requests.get(url, headers=headers, verify=CERT_FILE)
    try:
        return resp.status_code, resp.json()
    except ValueError:
        return resp.status_code, None


def fhir_get(cfg, token, path):
    """FHIR リポジトリに GET する。(HTTP ステータス, JSON または None) を返す"""
    return get_json(cfg["fhirBaseUrl"] + "/" + path, token)


def search_all(cfg, token, path, max_pages=50):
    """next のリンクをたどって、検索結果をすべて取得する。

    戻り値: {"status", "body"（エラー時の応答）, "resources", "count", "categories", "pages"}
    """
    url = cfg["fhirBaseUrl"] + "/" + path
    resources = []
    pages = 0
    while url and pages < max_pages:
        status, body = get_json(url, token)
        if status != 200:
            return {"status": status, "body": body, "resources": resources,
                    "count": None, "categories": {}, "pages": pages}
        pages += 1
        resources += [e["resource"] for e in body.get("entry", []) if "resource" in e]
        url = next((link["url"] for link in body.get("link", []) if link.get("relation") == "next"), None)
    return {"status": 200, "body": None, "resources": resources, "count": len(resources),
            "categories": count_categories(resources), "pages": pages}


def count_categories(resources):
    """Observation のカテゴリごとの件数を数える"""
    categories = {}
    for res in resources:
        if res.get("resourceType") != "Observation":
            continue
        for cat in res.get("category", []):
            for coding in cat.get("coding", []):
                code = coding.get("code", "?")
                categories[code] = categories.get(code, 0) + 1
    return categories


def outcome_text(body):
    """OperationOutcome のメッセージを 1 行にまとめる"""
    if not body or body.get("resourceType") != "OperationOutcome":
        return ""
    return "; ".join(
        i.get("diagnostics") or i.get("details", {}).get("text") or i.get("code", "") for i in body.get("issue", []))
