"""分析アプリをヘッドレスの Chromium で操作し、スコープごとの表示を確かめる（任意のテスト）。

Playwright の公式イメージの中で動かす。使い方は tools/browser-test/run.sh を参照。
スクリーンショットは tools/browser-test/screenshots/ に保存する。
"""
import json
import os
import sys

from playwright.sync_api import sync_playwright

ROOT = "/work"
APP_ROOT = "https://localhost:8443/app/"
APP_URL = APP_ROOT + "index.html"
SHOTS = os.path.join(ROOT, "tools", "browser-test", "screenshots")

with open(os.path.join(ROOT, "shared", "demo-config.json"), encoding="utf-8") as f:
    CFG = json.load(f)

results = []


def record(name, ok, detail):
    results.append(ok)
    print(f"[{'OK' if ok else 'NG'}] {name}: {detail}", flush=True)


def login(page, preset, patient_id=None):
    """プリセットを選んでログインし、同意してアプリに戻る"""
    page.goto(APP_URL)
    page.wait_for_selector(f"#preset-{preset}")
    page.check(f"#preset-{preset}")
    if patient_id:
        page.fill("#patient-id", patient_id)
    page.click("#login")
    page.wait_for_load_state("domcontentloaded")
    # 登録していないスコープのときは、ログイン画面を出さずにアプリへ戻される
    if page.url.startswith(APP_ROOT):
        page.wait_for_load_state("networkidle")
        return
    page.wait_for_selector("#Username")
    page.fill("#Username", CFG["username"])
    page.fill("#Password", CFG["password"])
    page.click("#btnLogin")
    page.wait_for_selector("#btnAccept")
    page.click("#btnAccept")
    page.wait_for_url("**/app/index.html")
    page.wait_for_selector("body[data-logged-in='true']")


def aggregate(page):
    """検索条件なしで Observation を集計して、カテゴリごとの件数と患者ごとの件数を返す"""
    page.select_option("#category", "")
    page.click("#search-observation")
    # 件数とカテゴリは③の欄、患者ごとの件数は下段の右に表示される
    page.wait_for_selector("#result-summary .summary, #result-summary .result-error", timeout=60000)
    cats = {}
    for row in page.query_selector_all("#result-summary .bar-row"):
        label = row.query_selector(".bar-label").inner_text()
        value = int(row.query_selector(".bar-value").inner_text().replace(",", ""))
        cats[label] = value
    patients = [r.inner_text() for r in page.query_selector_all("#result-patients tbody tr td:first-child code")]
    summary = (page.inner_text("#result-summary .summary") if page.query_selector("#result-summary .summary")
               else page.inner_text("#result-summary"))
    return cats, patients, summary


def main():
    os.makedirs(SHOTS, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        # 自己署名証明書を受け入れる（このテスト用のブラウザだけ）
        context = browser.new_context(ignore_https_errors=True, locale="ja-JP", viewport={"width": 1280, "height": 900})
        page = context.new_page()
        console_errors = []
        page.on("console", lambda m: console_errors.append(m.text) if m.type == "error" else None)

        # 1. README に書いた URL（/app/）で画面が開き、smart-configuration から認可サーバの情報を取れる
        response = page.goto(APP_ROOT)
        record("/app/ から開く", response is not None and response.ok and page.url == APP_URL,
               f"HTTP {response.status if response else '?'} → {page.url}")
        page.wait_for_function("document.querySelector('#discovery').textContent.includes('authorization_endpoint')")
        # 隠れているタブでも読めるよう、inner_text ではなく text_content で読む
        discovery = json.loads(page.text_content("#discovery"))
        record("smart-configuration の取得", "S256" in discovery.get("code_challenge_methods_supported", []),
               f"capabilities={discovery.get('capabilities')}")
        page.screenshot(path=os.path.join(SHOTS, "01-start.png"), full_page=True)

        # 2. 検査結果だけ
        login(page, "lab")
        granted = page.inner_text("#granted-scope")
        user = page.inner_text("#user")
        record("検査結果だけ: トークン", "user/Observation.rs?category=laboratory" in granted and "Practitioner/pr-001" in user,
               f"granted={granted.split()}, user={user}")
        cats, patients, summary = aggregate(page)
        record("検査結果だけ: 集計", set(cats) == {"laboratory"}, f"{cats} / {summary}")
        lab_total = cats.get("laboratory", 0)
        page.screenshot(path=os.path.join(SHOTS, "02-lab-only.png"), full_page=True)

        # 3. すべての観察データ
        login(page, "all")
        cats, patients, summary = aggregate(page)
        record("すべての観察データ: 集計", len(cats) > 1 and cats.get("laboratory") == lab_total,
               f"{cats} / {summary}")
        page.screenshot(path=os.path.join(SHOTS, "03-all.png"), full_page=True)
        target_patient = next((x for x in patients if x.startswith("Patient/")), None)

        # 4. 検査とバイタル（細粒度スコープを 2 つ）
        login(page, "lab-vital")
        cats, _, summary = aggregate(page)
        record("検査とバイタル: 集計", set(cats) == {"laboratory", "vital-signs"}, f"{cats} / {summary}")

        # 5. 患者情報だけ（Observation の許可なし）
        login(page, "patient-only")
        cats, _, summary = aggregate(page)
        record("患者情報だけ: Observation は 0 件", cats == {} and "0 件" in summary, summary)
        page.click("#search-patient")
        page.wait_for_function("document.querySelector('#result-summary h3')?.textContent.includes('GET Patient')")
        summary = page.inner_text("#result-summary .summary")
        record("患者情報だけ: Patient", not summary.startswith("0 件"), summary)
        page.screenshot(path=os.path.join(SHOTS, "04-patient-only.png"), full_page=True)

        # 6. 1 人の患者の検査結果（患者コンテキスト）
        if target_patient:
            pid = target_patient.split("/", 1)[1]
            login(page, "one-patient", pid)
            context_text = page.inner_text("#patient-context")
            cats, patients, summary = aggregate(page)
            record("1 人の患者の検査結果", patients == [target_patient] and set(cats) <= {"laboratory"},
                   f"context={context_text}, patients={patients}, {cats}")
            page.screenshot(path=os.path.join(SHOTS, "05-one-patient.png"), full_page=True)
        else:
            record("1 人の患者の検査結果", False, "患者 ID を取得できませんでした")

        # 7. 登録していないスコープ
        login(page, "unregistered")
        page.wait_for_selector("#notice:not([hidden])")
        notice = page.inner_text("#notice")
        record("登録していないスコープ", "invalid_scope" in notice, notice)
        page.screenshot(path=os.path.join(SHOTS, "06-unregistered.png"), full_page=True)

        record("ブラウザのコンソールエラー", not console_errors, console_errors or "なし")
        browser.close()

    ok = sum(results)
    print(f"\n{ok} / {len(results)} 件が期待どおりでした。")
    sys.exit(0 if ok == len(results) else 1)


if __name__ == "__main__":
    main()
