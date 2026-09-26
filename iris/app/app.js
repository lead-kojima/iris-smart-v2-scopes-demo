// SMART v2 スコープ 分析アプリ
// ブラウザだけで動く public クライアント。認可コードフロー + PKCE でアクセストークンを受け取り、
// FHIR リポジトリを検索して集計する。ライブラリは使わない。

// スコープの組み合わせ。openid と fhirUser は、ログインした利用者を ID トークンで受け取るために付ける
const PRESETS = [
  { id: 'lab', label: '検査結果だけ', scope: 'openid fhirUser user/Observation.rs?category=laboratory',
    note: '細粒度スコープ。検査カテゴリの Observation だけを読める' },
  { id: 'vital', label: 'バイタルだけ', scope: 'openid fhirUser user/Observation.rs?category=vital-signs',
    note: '細粒度スコープ。バイタルサインだけを読める' },
  { id: 'lab-vital', label: '検査とバイタル',
    scope: 'openid fhirUser user/Observation.rs?category=laboratory user/Observation.rs?category=vital-signs',
    note: '細粒度スコープを 2 つ。どちらかに当てはまるものを読める' },
  { id: 'survey', label: '問診票だけ', scope: 'openid fhirUser user/Observation.rs?category=survey',
    note: '細粒度スコープ。問診票（PHQ-2 など）だけを読める' },
  { id: 'all', label: 'すべての観察データ', scope: 'openid fhirUser user/Observation.rs',
    note: '条件なし。Observation をすべて読める' },
  { id: 'patient-only', label: '患者情報だけ', scope: 'openid fhirUser user/Patient.rs',
    note: 'Observation の許可がないので、Observation の検索は 0 件になる' },
  { id: 'one-patient', label: '1 人の患者の検査結果',
    scope: 'openid fhirUser launch/patient patient/Observation.rs?category=laboratory',
    note: '患者コンテキスト付き。指定した患者の検査結果だけを読める' },
  { id: 'unregistered', label: '登録していないスコープ', scope: 'openid fhirUser user/Observation.rs?category=social-history',
    note: '認可サーバに登録していないので、invalid_scope で拒否される' },
];

// 検索結果をたどるページ数の上限（1 ページ 100 件）
const MAX_PAGES = 20;

// sessionStorage は使えない環境（プライベートウィンドウの設定など）もあるので、失敗しても止めない
const store = {
  get(key) {
    try { return JSON.parse(sessionStorage.getItem(key)); } catch { return null; }
  },
  set(key, value) {
    try { sessionStorage.setItem(key, JSON.stringify(value)); } catch { /* 保存できなくても続ける */ }
  },
  remove(key) {
    try { sessionStorage.removeItem(key); } catch { /* 何もしない */ }
  },
};

// ---------- 設定と認可サーバの情報 ----------

async function fetchJson(url) {
  const res = await fetch(url, { headers: { Accept: 'application/json' }, cache: 'no-store' });
  if (!res.ok) throw new Error(`${url} を取得できませんでした（HTTP ${res.status}）`);
  return res.json();
}

// config.json は IRIS が起動後に書き出す（FHIR のベース URL、クライアント ID、リダイレクト URI）。
// 認可サーバのエンドポイントは、FHIR の smart-configuration から取得する
async function loadSettings() {
  const cfg = await fetchJson('config.json');
  const smart = await fetchJson(`${cfg.fhirBaseUrl}/.well-known/smart-configuration`);
  return { cfg, smart };
}

// ---------- PKCE と JWT ----------

function base64url(bytes) {
  let text = '';
  for (const b of new Uint8Array(bytes)) text += String.fromCharCode(b);
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomString(byteLength) {
  return base64url(crypto.getRandomValues(new Uint8Array(byteLength)));
}

// code_challenge = BASE64URL(SHA-256(code_verifier))
async function codeChallenge(verifier) {
  return base64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
}

// 空白は %20 にする。細粒度スコープの ? と = もここでエンコードされる
function toQuery(params) {
  return Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');
}

// JWT のヘッダーとペイロードを読む。署名の検証は FHIR リポジトリ側が行うので、ここでは表示だけに使う
function decodeJwt(token) {
  const parts = (token || '').split('.');
  if (parts.length !== 3) return null;
  const decode = (part) => {
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (part.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  };
  try {
    return { header: decode(parts[0]), payload: decode(parts[1]) };
  } catch {
    return null;
  }
}

// ---------- ログインとトークンの受け取り ----------

async function login(settings, scope, patientId) {
  const verifier = randomString(48);
  const state = randomString(16);
  const nonce = randomString(16);
  store.set('pending', { verifier, state, nonce, scope, patientId: patientId || '' });

  const params = {
    response_type: 'code',
    client_id: settings.cfg.clientId,
    redirect_uri: settings.cfg.redirectUri,
    scope,
    state,
    nonce,
    // トークンの宛先。FHIR エンドポイントの URL と完全に一致させる（違うと FHIR リポジトリが 401 を返す）
    aud: settings.cfg.fhirBaseUrl,
    code_challenge: await codeChallenge(verifier),
    code_challenge_method: 'S256',
  };
  if (patientId) {
    // IRIS for Health の SMART 用クラスは、claims パラメータで渡された patient をトークンに入れる
    params.claims = JSON.stringify({ patient: patientId });
  }
  location.assign(`${settings.smart.authorization_endpoint}?${toQuery(params)}`);
}

// callback.html で動く。認可コードをトークンに交換して、index.html に戻る
async function handleCallback() {
  // IRIS はエラーをフラグメント（# 以降）で返すことがあるので、クエリと両方を見る
  const params = new URLSearchParams(location.search);
  for (const [k, v] of new URLSearchParams(location.hash.slice(1))) {
    if (!params.has(k)) params.set(k, v);
  }
  const pending = store.get('pending');
  store.remove('pending');

  try {
    if (params.get('error')) {
      throw new Error(`認可サーバがエラーを返しました: ${params.get('error')} ${params.get('error_description') || ''}`);
    }
    if (!pending || params.get('state') !== pending.state) {
      throw new Error('state が一致しません。もう一度ログインしてください。');
    }
    const code = params.get('code');
    if (!code) throw new Error('認可コードがありません。');

    const settings = await loadSettings();
    // public クライアントなので秘密鍵は送らない。代わりに code_verifier で、認可リクエストを出した本人であることを示す
    const res = await fetch(settings.smart.token_endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: toQuery({
        grant_type: 'authorization_code',
        code,
        redirect_uri: settings.cfg.redirectUri,
        client_id: settings.cfg.clientId,
        code_verifier: pending.verifier,
      }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(`トークンを受け取れませんでした（HTTP ${res.status}）: ${body.error || ''} ${body.error_description || ''}`);
    }
    const idToken = decodeJwt(body.id_token);
    if (idToken && idToken.payload.nonce !== pending.nonce) {
      throw new Error('ID トークンの nonce が一致しません。');
    }
    store.set('session', { token: body, requestedScope: pending.scope, patientId: pending.patientId, receivedAt: Date.now() });
    location.replace('index.html');
  } catch (e) {
    store.set('notice', { kind: 'error', text: e.message });
    location.replace('index.html');
  }
}

// ---------- FHIR の検索 ----------

async function fhirGet(url, token) {
  const res = await fetch(url, { headers: { Accept: 'application/fhir+json', Authorization: `Bearer ${token}` } });
  let body = null;
  try { body = await res.json(); } catch { /* 本文がない応答もある */ }
  return { status: res.status, body };
}

// next のリンクをたどって、すべてのページの結果を集める
async function searchAll(firstUrl, token, onProgress) {
  const resources = [];
  let url = firstUrl;
  let pages = 0;
  let total;
  while (url && pages < MAX_PAGES) {
    const r = await fhirGet(url, token);
    if (r.status !== 200) return { ...r, resources, pages };
    pages += 1;
    if (total === undefined) total = r.body.total;
    for (const entry of r.body.entry || []) {
      if (entry.resource && (entry.search?.mode || 'match') === 'match') resources.push(entry.resource);
    }
    onProgress?.(resources.length, pages);
    url = (r.body.link || []).find((l) => l.relation === 'next')?.url || null;
  }
  return { status: 200, resources, pages, total, truncated: Boolean(url) };
}

function countBy(map, key) {
  map.set(key, (map.get(key) || 0) + 1);
}

function aggregateObservations(list) {
  const byCategory = new Map();
  const byPatient = new Map();
  const byCode = new Map();
  for (const o of list) {
    const cats = (o.category || []).flatMap((c) => (c.coding || []).map((cd) => cd.code)).filter(Boolean);
    for (const c of cats.length ? cats : ['（なし）']) countBy(byCategory, c);
    countBy(byPatient, o.subject?.reference || '（なし）');

    const coding = (o.code?.coding || [])[0] || {};
    const key = `${coding.system || ''}|${coding.code || o.code?.text || '?'}`;
    let row = byCode.get(key);
    if (!row) {
      row = { code: coding.code || '', display: coding.display || o.code?.text || '', category: cats[0] || '', count: 0, values: [], unit: '' };
      byCode.set(key, row);
    }
    row.count += 1;
    if (typeof o.valueQuantity?.value === 'number') {
      row.values.push(o.valueQuantity.value);
      row.unit = o.valueQuantity.unit || o.valueQuantity.code || row.unit;
    }
  }
  const sortDesc = (m) => [...m.entries()].sort((a, b) => b[1] - a[1]);
  return {
    byCategory: sortDesc(byCategory),
    byPatient: sortDesc(byPatient),
    byCode: [...byCode.values()].sort((a, b) => b.count - a.count),
  };
}

// ---------- 画面 ----------

// 要素を作る小さなヘルパー。文字列は textContent で入れるので、HTML として解釈されない
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null && v !== false) el.setAttribute(k, v === true ? '' : v);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

function $(id) {
  return document.getElementById(id);
}

function showNotice(kind, text) {
  const box = $('notice');
  box.className = `notice ${kind}`;
  box.textContent = text;
  box.hidden = false;
}

function scopeChips(scopeText, compareWith) {
  const other = new Set((compareWith || '').split(/\s+/).filter(Boolean));
  const items = (scopeText || '').split(/\s+/).filter(Boolean);
  if (!items.length) return [h('span', { class: 'muted' }, '（なし）')];
  return items.map((s) => h('code', { class: other.size && !other.has(s) ? 'chip diff' : 'chip' }, s));
}

function renderPresets(settings) {
  const box = $('presets');
  const saved = store.get('preset') || 'lab';
  for (const p of PRESETS) {
    const input = h('input', { type: 'radio', name: 'preset', value: p.id, id: `preset-${p.id}` });
    input.addEventListener('change', () => selectPreset(p.id));
    // 説明はツールチップで出す
    box.append(h('label', { class: 'preset', for: `preset-${p.id}`, title: p.note }, input, h('span', {}, p.label)));
  }
  selectPreset(PRESETS.some((p) => p.id === saved) ? saved : 'lab');
  $('scope').addEventListener('input', updatePatientField);

  $('login').addEventListener('click', async () => {
    const presetId = document.querySelector('input[name="preset"]:checked')?.value;
    const scope = $('scope').value.trim().split(/\s+/).join(' ');
    const needsPatient = usesPatientContext(scope);
    const patientId = needsPatient ? $('patient-id').value.trim() : '';
    if (needsPatient && !patientId) {
      showNotice('error', '患者コンテキストを使うスコープです。患者 ID を入力してください。');
      return;
    }
    store.set('preset', presetId);
    store.remove('session');
    await login(settings, scope, patientId);
  });
}

function selectPreset(id) {
  const preset = PRESETS.find((p) => p.id === id);
  $(`preset-${id}`).checked = true;
  $('scope').value = preset.scope;
  updatePatientField();
}

function usesPatientContext(scope) {
  return /(^|\s)patient\//.test(scope);
}

// 患者 ID は、patient/ スコープを要求するときだけ入力できるようにする
function updatePatientField() {
  $('patient-id').disabled = !usesPatientContext($('scope').value);
}

// 右上のタブ（認可サーバ情報、アクセストークン情報、ID トークン情報）。選んだタブを返す関数を返す
function initTabs() {
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    for (const t of tabs) {
      const selected = t === tab;
      t.setAttribute('aria-selected', String(selected));
      t.tabIndex = selected ? 0 : -1;
      $(t.getAttribute('aria-controls')).hidden = !selected;
    }
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', (e) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!step) return;
      const next = tabs[(i + step + tabs.length) % tabs.length];
      select(next);
      next.focus();
    });
  });
  return (id) => select($(id));
}

function renderSession(session) {
  const access = decodeJwt(session.token.access_token);
  const id = decodeJwt(session.token.id_token);
  const granted = session.token.scope || access?.payload.scope || '';

  document.body.dataset.loggedIn = 'true';
  for (const button of ['logout', 'search-observation', 'search-patient', 'search-free']) $(button).disabled = false;
  showResult([h('p', { class: 'muted' }, '検索条件を選んで、検索を実行してください。')]);
  $('requested-scope').replaceChildren(...scopeChips(session.requestedScope, granted));
  $('granted-scope').replaceChildren(...scopeChips(granted, session.requestedScope));
  const who = id?.payload.preferred_username || access?.payload.sub || '';
  const fhirUser = id?.payload.fhirUser || access?.payload.fhirUser;
  $('user').textContent = fhirUser ? `${who}（fhirUser: ${fhirUser}）` : who;
  $('patient-context').textContent = access?.payload.patient ? `Patient/${access.payload.patient}` : 'なし';
  $('access-token').textContent = access
    ? JSON.stringify({ header: access.header, payload: access.payload }, null, 2)
    : '（JWT 形式ではありません。IRIS の FHIR リポジトリは JWT 形式のトークンだけを受け付けます）';
  $('id-token').textContent = id ? JSON.stringify(id.payload, null, 2) : '（ID トークンはありません。openid スコープを要求すると受け取れます）';

  const exp = access?.payload.exp;
  const tick = () => {
    if (!exp) { $('expiry').textContent = '不明'; return false; }
    const left = exp - Math.floor(Date.now() / 1000);
    $('expiry').textContent = left > 0
      ? `あと ${Math.floor(left / 60)} 分 ${left % 60} 秒（${new Date(exp * 1000).toLocaleTimeString()} まで）`
      : '期限切れ。ログインし直してください（このトークンで検索すると 401 になります）';
    return left > 0;
  };
  if (tick()) {
    const timer = setInterval(() => { if (!tick()) clearInterval(timer); }, 1000);
  }
}

function explainStatus(status) {
  if (status === 401) return 'トークンが受け付けられませんでした。期限切れ、改ざん、aud の不一致、リソースのスコープがない、などが原因です。';
  if (status === 403) return 'このトークンのスコープでは許可されていない操作です。';
  return '';
}

function renderError(result) {
  const diag = (result.body?.issue || []).map((i) => i.diagnostics || i.details?.text || i.code).join(' / ');
  return h('div', { class: 'result-error' },
    h('p', {}, h('strong', {}, `HTTP ${result.status}`), ' ', explainStatus(result.status)),
    diag ? h('p', { class: 'muted' }, `OperationOutcome: ${diag}`) : null);
}

// 件数の棒グラフ（2 列に並べる）。rows は [名前, 件数] の配列
function bars(rows, ariaLabel) {
  const max = Math.max(1, ...rows.map(([, n]) => n));
  return h('div', { class: 'bars', 'aria-label': ariaLabel }, rows.map(([name, n]) => h('div', { class: 'bar-row' },
    h('span', { class: 'bar-label' }, name),
    h('span', { class: 'bar-track' }, h('span', { class: 'bar', style: `width:${(n / max) * 100}%` })),
    h('span', { class: 'bar-value' }, n.toLocaleString()))));
}

function stats(values) {
  if (!values.length) return '';
  const sum = values.reduce((a, b) => a + b, 0);
  const fmt = (v) => (Math.round(v * 10) / 10).toLocaleString();
  return `${fmt(Math.min(...values))} / ${fmt(sum / values.length)} / ${fmt(Math.max(...values))}`;
}

// 検索結果は 3 か所に分けて表示する。③の欄に件数とカテゴリ、下段の左に項目ごと、下段の右に患者ごと
function showResult(summary, items, patients) {
  const muted = (text) => [h('p', { class: 'muted' }, text)];
  $('result-summary').replaceChildren(...summary);
  $('result-items').replaceChildren(...(items || muted('Observation を検索すると、項目ごとの件数を表示します。')));
  $('result-patients').replaceChildren(...(patients || muted('Observation を検索すると、患者ごとの件数を表示します。')));
}

// 「GET …」と取得件数を 1 行に並べる
function summaryHead(query, ...rest) {
  return h('div', { class: 'summary-head' }, h('h3', {}, `GET ${query}`), ...rest);
}

function fetchedText(result, note) {
  return h('p', { class: 'summary' }, h('strong', {}, `${result.resources.length.toLocaleString()} 件`),
    ` を取得しました（HTTP 200、${result.pages} ページ）。`,
    result.truncated ? ' ページ数の上限に達したので、途中までの集計です。' : '', note || '');
}

// 以下の render 関数は、検索が成功（HTTP 200）したときに呼ぶ。失敗したときの表示は bindSearch で行う
function renderObservationResult(result, query) {
  if (!result.resources.length) {
    const none = [h('p', { class: 'muted' }, '0 件です。')];
    showResult([summaryHead(query,
      fetchedText(result, ' スコープに合わないデータは、エラーにならずに検索結果から除かれます。'))], none, none);
    return;
  }
  const agg = aggregateObservations(result.resources);
  showResult(
    [summaryHead(query, fetchedText(result)), bars(agg.byCategory, 'カテゴリごとの件数')],
    [h('h4', {}, '項目ごと（件数の多い順に 20 項目）'),
      h('div', { class: 'table-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'カテゴリ'), h('th', {}, 'コード'), h('th', {}, '項目'),
          h('th', { class: 'num' }, '件数'), h('th', { class: 'num' }, '最小 / 平均 / 最大'), h('th', {}, '単位'))),
        h('tbody', {}, agg.byCode.slice(0, 20).map((r) => h('tr', {},
          h('td', {}, r.category), h('td', {}, h('code', {}, r.code)), h('td', {}, r.display),
          h('td', { class: 'num' }, r.count.toLocaleString()), h('td', { class: 'num' }, stats(r.values)), h('td', {}, r.unit))))))],
    [h('h4', {}, '患者ごと'),
      h('div', { class: 'table-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, '患者'), h('th', { class: 'num' }, '件数'), h('th', {}, ''))),
        h('tbody', {}, agg.byPatient.map(([ref, n]) => h('tr', {},
          h('td', {}, h('code', {}, ref)),
          h('td', { class: 'num' }, n.toLocaleString()),
          h('td', {}, ref.startsWith('Patient/') ? h('button', {
            type: 'button', class: 'small',
            onclick: () => {
              selectPreset('one-patient');
              $('patient-id').value = ref.slice('Patient/'.length);
              $('login-panel').scrollIntoView({ behavior: 'smooth' });
              showNotice('info', `患者 ${ref} の検査結果だけを読むスコープを選びました。「ログインしてトークンを受け取る」を押してください。`);
            },
          }, 'この患者だけに絞る') : ''))))))]);
}

function patientName(p) {
  const n = (p.name || [])[0] || {};
  return n.text || [...(n.given || []), n.family].filter(Boolean).join(' ');
}

function renderPatientResult(result, query) {
  if (!result.resources.length) {
    showResult([summaryHead(query,
      fetchedText(result, ' Patient を読むスコープがないと、エラーにならずに 0 件になります。'))]);
    return;
  }
  showResult(
    [summaryHead(query, fetchedText(result))],
    [h('h4', {}, 'Patient の一覧'),
      h('div', { class: 'table-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'ID'), h('th', {}, '氏名'), h('th', {}, '性別'), h('th', {}, '生年月日'))),
        h('tbody', {}, result.resources.map((p) => h('tr', {},
          h('td', {}, h('code', {}, p.id)), h('td', {}, patientName(p)), h('td', {}, p.gender || ''), h('td', {}, p.birthDate || ''))))))]);
}

function renderGenericResult(result, query) {
  const byType = new Map();
  for (const r of result.resources) countBy(byType, r.resourceType);
  showResult([summaryHead(query, fetchedText(result)), bars([...byType.entries()], 'リソースの種類ごとの件数')]);
}

function bindSearch(settings, session) {
  const base = settings.cfg.fhirBaseUrl;
  const token = session.token.access_token;
  const progress = (n, pages) => {
    showResult([h('p', { class: 'muted' }, `取得中… ${n.toLocaleString()} 件（${pages} ページ）`)]);
  };
  // 検索して、成功したら render で表示する。失敗したら HTTP ステータスと OperationOutcome を表示する
  const run = async (query, render) => {
    progress(0, 0);
    const result = await searchAll(`${base}/${query}`, token, progress);
    if (result.status === 200) render(result, query);
    else showResult([summaryHead(query), renderError(result)]);
  };
  $('search-observation').addEventListener('click', () => {
    const category = $('category').value;
    run(`Observation?${category ? `category=${encodeURIComponent(category)}&` : ''}_count=100`, renderObservationResult);
  });
  $('search-patient').addEventListener('click', () => run('Patient?_count=100', renderPatientResult));
  $('search-free').addEventListener('click', () => {
    const query = $('free-query').value.trim().replace(/^\//, '');
    if (query) run(query, query.startsWith('Observation') ? renderObservationResult : renderGenericResult);
  });
  $('logout').addEventListener('click', () => {
    store.remove('session');
    location.replace('index.html');
  });
}

async function initIndex() {
  const selectTab = initTabs();
  const notice = store.get('notice');
  store.remove('notice');
  if (notice) showNotice(notice.kind, notice.text);

  let settings;
  try {
    settings = await loadSettings();
  } catch (e) {
    showNotice('error', `設定を読み込めませんでした。IRIS の起動後の設定が終わっているか確認してください。${e.message}`);
    return;
  }
  $('discovery').textContent = JSON.stringify(settings.smart, null, 2);
  renderPresets(settings);

  const session = store.get('session');
  if (session?.patientId) $('patient-id').value = session.patientId;
  if (session?.token?.access_token) {
    renderSession(session);
    bindSearch(settings, session);
    // ログインしたら、受け取ったアクセストークンを見せる
    selectTab('tab-access-token');
  }
}

if (document.body.dataset.page === 'callback') {
  handleCallback();
} else {
  initIndex();
}
