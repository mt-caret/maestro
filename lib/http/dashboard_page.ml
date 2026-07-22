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
  body { font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; margin: 0; }
  main { padding: 1.5rem; }
  h1 { font-size: 1.2rem; margin: 0; }
  h2 { font-size: 1rem; margin: 1.25rem 0 .25rem; }
  header p { margin: .2rem 0; }
  .muted { opacity: .55; }
  .error { color: #c0392b; }
  .totals { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-top: .75rem; opacity: .8; }
  .layout { display: grid; grid-template-columns: minmax(0, 2fr) minmax(18rem, 1fr); gap: 2rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent); padding: .3rem .75rem .3rem 0; text-align: left; }
  th { opacity: .6; font-weight: normal; }
  button.issue { border: 0; background: none; color: inherit; cursor: pointer; font: inherit; padding: 0; }
  aside { border-left: 1px solid color-mix(in srgb, currentColor 18%, transparent); padding-left: 1.5rem; }
  dl div { display: grid; grid-template-columns: 6rem minmax(0, 1fr); gap: .5rem; margin: .4rem 0; }
  dt { opacity: .6; }
  dd { margin: 0; overflow-wrap: anywhere; }
  @media (max-width: 760px) { .layout { grid-template-columns: 1fr; } aside { border-left: 0; padding-left: 0; } }
</style>
</head>
<body>
<div id="app"></div>
<script src="/assets/dashboard.js"></script>
</body>
</html>
|html}
;;

let javascript_gzip = Dashboard_bundle.web_app_dot_bc_dot_js_dot_gz
