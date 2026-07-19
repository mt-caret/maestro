open! Core

let html =
  {html|<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Maestro</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; margin: 0; padding: 1.5rem; }
  h1 { font-size: 1.1rem; margin: 0 0 1rem; }
  .totals { display: flex; gap: 1.5rem; flex-wrap: wrap; margin-bottom: 1rem; opacity: 0.85; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; }
  caption { text-align: left; font-weight: bold; padding: 0.25rem 0; }
  th, td { text-align: left; padding: 0.25rem 0.75rem 0.25rem 0; white-space: nowrap; }
  th { opacity: 0.6; font-weight: normal; }
  tr:not(:last-child) td { border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent); }
  .muted { opacity: 0.55; }
  .err { color: #c0392b; }
</style>
</head>
<body>
<h1>Maestro <span id="clock" class="muted"></span></h1>
<div class="totals" id="totals"></div>
<div id="tables"></div>
<script>
const fmt = n => (n ?? 0).toLocaleString();
const cell = v => { const td = document.createElement('td'); td.textContent = v ?? ''; return td; };
function table(caption, columns, rows) {
  const t = document.createElement('table');
  const cap = document.createElement('caption'); cap.textContent = `${caption} (${rows.length})`; t.appendChild(cap);
  const head = document.createElement('tr');
  columns.forEach(c => { const th = document.createElement('th'); th.textContent = c.label; head.appendChild(th); });
  t.appendChild(head);
  if (rows.length === 0) { const tr = document.createElement('tr'); const td = cell('none'); td.className = 'muted'; td.colSpan = columns.length; tr.appendChild(td); t.appendChild(tr); }
  rows.forEach(r => { const tr = document.createElement('tr'); columns.forEach(c => tr.appendChild(cell(c.get(r)))); t.appendChild(tr); });
  return t;
}
async function refresh() {
  let s;
  try { s = await (await fetch('/api/v1/state')).json(); }
  catch (e) { document.getElementById('clock').textContent = '(unreachable)'; return; }
  document.getElementById('clock').textContent = s.generated_at ?? '';
  if (s.error) { document.getElementById('totals').innerHTML = `<span class="err">${s.error.message}</span>`; return; }
  const ct = s.codex_totals ?? {};
  document.getElementById('totals').innerHTML =
    `<span>agents ${s.counts.running}</span><span>retrying ${s.counts.retrying}</span>` +
    `<span>blocked ${s.counts.blocked}</span><span>tokens in ${fmt(ct.input_tokens)} / out ${fmt(ct.output_tokens)}</span>` +
    `<span>runtime ${Math.round(ct.seconds_running ?? 0)}s</span>`;
  const tables = document.getElementById('tables');
  tables.replaceChildren(
    table('Running', [
      {label:'ID', get:r=>r.issue_identifier}, {label:'STATE', get:r=>r.state},
      {label:'TURN', get:r=>r.turn_count}, {label:'TOKENS', get:r=>fmt(r.tokens?.total_tokens)},
      {label:'SESSION', get:r=>r.session_id ?? ''}, {label:'EVENT', get:r=>r.last_message ?? ''}], s.running),
    table('Backoff queue', [
      {label:'ID', get:r=>r.issue_identifier}, {label:'ATTEMPT', get:r=>r.attempt},
      {label:'IN', get:r=>`${Math.round((r.due_in_ms ?? 0)/1000)}s`}, {label:'ERROR', get:r=>r.error ?? ''}], s.retrying),
    table('Blocked', [
      {label:'ID', get:r=>r.issue_identifier}, {label:'STATE', get:r=>r.state ?? ''},
      {label:'ERROR', get:r=>r.error ?? ''}], s.blocked));
}
refresh();
setInterval(refresh, 1000);
</script>
</body>
</html>
|html}
;;
