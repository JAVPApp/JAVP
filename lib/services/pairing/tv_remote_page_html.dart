import 'dart:convert';

import 'package:javp/services/pairing/tv_remote_ui_strings.dart';

String htmlEscape(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

/// Session-expired page shown when the QR token is stale.
String buildTvRemoteExpiredHtml(TvRemoteUiStrings s) {
  final title = htmlEscape(s.sessionExpiredTitle);
  final body = htmlEscape(s.sessionExpiredBody);
  return _shell(
    localeTag: s.localeTag,
    title: title,
    body:
        '''
<div class="card">
  <p class="brand">JAVP</p>
  <h1>$title</h1>
  <p class="lede">$body</p>
</div>
''',
  );
}

/// Main phone remote form (Search / Channel / Paste URL).
String buildTvRemoteFormHtml(TvRemoteUiStrings s) {
  final title = htmlEscape(s.title);
  final subtitle = htmlEscape(s.subtitle);
  final tabSearch = htmlEscape(s.tabSearch);
  final tabChannel = htmlEscape(s.tabChannel);
  final tabPaste = htmlEscape(s.tabPaste);
  final searchLabel = htmlEscape(s.searchLabel);
  final searchHelp = htmlEscape(s.searchHelp);
  final searchHint = htmlEscape(s.searchHint);
  final searchSend = htmlEscape(s.searchSend);
  final channelLabel = htmlEscape(s.channelLabel);
  final channelHelp = htmlEscape(s.channelHelp);
  final channelHint = htmlEscape(s.channelHint);
  final channelSend = htmlEscape(s.channelSend);
  final pasteLabel = htmlEscape(s.pasteLabel);
  final pasteHelp = htmlEscape(s.pasteHelp);
  final pasteHint = htmlEscape(s.pasteHint);
  final pasteSend = htmlEscape(s.pasteSend);
  final stringsJson = jsonEncode(s.toJsMap());

  return _shell(
    localeTag: s.localeTag,
    title: title,
    body:
        '''
<div class="card">
  <p class="brand">JAVP</p>
  <h1>$title</h1>
  <p class="lede">$subtitle</p>
  <div class="tabs" role="tablist">
    <button type="button" class="tab on" role="tab" aria-selected="true" data-tab="search">$tabSearch</button>
    <button type="button" class="tab" role="tab" aria-selected="false" data-tab="channel">$tabChannel</button>
    <button type="button" class="tab" role="tab" aria-selected="false" data-tab="paste">$tabPaste</button>
  </div>
  <div class="panel on" id="panel-search" role="tabpanel">
    <p class="help">$searchHelp</p>
    <label for="search">$searchLabel</label>
    <input id="search" autocomplete="off" autofocus placeholder="$searchHint"/>
    <button type="button" class="primary" id="sendSearch">$searchSend</button>
  </div>
  <div class="panel" id="panel-channel" role="tabpanel">
    <p class="help">$channelHelp</p>
    <label for="channel">$channelLabel</label>
    <input id="channel" inputmode="numeric" pattern="[0-9]*" placeholder="$channelHint"/>
    <button type="button" class="primary" id="sendChannel">$channelSend</button>
  </div>
  <div class="panel" id="panel-paste" role="tabpanel">
    <p class="help">$pasteHelp</p>
    <label for="paste">$pasteLabel</label>
    <textarea id="paste" placeholder="$pasteHint"></textarea>
    <button type="button" class="primary" id="sendPaste">$pasteSend</button>
  </div>
  <div id="status" class="status" hidden></div>
  <div id="last" class="last" hidden></div>
</div>
<script>
const S = $stringsJson;
const token = new URLSearchParams(location.search).get('t') || '';
const statusEl = document.getElementById('status');
const lastEl = document.getElementById('last');

function setStatus(kind, text) {
  statusEl.hidden = !text;
  statusEl.className = 'status' + (kind ? ' ' + kind : '');
  statusEl.textContent = text || '';
}

function setLast(value) {
  if (!value) { lastEl.hidden = true; lastEl.textContent = ''; return; }
  lastEl.hidden = false;
  lastEl.textContent = S.lastSentPrefix + ': ' + value;
}

document.querySelectorAll('.tab').forEach(tab => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(t => {
      t.classList.remove('on');
      t.setAttribute('aria-selected', 'false');
    });
    document.querySelectorAll('.panel').forEach(p => p.classList.remove('on'));
    tab.classList.add('on');
    tab.setAttribute('aria-selected', 'true');
    document.getElementById('panel-' + tab.dataset.tab).classList.add('on');
    setStatus('', '');
  });
});

function localizeError(data, fallback) {
  if (data && data.code && S[data.code]) return S[data.code];
  if (data && data.error) return String(data.error);
  return fallback || S.errorFailed;
}

async function postRemote(kind, value) {
  setStatus('', S.sending);
  const res = await fetch('/api/remote', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token, kind, value }),
  });
  let data = {};
  try { data = await res.json(); } catch (_) {}
  if (!res.ok || !data.ok) throw new Error(localizeError(data, S.errorFailed));
  setStatus('ok', S.sent);
  setLast(value.trim());
}

document.getElementById('sendSearch').addEventListener('click', async () => {
  try { await postRemote('search', document.getElementById('search').value); }
  catch (err) { setStatus('err', String(err.message || err)); }
});
document.getElementById('search').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') document.getElementById('sendSearch').click();
});
document.getElementById('sendChannel').addEventListener('click', async () => {
  try { await postRemote('channel', document.getElementById('channel').value); }
  catch (err) { setStatus('err', String(err.message || err)); }
});
document.getElementById('channel').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') document.getElementById('sendChannel').click();
});
document.getElementById('sendPaste').addEventListener('click', async () => {
  try { await postRemote('paste', document.getElementById('paste').value); }
  catch (err) { setStatus('err', String(err.message || err)); }
});
</script>
''',
  );
}

String _shell({
  required String localeTag,
  required String title,
  required String body,
}) {
  final lang = htmlEscape(localeTag);
  return '''
<!DOCTYPE html>
<html lang="$lang">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"/>
<meta name="color-scheme" content="dark"/>
<meta name="theme-color" content="#0B0C0F"/>
<title>$title · JAVP</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0B0C0F;
    --bg-deep: #08090C;
    --card: #14161C;
    --surface-high: #1C1F28;
    --border: #2A2F3A;
    --accent: #E11D48;
    --accent-hi: #F43F5E;
    --accent-soft: rgba(225, 29, 72, 0.20);
    --text: #F4F5F7;
    --muted: #9AA3B2;
    --dim: #6C7484;
    --ok: #22C55E;
    --err: #F87171;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100dvh;
    font-family: "Segoe UI", system-ui, -apple-system, sans-serif;
    color: var(--text);
    background:
      radial-gradient(1200px 600px at 10% -10%, rgba(225, 29, 72, 0.18), transparent 55%),
      radial-gradient(900px 500px at 100% 0%, rgba(35, 39, 52, 0.9), transparent 50%),
      linear-gradient(180deg, var(--bg) 0%, var(--bg-deep) 100%);
    padding: 28px 20px 40px;
  }
  .card {
    background: linear-gradient(180deg, rgba(28, 31, 40, 0.92), rgba(20, 22, 28, 0.96));
    border: 1px solid var(--border);
    border-radius: 18px;
    padding: 24px 22px 22px;
    max-width: 440px;
    margin: 0 auto;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45);
  }
  .brand {
    margin: 0 0 10px;
    color: var(--accent-hi);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.22em;
    text-transform: uppercase;
  }
  h1 {
    font-size: 1.55rem;
    line-height: 1.15;
    letter-spacing: -0.03em;
    margin: 0 0 8px;
    font-weight: 700;
  }
  .lede, .help, p { color: var(--muted); margin: 0; line-height: 1.45; }
  .lede { margin-bottom: 18px; }
  .help { font-size: 0.92rem; margin: 4px 0 14px; }
  .tabs {
    display: flex;
    gap: 8px;
    margin: 0 0 18px;
    padding: 4px;
    border-radius: 14px;
    background: rgba(8, 9, 12, 0.55);
    border: 1px solid var(--border);
  }
  .tab {
    flex: 1;
    min-height: 44px;
    padding: 10px 8px;
    border-radius: 11px;
    border: 0;
    background: transparent;
    color: var(--muted);
    font-size: 13px;
    font-weight: 700;
  }
  .tab.on {
    color: #fff;
    background: var(--accent-soft);
    box-shadow: inset 0 0 0 1px rgba(225, 29, 72, 0.55);
  }
  .panel { display: none; }
  .panel.on { display: block; }
  label {
    display: block;
    font-size: 0.82rem;
    font-weight: 600;
    margin: 0 0 8px;
    color: var(--dim);
    letter-spacing: 0.02em;
    text-transform: uppercase;
  }
  input, textarea {
    width: 100%;
    padding: 14px 16px;
    border-radius: 12px;
    border: 1px solid var(--border);
    background: var(--surface-high);
    color: var(--text);
    font-size: 16px;
  }
  input:focus, textarea:focus {
    outline: none;
    border-color: var(--accent);
    box-shadow: 0 0 0 3px var(--accent-soft);
  }
  textarea { min-height: 96px; resize: vertical; }
  .primary {
    width: 100%;
    margin-top: 14px;
    min-height: 52px;
    padding: 14px 16px;
    border: 0;
    border-radius: 12px;
    background: linear-gradient(180deg, var(--accent-hi), var(--accent));
    color: #fff;
    font-weight: 750;
    font-size: 16px;
  }
  .primary:active { filter: brightness(0.95); }
  .status {
    margin-top: 16px;
    padding: 12px 14px;
    border-radius: 12px;
    font-weight: 650;
    font-size: 0.95rem;
    background: rgba(28, 31, 40, 0.9);
    border: 1px solid var(--border);
  }
  .status.ok {
    color: var(--ok);
    border-color: rgba(34, 197, 94, 0.35);
    background: rgba(34, 197, 94, 0.08);
  }
  .status.err {
    color: var(--err);
    border-color: rgba(248, 113, 113, 0.35);
    background: rgba(248, 113, 113, 0.08);
  }
  .last {
    margin-top: 10px;
    padding: 10px 12px;
    border-radius: 999px;
    font-size: 0.85rem;
    color: var(--muted);
    background: rgba(8, 9, 12, 0.55);
    border: 1px solid var(--border);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
</head>
<body>
$body
</body>
</html>
''';
}
