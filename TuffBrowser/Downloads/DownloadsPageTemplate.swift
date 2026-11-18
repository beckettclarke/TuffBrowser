import Foundation

/// The HTML, CSS and script of tuff://downloads. It draws from `dl.state` once a second and
/// sends every action back as a `dl.*` message (see `DownloadsPage`).
enum DownloadsPageTemplate {
    static let html = #"""
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Downloads</title>
<style>
  :root {
    color-scheme: light dark;
    --accent: __ACCENT__;
    --fg: #1d1d1f; --dim: rgba(0,0,0,.55); --faint: rgba(0,0,0,.36);
    --bg: #f6f5f3; --side: #efeeeb; --plate: rgba(0,0,0,.03); --hover: rgba(0,0,0,.05); --line: rgba(0,0,0,.075);
    --field: rgba(0,0,0,.055); --sel: color-mix(in srgb, var(--accent) 18%, transparent);
    --card: #fff; --shade: rgba(0,0,0,.28);
    --ok: #2f9e44; --warn: #d9822b; --danger: #d93d42; --seed: #1c7ed6;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --fg: #f2f2f4; --dim: rgba(255,255,255,.58); --faint: rgba(255,255,255,.34);
      --bg: #1b1b1e; --side: #161619; --plate: rgba(255,255,255,.035); --hover: rgba(255,255,255,.06); --line: rgba(255,255,255,.08);
      --field: rgba(255,255,255,.07); --sel: color-mix(in srgb, var(--accent) 28%, transparent);
      --card: #26262a; --shade: rgba(0,0,0,.55);
      --ok: #51cf66; --warn: #ffa94d; --danger: #ff6369; --seed: #4dabf7;
    }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  html { background: var(--bg); }
  body { margin: 0; font: 13px -apple-system, system-ui, sans-serif; color: var(--fg); -webkit-font-smoothing: antialiased; overflow: hidden; }
  button { font: inherit; color: inherit; border: 0; background: none; cursor: default; }
  input, select, textarea { font: inherit; color: inherit; }
  svg { flex: none; }
  .app { display: grid; grid-template-columns: 236px minmax(0, 1fr); height: 100vh; }

  /* Sidebar */
  aside { background: var(--side); border-right: .5px solid var(--line); padding: 22px 12px 12px; display: flex; flex-direction: column; gap: 1px; overflow-y: auto; }
  aside::-webkit-scrollbar { width: 0; }
  .brand { display: flex; align-items: center; gap: 9px; font: 650 17px ui-rounded, -apple-system, system-ui; padding: 0 10px 14px; }
  .brand .mark { width: 28px; height: 28px; border-radius: 8px; display: grid; place-items: center; background: var(--sel); color: var(--accent); }
  aside h3 { font: 600 10.5px -apple-system, system-ui; letter-spacing: .04em; text-transform: uppercase; color: var(--faint); margin: 14px 10px 4px; }
  .item { display: flex; align-items: center; gap: 9px; width: 100%; height: 29px; padding: 0 10px; border-radius: 8px; text-align: left; font-weight: 500; transition: background .12s; }
  .item:hover { background: var(--hover); }
  .item.sel { background: var(--sel); }
  .item .ic { width: 16px; display: grid; place-items: center; color: var(--dim); }
  .item.sel .ic { color: var(--accent); }
  .item .label { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .item .n { color: var(--faint); font-size: 11.5px; font-variant-numeric: tabular-nums; }
  .spacer { flex: 1; min-height: 12px; }
  .stats { padding: 8px 10px 2px; display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 3px 10px; font-size: 11.5px; color: var(--dim); font-variant-numeric: tabular-nums; }
  .stats span, .stats b { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .stats b { font-weight: 600; color: var(--fg); text-align: right; }
  .foot-side { border-top: .5px solid var(--line); margin-top: 6px; padding-top: 6px; }
  .toggle-row { display: flex; align-items: center; gap: 9px; width: 100%; height: 30px; padding: 0 10px; border-radius: 8px; font-weight: 500; text-align: left; }
  .toggle-row:hover { background: var(--hover); }
  .toggle-row[hidden] { display: none; }
  .toggle-row .ic { width: 16px; display: grid; place-items: center; color: var(--dim); }
  .toggle-row .label { flex: 1; }
  .toggle-row small { color: var(--faint); font-size: 11px; font-weight: 500; }
  .tick { width: 15px; height: 15px; border-radius: 4px; background: var(--field); border: .5px solid var(--line); display: grid; place-items: center; color: #fff; flex: none; }
  .tick.on { background: var(--accent); border-color: transparent; }
  .item[hidden] { display: none; }

  /* Main */
  main { display: flex; flex-direction: column; min-width: 0; height: 100vh; }
  header { display: flex; align-items: center; gap: 10px; padding: 22px 26px 10px; }
  h1 { font: 650 23px ui-rounded, -apple-system, system-ui; margin: 0; white-space: nowrap; }
  .count { color: var(--faint); font-size: 12.5px; padding-top: 5px; white-space: nowrap; }
  .speeds { margin-left: auto; display: flex; gap: 12px; color: var(--dim); font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .speeds span { display: inline-flex; align-items: center; gap: 4px; }
  .pill { font-weight: 600; font-size: 12px; height: 28px; padding: 0 11px; border-radius: 8px; background: var(--field); display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; transition: background .12s, transform .12s; }
  .pill:hover { background: var(--hover); }
  .pill:active { transform: scale(.96); }
  .pill.primary { background: var(--accent); color: #fff; }
  .pill.danger { color: var(--danger); }
  .pill:disabled { opacity: .45; }
  kbd { font: 600 10.5px -apple-system, system-ui; border-radius: 4px; padding: 1px 5px; background: rgba(255,255,255,.22); }
  .pill:not(.primary) kbd { background: var(--field); color: var(--dim); }
  .toolbar { display: flex; align-items: center; gap: 8px; padding: 0 26px 12px; }
  .search { flex: 1; display: flex; align-items: center; gap: 8px; height: 32px; padding: 0 11px; border-radius: 10px; background: var(--field); outline: 2px solid transparent; transition: outline-color .12s; }
  .search:focus-within { outline-color: color-mix(in srgb, var(--accent) 70%, transparent); }
  .search input { flex: 1; border: 0; outline: 0; background: none; font-weight: 500; }
  .search kbd { background: none; border: 1px solid var(--line); color: var(--faint); }
  select.sort { height: 28px; border-radius: 8px; border: 0; background: var(--field); padding: 0 8px; font-weight: 600; font-size: 12px; }

  .list { flex: 1; overflow-y: auto; padding: 0 18px 18px; }
  .row { display: grid; grid-template-columns: 34px minmax(0, 1fr) auto; align-items: center; gap: 12px; padding: 9px 10px; border-radius: 11px; margin-bottom: 2px; }
  .row:hover { background: var(--hover); }
  .row.sel { background: var(--sel); }
  .glyph { width: 34px; height: 34px; border-radius: 9px; display: grid; place-items: center; background: var(--plate); border: .5px solid var(--line); color: var(--dim); }
  .row.sel .glyph { color: var(--accent); }
  .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta { color: var(--dim); font-size: 11.5px; margin-top: 3px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-variant-numeric: tabular-nums; }
  .meta .st { font-weight: 600; }
  .st.running, .st.downloading { color: var(--accent); }
  .st.seeding { color: var(--seed); }
  .st.finished, .st.completed { color: var(--ok); }
  .st.failed, .st.error { color: var(--danger); }
  .st.paused, .st.queued, .st.stalled, .st.checking, .st.metadata { color: var(--warn); }
  .bar { height: 4px; border-radius: 2px; background: var(--field); margin-top: 6px; overflow: hidden; }
  .bar i { display: block; height: 100%; border-radius: 2px; background: var(--accent); transition: width .5s; }
  .bar.seeding i { background: var(--seed); }
  .bar.finished i, .bar.completed i { background: var(--ok); }
  .bar.paused i, .bar.queued i, .bar.stalled i { background: var(--warn); }
  .bar.failed i, .bar.error i { background: var(--danger); }
  .acts { display: flex; gap: 2px; opacity: .55; }
  .row:hover .acts, .row.sel .acts { opacity: 1; }
  .icon-btn { width: 28px; height: 28px; border-radius: 7px; display: grid; place-items: center; color: var(--dim); }
  .icon-btn:hover { background: var(--field); color: var(--fg); }
  .empty { text-align: center; padding: 90px 20px; color: var(--dim); }
  .empty h3 { font: 650 17px -apple-system, system-ui; color: var(--fg); margin: 14px 0 6px; }
  .empty p { margin: 0 auto 16px; max-width: 400px; line-height: 1.5; }
  .drop { position: fixed; inset: 10px; border: 2px dashed var(--accent); border-radius: 16px; background: color-mix(in srgb, var(--accent) 8%, transparent); display: none; place-items: center; font: 650 17px -apple-system; color: var(--accent); z-index: 50; pointer-events: none; }
  body.dragging .drop { display: grid; }

  /* Detail panel */
  .detail { height: 42vh; min-height: 220px; border-top: .5px solid var(--line); display: flex; flex-direction: column; background: var(--plate); }
  .detail[hidden] { display: none; }
  .tabs { display: flex; align-items: center; gap: 2px; padding: 8px 18px 0; border-bottom: .5px solid var(--line); }
  .tab { padding: 6px 11px 8px; font-weight: 600; font-size: 12px; color: var(--dim); border-bottom: 2px solid transparent; }
  .tab.sel { color: var(--fg); border-bottom-color: var(--accent); }
  .tabs .close { margin-left: auto; }
  .pane { flex: 1; overflow: auto; padding: 14px 22px 20px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 6px 26px; }
  .kv { display: flex; justify-content: space-between; gap: 12px; padding: 4px 0; border-bottom: .5px solid var(--line); font-size: 12px; min-width: 0; }
  .kv span:first-child { color: var(--dim); white-space: nowrap; }
  .kv span:last-child { font-weight: 500; text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-variant-numeric: tabular-nums; user-select: text; }
  .controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 14px; }
  .check { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 500; }
  .check input { accent-color: var(--accent); }
  table { width: 100%; border-collapse: collapse; font-size: 12px; font-variant-numeric: tabular-nums; }
  th { text-align: left; font-weight: 600; color: var(--dim); padding: 4px 8px; border-bottom: .5px solid var(--line); position: sticky; top: -14px; background: var(--bg); white-space: nowrap; }
  td { padding: 5px 8px; border-bottom: .5px solid var(--line); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 380px; }
  td.r, th.r { text-align: right; }
  td .bar { margin: 0; width: 80px; display: inline-block; vertical-align: middle; }
  .mini { height: 24px; border-radius: 6px; border: 0; background: var(--field); padding: 0 7px; font-size: 12px; }
  input.mini { width: 110px; }
  .plate { border-radius: 12px; background: var(--plate); border: .5px solid var(--line); overflow: hidden; }
  .plate.pad { padding: 12px; }
  .plate + .plate, .tiles + .plate, .plate + .addrow, .note + .plate { margin-top: 12px; }
  .hero { display: flex; align-items: center; justify-content: space-between; gap: 18px; flex-wrap: wrap; margin-bottom: 14px; }
  .hero-l { display: flex; align-items: center; gap: 14px; min-width: 0; }
  .hero-t { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .hero-t b { font: 650 15px -apple-system, system-ui; }
  .hero-t span { color: var(--dim); font-size: 12.5px; font-variant-numeric: tabular-nums; }
  .hero-r { display: flex; flex-wrap: wrap; gap: 6px; }
  .pill svg { margin-left: -2px; }
  .ring .track { fill: none; stroke: var(--field); stroke-width: 5; }
  .ring .fill { fill: none; stroke: var(--accent); stroke-width: 5; stroke-linecap: round; transition: stroke-dashoffset .5s; }
  .ring.seeding .fill { stroke: var(--seed); } .ring.finished .fill, .ring.completed .fill { stroke: var(--ok); }
  .ring.paused .fill, .ring.queued .fill, .ring.stalled .fill { stroke: var(--warn); } .ring.failed .fill, .ring.error .fill { stroke: var(--danger); }
  .ring.off .fill { stroke: var(--faint); }
  .ring text { font: 650 12px -apple-system, system-ui; fill: var(--fg); font-variant-numeric: tabular-nums; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(108px, 1fr)); gap: 8px; margin-bottom: 14px; }
  .tile { border-radius: 11px; background: var(--plate); border: .5px solid var(--line); padding: 9px 12px; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .tile span { color: var(--dim); font-size: 11px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tile b { font: 650 16px -apple-system, system-ui; font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tile small { color: var(--faint); font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .actions2 { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
  .cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 14px; align-items: start; }
  .sect { margin-bottom: 14px; min-width: 0; }
  .cols .sect { margin-bottom: 0; }
  .sect-h { display: flex; align-items: baseline; justify-content: space-between; margin: 0 4px 6px; }
  .sect h5 { font: 650 11px -apple-system, system-ui; letter-spacing: .04em; text-transform: uppercase; color: var(--faint); margin: 0; }
  .kvs .kvr { display: flex; justify-content: space-between; gap: 16px; padding: 8px 12px; border-bottom: .5px solid var(--line); font-size: 12px; min-width: 0; }
  .kvs .kvr:last-child, .kvs .opt-row:last-child { border-bottom: 0; }
  .kvr span:first-child { color: var(--dim); white-space: nowrap; }
  .kvr span:last-child { font-weight: 500; text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; user-select: text; font-variant-numeric: tabular-nums; }
  .opt-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 12px; border-bottom: .5px solid var(--line); }
  .opt-row span { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .opt-row b { font-weight: 500; font-size: 12.5px; } .opt-row small { color: var(--faint); font-size: 11px; }
  .opt-row input[type=checkbox] { accent-color: var(--accent); width: 15px; height: 15px; }
  .opt-row input.mini { width: 90px; }
  .list .lrow { display: grid; align-items: center; gap: 12px; padding: 8px 12px; border-bottom: .5px solid var(--line); min-height: 44px; }
  .list .lrow:last-child { border-bottom: 0; }
  .list .lrow:hover { background: var(--hover); }
  .lrow .grow, .grow { min-width: 0; }
  .lrow .grow { display: flex; flex-direction: column; gap: 1px; }
  .lrow .grow b { font-weight: 600; font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lrow .grow small { color: var(--faint); font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lbar { display: flex; align-items: center; gap: 8px; font-size: 11.5px; color: var(--dim); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .lbar .bar { flex: 1; margin: 0; } .lbar em { font-style: normal; min-width: 42px; text-align: right; }
  .lrow.seg { grid-template-columns: 26px minmax(0, 1fr) 200px; }
  .lrow .num { width: 22px; height: 22px; border-radius: 6px; background: var(--field); display: grid; place-items: center; font-size: 11px; font-weight: 650; color: var(--dim); }
  .lrow.peer { grid-template-columns: 20px minmax(140px, 1fr) auto 150px 150px; }
  .pglyph { color: var(--dim); display: grid; place-items: center; }
  .chips { display: flex; gap: 4px; flex-wrap: wrap; justify-content: flex-end; }
  .chip { font-size: 10.5px; font-weight: 600; padding: 2px 7px; border-radius: 6px; background: var(--field); color: var(--dim); white-space: nowrap; }
  .chip.good { color: var(--ok); background: color-mix(in srgb, var(--ok) 14%, transparent); }
  .chip.seed { color: var(--seed); background: color-mix(in srgb, var(--seed) 14%, transparent); }
  .chip.warn { color: var(--warn); background: color-mix(in srgb, var(--warn) 14%, transparent); }
  .chip.dim { background: none; border: .5px solid var(--line); }
  .rates { display: flex; flex-direction: column; align-items: flex-end; gap: 1px; font-size: 11.5px; color: var(--dim); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .rates span { display: inline-flex; align-items: center; gap: 4px; }
  .lrow.trk { grid-template-columns: 10px minmax(0, 1fr) 190px 100px 28px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); display: inline-block; flex: none; }
  .dot.ok { background: var(--ok); } .dot.bad { background: var(--danger); } .dot.busy { background: var(--warn); }
  .tstat, .tnext { display: flex; flex-direction: column; gap: 1px; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; }
  .tstat small, .tnext small { color: var(--faint); font-size: 11px; font-weight: 400; overflow: hidden; text-overflow: ellipsis; }
  .tnext { color: var(--dim); font-variant-numeric: tabular-nums; }
  .sources { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 8px; margin-bottom: 14px; }
  .source { display: flex; align-items: center; gap: 8px; border-radius: 11px; background: var(--plate); border: .5px solid var(--line); padding: 9px 12px; font-size: 12px; }
  .source b { font-weight: 650; } .source span { margin-left: auto; color: var(--dim); white-space: nowrap; }
  .addrow { display: flex; gap: 8px; align-items: flex-start; margin-top: 12px; }
  .addrow .text, .sumrow .text { flex: 1; height: 30px; border-radius: 8px; border: 0; background: var(--field); padding: 0 10px; outline: 2px solid transparent; min-width: 0; }
  .addrow textarea.text { height: 52px; padding: 7px 10px; font: 12px ui-monospace, Menlo, monospace; resize: vertical; }
  .addrow .text:focus, .sumrow .text:focus { outline-color: color-mix(in srgb, var(--accent) 60%, transparent); }
  .legend { display: flex; gap: 16px; margin-top: 10px; font-size: 11.5px; color: var(--dim); }
  .legend span { display: inline-flex; align-items: center; gap: 6px; } .legend .right { margin-left: auto; }
  .sw { width: 10px; height: 10px; border-radius: 3px; background: var(--field); display: inline-block; }
  .sw.on { background: var(--accent); } .sw.busy { background: color-mix(in srgb, var(--accent) 35%, transparent); }
  .lrow.log { grid-template-columns: 90px minmax(0, 1fr); }
  .ltime { display: flex; flex-direction: column; font-size: 12px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .ltime small { color: var(--faint); font-size: 11px; font-weight: 400; }
  .lrow.log .grow { font-size: 12.5px; }
  .sumrow { display: flex; gap: 8px; align-items: center; }
  .sumout { margin-top: 10px; font: 11.5px ui-monospace, Menlo, monospace; color: var(--dim); user-select: text; word-break: break-all; min-height: 16px; }
  .pane-empty { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 26px 10px; color: var(--faint); text-align: center; }
  .pane-empty p { margin: 0; max-width: 380px; line-height: 1.5; color: var(--dim); }
  .segs { position: relative; height: 22px; border-radius: 6px; background: var(--field); overflow: hidden; }
  canvas { width: 100%; height: 44px; border-radius: 8px; background: var(--field); display: block; }
  @media (max-width: 980px) { .lrow.peer { grid-template-columns: 20px minmax(0, 1fr) 120px 110px; } .lrow.peer .chips { display: none; } .lrow.trk { grid-template-columns: 10px minmax(0, 1fr) 150px 28px; } .lrow.trk .tnext { display: none; } }
  .froot { display: flex; align-items: center; gap: 7px; color: var(--dim); font-weight: 600; font-size: 12px; margin: 2px 4px 8px; }
  .flist { border-radius: 12px; background: var(--plate); border: .5px solid var(--line); overflow: hidden; }
  .frow { display: grid; grid-template-columns: 22px 20px minmax(0, 1fr) 80px 170px auto auto; align-items: center; gap: 10px; padding: 7px 10px 7px 12px; border-bottom: .5px solid var(--line); min-height: 44px; }
  .frow:last-child { border-bottom: 0; }
  .frow:hover { background: var(--hover); }
  .frow.skipped .fname, .frow.skipped .fsize, .frow.skipped .fglyph { opacity: .45; }
  .fcheck { display: grid; place-items: center; }
  .fcheck input { accent-color: var(--accent); width: 15px; height: 15px; margin: 0; }
  .fglyph { color: var(--dim); display: grid; place-items: center; }
  .fname { min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .fname b { font-weight: 600; font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .fname small { color: var(--faint); font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .fsize { text-align: right; color: var(--dim); font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .fprog { display: flex; align-items: center; gap: 8px; font-size: 11.5px; color: var(--dim); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .fprog .bar { flex: 1; margin: 0; }
  .fprog em { font-style: normal; font-weight: 600; color: var(--faint); }
  .fprog em.ok { color: var(--ok); }
  .facts { display: flex; gap: 2px; justify-content: flex-end; }
  .facts .icon-btn { width: 26px; height: 26px; }
  @media (max-width: 900px) { .frow { grid-template-columns: 22px 20px minmax(0, 1fr) 70px 110px auto auto; } }
  .segs i { position: absolute; top: 0; bottom: 0; background: var(--accent); border-right: 1px solid var(--bg); }
  .note { color: var(--dim); font-size: 12px; line-height: 1.5; margin: 0 0 12px; }
  .mono { font: 11.5px ui-monospace, Menlo, monospace; user-select: text; }

  /* Sheets */
  .shade { position: fixed; inset: 0; background: var(--shade); display: grid; place-items: center; z-index: 40; }
  .shade[hidden] { display: none; }
  .sheet { width: min(640px, calc(100vw - 40px)); max-height: calc(100vh - 60px); display: flex; flex-direction: column; background: var(--card); border-radius: 16px; box-shadow: 0 20px 60px rgba(0,0,0,.35), 0 0 0 .5px var(--line); }
  .sheet h2 { font: 650 17px ui-rounded, -apple-system, system-ui; margin: 0; padding: 18px 20px 4px; }
  .sheet .sub { color: var(--dim); padding: 0 20px 10px; font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sheet .body { overflow-y: auto; padding: 4px 20px 14px; }
  .sheet .foot { display: flex; justify-content: flex-end; gap: 8px; padding: 12px 20px 16px; border-top: .5px solid var(--line); }
  .field { display: flex; flex-direction: column; gap: 5px; margin-bottom: 12px; }
  .field > span { font-size: 12px; font-weight: 600; color: var(--dim); }
  .field input[type=text], .field input[type=number], .field select, .field textarea, .text { height: 30px; border-radius: 8px; border: 0; background: var(--field); padding: 0 10px; outline: 2px solid transparent; }
  .field textarea { height: 86px; padding: 8px 10px; resize: vertical; font: 12px ui-monospace, Menlo, monospace; }
  .field input:focus, .field select:focus, .field textarea:focus { outline-color: color-mix(in srgb, var(--accent) 60%, transparent); }
  .pathrow { display: flex; gap: 8px; }
  .pathrow input { flex: 1; }
  .files { max-height: 260px; overflow-y: auto; border-radius: 10px; background: var(--plate); border: .5px solid var(--line); padding: 4px; margin-bottom: 12px; }
  .files label { display: grid; grid-template-columns: 18px 1fr auto; gap: 8px; align-items: center; padding: 4px 6px; border-radius: 6px; font-size: 12px; }
  .files label:hover { background: var(--hover); }
  .files label span:nth-child(2) { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .files label span:last-child { color: var(--dim); font-variant-numeric: tabular-nums; }
  .settings section { margin-bottom: 16px; }
  .settings h4 { font: 650 13px -apple-system, system-ui; margin: 6px 0 8px; }
  .settings .opt { display: grid; grid-template-columns: 1fr auto; align-items: center; gap: 12px; padding: 7px 0; border-bottom: .5px solid var(--line); font-size: 12.5px; }
  .settings .opt small { display: block; color: var(--dim); font-size: 11px; margin-top: 2px; }
  .settings input[type=number], .settings input[type=text], .settings select { height: 26px; border-radius: 7px; border: 0; background: var(--field); padding: 0 8px; width: 150px; }
  .settings input[type=checkbox] { accent-color: var(--accent); transform: scale(1.15); }
  .menu { position: fixed; z-index: 60; min-width: 210px; background: var(--card); border-radius: 10px; padding: 5px; box-shadow: 0 10px 30px rgba(0,0,0,.25), 0 0 0 .5px var(--line); }
  .menu button { display: flex; width: 100%; align-items: center; gap: 9px; padding: 6px 10px; border-radius: 6px; text-align: left; font-size: 12.5px; }
  .menu button svg { opacity: .75; }
  .menu button:hover svg { opacity: 1; }
  .menu button:hover { background: var(--accent); color: #fff; }
  .menu button.danger { color: var(--danger); }
  .menu button.danger:hover { color: #fff; background: var(--danger); }
  .menu hr { border: 0; border-top: .5px solid var(--line); margin: 4px 6px; }
  .switch { position: relative; width: 38px; height: 22px; border-radius: 11px; background: var(--field); transition: background .18s; flex: none; }
  .switch::after { content: ""; position: absolute; top: 2px; left: 2px; width: 18px; height: 18px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.3); transition: transform .18s; }
  .switch.on { background: var(--accent); }
  .switch.on::after { transform: translateX(16px); }
  .st.off { color: var(--faint); }
  .bar.off i { background: var(--faint); }
  .toast { position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%); background: var(--card); padding: 9px 14px; border-radius: 10px; box-shadow: 0 8px 24px rgba(0,0,0,.2), 0 0 0 .5px var(--line); font-weight: 500; z-index: 70; }
  @media (max-width: 760px) { .app { grid-template-columns: minmax(0, 1fr); } aside { display: none; } }
</style>
</head>
<body>
<div class="app">
  <aside>
    <div class="brand"><span class="mark" data-i="down"></span>Downloads</div>
    <nav id="views"></nav>
    <h3>Kinds</h3>
    <nav id="kinds"></nav>
    <div class="spacer"></div>
    <button class="item" id="addBtn"><span class="ic" data-i="plus"></span><span class="label">Add Address or Magnet…</span></button>
    <button class="item" id="openBtn"><span class="ic" data-i="file"></span><span class="label">Open Torrent File…</span></button>
    <button class="item" id="createBtn"><span class="ic" data-i="make"></span><span class="label">Create Torrent…</span></button>
    <button class="item" id="settingsBtn"><span class="ic" data-i="gear"></span><span class="label">Download Settings</span></button>
    <div class="foot-side">
      <button class="toggle-row" id="torrentSwitch" title="Download torrents in Tuff"><span class="ic" data-i="magnet"></span><span class="label">Torrents <small id="torrentState">Off</small></span><span class="switch" id="torrentKnob"></span></button>
      <button class="toggle-row" id="advancedSwitch" hidden title="Show peers, trackers, pieces and every setting"><span class="ic" data-i="sliders"></span><span class="label">Advanced</span><span class="tick" id="advancedTick"></span></button>
      <div class="stats" id="stats"></div>
    </div>
  </aside>
  <main>
    <header>
      <h1 id="heading">All Downloads</h1><span class="count" id="count"></span>
      <div class="speeds" id="speeds"></div>
    </header>
    <div class="toolbar">
      <label class="search"><span data-i="search"></span><input id="q" type="search" placeholder="Search downloads" autocomplete="off" spellcheck="false"><kbd>/</kbd></label>
      <select class="sort" id="sort" title="Sort">
        <option value="added">Newest</option><option value="name">Name</option><option value="size">Size</option>
        <option value="progress">Progress</option><option value="speed">Speed</option><option value="queue">Queue</option>
      </select>
      <button class="pill" id="pauseAll"><span data-i="pause"></span>Pause All</button>
      <button class="pill" id="resumeAll"><span data-i="play"></span>Resume All</button>
      <button class="pill" id="clear">Clear Finished</button>
    </div>
    <div class="list" id="list" tabindex="0"></div>
    <div class="detail" id="detail" hidden>
      <div class="tabs" id="tabs"></div>
      <div class="pane" id="pane"></div>
    </div>
  </main>
</div>
<div class="shade" id="shade" hidden><div class="sheet" id="sheet"></div></div>
<div class="drop">Drop torrent files or links to download them</div>
<script>
(() => {
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  async function send(cmd, args = {}, tries = 4) {
    for (let i = 0; ; i++) {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuff;
        if (!h) throw new Error('Tuff isn’t answering.');
        return await h.postMessage({ cmd, ...args });
      } catch (e) {
        if (i >= tries || !/answering|busy/.test(String(e))) { toast(String(e.message || e)); throw e; }
        await wait(150 * (i + 1));
      }
    }
  }

  // Icons (stroked, 24-unit grid)
  const P = {
    down: '<path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 20h14"/>', up: '<path d="M12 20V9m0 0-4.5 4.5M12 9l4.5 4.5M5 4h14"/>',
    pause: '<path d="M9 6v12M15 6v12"/>', play: '<path d="M8 5.5v13l10.5-6.5z"/>', x: '<path d="M6 6l12 12M18 6 6 18"/>',
    folder: '<path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/>',
    more: '<circle cx="6" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="18" cy="12" r="1.3"/>',
    plus: '<path d="M12 5v14M5 12h14"/>', file: '<path d="M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20z"/><path d="M14 3.5V8h4"/>',
    make: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M6 18l2.5-2.5M15.5 8.5 18 6"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>', retry: '<path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4.5h4.5"/>',
    all: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M8 12h8"/>', active: '<path d="M4 12h3l3-7 4 14 3-7h3"/>',
    done: '<path d="m5 12.5 4.5 4.5L19 7.5"/>', warn: '<path d="M12 4 2.8 19.5h18.4z"/><path d="M12 10v4.5M12 17v.2"/>',
    magnet: '<path d="M6 4v8a6 6 0 0 0 12 0V4h-4v8a2 2 0 0 1-4 0V4z"/><path d="M6 8h4M14 8h4"/>', seed: '<path d="M12 20V10M12 10c0-3.5 2.5-6 6-6 0 3.5-2.5 6-6 6zM12 13c0-3-2-5-5-5 0 3 2 5 5 5z"/>',
    video: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10.5 5-3v9l-5-3"/>', audio: '<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/>',
    image: '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><circle cx="9" cy="10" r="1.7"/><path d="m20.5 16-5-5-9 8.5"/>',
    archive: '<rect x="4" y="3.5" width="16" height="17" rx="2"/><path d="M12 3.5v2M12 7.5v2M12 11.5v2"/><rect x="10.5" y="14" width="3" height="3" rx=".6"/>',
    app: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M9 15.5 12 8l3 7.5M10 13h4"/>', document: '<path d="M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20z"/><path d="M10 12h5M10 15.5h5"/>',
    other: '<path d="M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20z"/>', torrent: '<path d="M6 4v8a6 6 0 0 0 12 0V4h-4v8a2 2 0 0 1-4 0V4z"/>',
    sliders: '<path d="M5 6h9M18 6h1M5 12h3M12 12h7M5 18h11M20 18h-1"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16H8"/>',
    pencil: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="m13 7 4 4"/>', trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
    bolt: '<path d="M13 3 5 13.5h6L10 21l8-10.5h-6z"/>', open: '<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/>',
    export: '<path d="M12 15V4m0 0L8 8m4-4 4 4"/><path d="M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/>', check: '<circle cx="12" cy="12" r="8.5"/><path d="m8.5 12.3 2.4 2.4 4.6-5"/>',
    broadcast: '<circle cx="12" cy="12" r="2"/><path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8"/>',
    move: '<path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/><path d="M10 13.5h5m0 0-2-2m2 2-2 2"/>',
    top: '<path d="M6 4h12M12 20V9m0 0-4 4m4-4 4 4"/>', bottom: '<path d="M6 20h12M12 4v11m0 0-4-4m4 4 4-4"/>',
    arrowUp: '<path d="M12 19V5m0 0-5 5m5-5 5 5"/>', arrowDown: '<path d="M12 5v14m0 0-5-5m5 5 5-5"/>', stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  };
  const icon = (n, s = 15) => `<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${P[n] || P.other}</svg>`;
  const fileKind = (name) => {
    const ext = (name.split('.').pop() || '').toLowerCase();
    if (/^(mp4|mkv|mov|avi|webm|m4v|wmv|flv|ts)$/.test(ext)) return 'video';
    if (/^(mp3|m4a|flac|wav|aac|ogg|opus|aiff)$/.test(ext)) return 'audio';
    if (/^(jpe?g|png|gif|webp|heic|svg|tiff|bmp|avif)$/.test(ext)) return 'image';
    if (/^(zip|rar|7z|gz|tgz|bz2|xz|tar|zst)$/.test(ext)) return 'archive';
    if (/^(dmg|pkg|app|iso|exe|msi|apk|ipa|dat|bin|img)$/.test(ext)) return 'app';
    if (/^(pdf|docx?|txt|rtf|md|pages|xlsx?|csv|pptx?|key|numbers|epub|nfo)$/.test(ext)) return 'document';
    return 'other';
  };
  const paintIcons = (root = document) => root.querySelectorAll('[data-i]').forEach((e) => { if (!e.firstChild) e.innerHTML = icon(e.dataset.i); });
  paintIcons();

  // Formatting
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const size = (b) => { if (!(b >= 0)) return '—'; let i = 0; while (b >= 1000 && i < 4) { b /= 1000; i++; } return (i ? b.toFixed(b < 10 ? 2 : b < 100 ? 1 : 0) : Math.round(b)) + ' ' + units[i]; };
  const speed = (b) => size(b || 0) + '/s';
  const time = (s) => { if (!(s >= 0) || !isFinite(s)) return '∞'; s = Math.round(s); if (s < 60) return s + 's'; if (s < 3600) return Math.floor(s / 60) + 'm ' + (s % 60) + 's'; if (s < 86400) return Math.floor(s / 3600) + 'h ' + Math.floor(s % 3600 / 60) + 'm'; return Math.floor(s / 86400) + 'd ' + Math.floor(s % 86400 / 3600) + 'h'; };
  const date = (ms) => ms ? new Date(ms).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : '—';
  const pct = (p) => (Math.floor((p || 0) * 1000) / 10).toFixed(1) + '%';
  const stateLabel = { running: 'Downloading', downloading: 'Downloading', finished: 'Done', completed: 'Done', paused: 'Paused', queued: 'Queued', failed: 'Failed', error: 'Error', seeding: 'Seeding', stalled: 'Stalled', checking: 'Checking', metadata: 'Getting details', off: 'Torrents off' };
  function toast(text) {
    const t = document.createElement('div'); t.className = 'toast'; t.textContent = text; document.body.appendChild(t);
    setTimeout(() => t.remove(), 2600);
  }

  // State
  let data = { http: [], torrents: [], global: {}, events: [], pending: [] };
  // Advanced: everything. Otherwise only what most people need (and only with torrents on).
  const adv = () => !!(data.advanced && data.torrentsEnabled);
  let view = 'all', kind = '', query = '', sel = null, tab = 'general', menuEl = null, sheetKind = null, busy = false;
  let shownPending = null;
  try { view = localStorage.getItem('dl.view') || 'all'; } catch {}

  const all = () => [...data.http, ...data.torrents.map((t) => ({ ...t, category: 'torrent' }))];
  const isActive = (d) => ['running', 'downloading', 'stalled', 'metadata', 'checking', 'queued'].includes(d.state);
  const views = [
    ['all', 'All', 'all', () => true],
    ['active', 'Active', 'active', isActive],
    ['done', 'Completed', 'done', (d) => ['finished', 'completed', 'seeding'].includes(d.state)],
    ['paused', 'Paused', 'pause', (d) => d.state === 'paused'],
    ['failed', 'Failed', 'warn', (d) => ['failed', 'error'].includes(d.state)],
    ['torrents', 'Torrents', 'magnet', (d) => d.kind === 'torrent'],
    ['seeding', 'Seeding', 'seed', (d) => d.state === 'seeding'],
  ];
  const kinds = [['video', 'Video'], ['audio', 'Audio'], ['document', 'Documents'], ['image', 'Images'], ['archive', 'Archives'], ['app', 'Apps & Disk Images'], ['other', 'Other']];

  function visible() {
    const v = views.find((x) => x[0] === view) || views[0];
    let list = all().filter(v[3]);
    if (kind) list = list.filter((d) => d.category === kind);
    if (query) { const q = query.toLowerCase(); list = list.filter((d) => (d.name + ' ' + (d.url || '') + ' ' + (d.path || '')).toLowerCase().includes(q)); }
    const by = $('sort').value;
    const key = { added: (d) => -(d.added || 0), name: (d) => d.name.toLowerCase(), size: (d) => -(d.size || 0), progress: (d) => -(d.progress || 0), speed: (d) => -((d.speed || d.down || 0)), queue: (d) => d.kind === 'torrent' ? d.queue : 1e9 }[by];
    return list.sort((a, b) => { const x = key(a), y = key(b); return x < y ? -1 : x > y ? 1 : 0; });
  }

  // Sidebar
  function drawSidebar() {
    const items = all();
    const shownViews = views.filter(([id]) => (id !== 'torrents' || data.torrentsEnabled || data.torrents.length) && (id !== 'seeding' || adv()));
    if (!shownViews.some((v) => v[0] === view)) view = 'all';
    $('views').innerHTML = shownViews.map(([id, label, ic, test]) =>
      `<button class="item${view === id && !kind ? ' sel' : ''}" data-view="${id}"><span class="ic">${icon(ic)}</span><span class="label">${label}</span><span class="n">${items.filter(test).length || ''}</span></button>`).join('');
    $('kinds').innerHTML = kinds.map(([id, label]) => {
      const n = items.filter((d) => d.category === id).length;
      return `<button class="item${kind === id ? ' sel' : ''}" data-kind="${id}"><span class="ic">${icon(id)}</span><span class="label">${label}</span><span class="n">${n || ''}</span></button>`;
    }).join('');
    const g = data.global || {};
    const rows = [['Down', speed((g.down || 0) + (data.httpSpeed || 0))]];
    if (data.torrentsEnabled) rows.push(['Up', speed(g.up)]);
    if (adv()) {
      rows.push(['Peers', g.peers ?? 0], ['DHT nodes', g.dhtNodes ?? 0]);
      if (g.port) rows.push(['Port', g.port]);
      if (g.externalIP) rows.push(['Address', esc(g.externalIP)]);
      if (g.downloadedAll) rows.push(['All time ↓', size(g.downloadedAll)], ['All time ↑', size(g.uploadedAll)]);
    }
    $('stats').innerHTML = rows.map(([k, v]) => `<span>${k}</span><b title="${v}">${v}</b>`).join('');
    $('createBtn').hidden = !adv();
    $('openBtn').hidden = !data.torrentsEnabled;
    $('advancedSwitch').hidden = !data.torrentsEnabled;
    $('advancedTick').classList.toggle('on', adv());
    $('advancedTick').innerHTML = adv() ? icon('done', 11) : '';
  }

  // List
  function meta(d) {
    const st = `<span class="st ${d.state}">${esc(d.state === 'failed' ? (d.reason || 'Failed') : d.state === 'error' ? (d.error || 'Error') : stateLabel[d.state] || d.state)}</span>`;
    const bits = [st];
    if (d.kind === 'http') {
      if (d.state === 'running') {
        bits.push(`${size(d.done)} of ${size(d.size)}`, speed(d.speed));
        if (d.eta) bits.push(time(d.eta) + ' left');
        if (d.connections > 1 && adv()) bits.push(d.connections + ' connections');
      } else if (d.state === 'finished') {
        bits.push(size(d.size));
        try { bits.push(new URL(d.url).host); } catch {}
      } else { bits.push(`${size(d.done)} of ${size(d.size)}`); }
    } else if (d.state === 'off') {
      bits.push(`${size(d.done)} of ${size(d.size)}`, 'turn torrents on to carry on');
    } else {
      if (d.state === 'metadata') bits.push('from ' + (d.peers + d.seeds) + ' peers');
      else if (d.state === 'checking') bits.push(pct(d.progress));
      else {
        bits.push(`${size(d.done)} of ${size(d.size)}`);
        if (d.down > 0) bits.push('↓ ' + speed(d.down));
        if (d.up > 0 && adv()) bits.push('↑ ' + speed(d.up));
        if (d.eta > 0 && d.state === 'downloading') bits.push(time(d.eta) + ' left');
        if (adv()) {
          bits.push(`${d.seeds} seed${d.seeds === 1 ? '' : 's'}, ${d.peers} peer${d.peers === 1 ? '' : 's'}`);
          if (d.uploaded > 0) bits.push('ratio ' + d.ratio.toFixed(2));
        } else if (d.state === 'downloading' || d.state === 'stalled') {
          const n = d.seeds + d.peers;
          bits.push(n ? `from ${n} ${n === 1 ? 'person' : 'people'}` : 'looking for people to download from');
        }
      }
    }
    return bits.join(' · ');
  }

  function actions(d) {
    const b = (act, ic, title) => `<button class="icon-btn" data-act="${act}" title="${title}">${icon(ic)}</button>`;
    let out = '';
    if (d.kind === 'http') {
      if (d.state === 'running') out += b('pause', 'pause', 'Pause');
      else if (d.state !== 'finished' && d.resumable) out += b('resume', d.state === 'failed' ? 'retry' : 'play', d.state === 'failed' ? 'Try Again' : 'Resume');
      if (d.state === 'finished') out += b('reveal', 'folder', 'Show in Finder');
    } else if (d.state === 'off') {
      out += b('reveal', 'folder', 'Show in Finder');
    } else {
      if (d.state === 'paused' || d.state === 'error') out += b('resume', 'play', 'Resume');
      else if (d.state === 'completed') { if (adv()) out += b('seed', 'seed', 'Seed'); }
      else out += b('pause', 'pause', 'Pause');
      out += b('reveal', 'folder', 'Show in Finder');
    }
    return out + b('menu', 'more', 'More');
  }

  const rowCache = new Map();
  function drawList() {
    const list = visible();
    const box = $('list');
    if (!list.length) {
      rowCache.clear();
      const empty = all().length === 0;
      box.innerHTML = `<div class="empty">${icon('down', 34)}<h3>${empty ? 'Nothing downloaded yet' : 'Nothing here'}</h3><p>${empty
        ? 'Files you download from pages show up here. Paste a link or magnet, drop a .torrent file on this page, or open one from Finder.'
        : 'Try another view, or clear the search.'}</p>${empty ? '<button class="pill primary" id="emptyAdd">Add Address or Magnet…</button>' : ''}</div>`;
      const e = $('emptyAdd'); if (e) e.onclick = () => openAdd();
      return;
    }
    if (box.querySelector('.empty')) box.innerHTML = '';
    const keep = new Set();
    let prev = null;
    for (const d of list) {
      keep.add(d.id);
      let row = rowCache.get(d.id);
      if (!row) {
        row = document.createElement('div');
        row.className = 'row';
        row.dataset.id = d.id;
        rowCache.set(d.id, row);
      }
      const html = `<div class="glyph">${icon(d.kind === 'torrent' ? 'torrent' : d.category, 17)}</div>
        <div style="min-width:0"><div class="name" title="${esc(d.name)}">${esc(d.name)}</div><div class="meta">${meta(d)}</div>
        ${d.state === 'finished' || d.state === 'completed' ? '' : `<div class="bar ${d.state}"><i style="width:${Math.max(0, Math.min(100, (d.progress || 0) * 100))}%"></i></div>`}</div>
        <div class="acts">${actions(d)}</div>`;
      if (row._html !== html) { row.innerHTML = html; row._html = html; }
      row.classList.toggle('sel', d.id === sel);
      const next = prev ? prev.nextSibling : box.firstChild;
      if (next !== row) box.insertBefore(row, next);
      prev = row;
    }
    for (const [id, row] of rowCache) if (!keep.has(id)) { row.remove(); rowCache.delete(id); }
  }

  function drawHeader() {
    const v = views.find((x) => x[0] === view);
    $('heading').textContent = kind ? kinds.find((k) => k[0] === kind)[1] : (v[0] === 'all' ? 'All Downloads' : v[1]);
    const items = visible();
    const active = all().filter(isActive).length;
    $('count').textContent = items.length + (items.length === 1 ? ' item' : ' items') + (active ? ` · ${active} active` : '');
    const g = data.global || {};
    const on = !!data.torrentsEnabled;
    $('torrentKnob').classList.toggle('on', on);
    $('torrentState').textContent = on ? 'On' : 'Off';
    $('speeds').innerHTML = `<span>${icon('down', 12)}${speed((g.down || 0) + (data.httpSpeed || 0))}</span><span>${icon('up', 12)}${speed(g.up)}</span>`;
  }

  // Detail panel
  const find = (id) => all().find((d) => d.id === id);
  function drawDetail() {
    const d = sel && find(sel);
    $('detail').hidden = !d;
    if (!d) return;
    const tabs = !adv() ? [['general', 'General']].concat(d.kind === 'torrent' ? [['files', 'Files']] : []) : d.kind === 'torrent'
      ? [['general', 'General'], ['files', 'Files'], ['peers', 'Peers'], ['trackers', 'Trackers'], ['log', 'Log']]
      : [['general', 'General'], ['segments', 'Connections'], ['checksum', 'Checksum']];
    if (!tabs.some((t) => t[0] === tab)) tab = 'general';
    $('tabs').innerHTML = tabs.map(([id, label]) => `<button class="tab${tab === id ? ' sel' : ''}" data-tab="${id}">${label}</button>`).join('') +
      `<button class="icon-btn close" data-act="closeDetail" title="Close">${icon('x', 13)}</button>`;
    if (busy) return;
    const x = data.detail && data.detail.id === d.id ? { ...d, ...data.detail } : d;
    $('pane').innerHTML = (d.kind === 'torrent' ? torrentPane : httpPane)(x);
    if (tab === 'general' && d.kind === 'torrent') drawPieces(x);
  }
  // Building blocks for the detail panes.
  const plateRows = (list) => {
    const shown = list.filter((r) => r && r[1] !== undefined && r[1] !== '' && r[1] !== null);
    return shown.length ? `<div class="plate kvs">${shown.map(([k, v, mono]) => `<div class="kvr"><span>${k}</span><span class="${mono ? 'mono' : ''}" title="${esc(v)}">${esc(v)}</span></div>`).join('')}</div>` : '';
  };
  const tile = (label, value, sub = '') => `<div class="tile"><span>${label}</span><b>${value}</b>${sub ? `<small>${sub}</small>` : ''}</div>`;
  const pbtn = (act, ic, label, cls = '') => `<button class="pill ${cls}" data-act="${act}">${icon(ic, 13)}${label}</button>`;
  const section = (title, body, extra = '') => body ? `<div class="sect"><div class="sect-h"><h5>${title}</h5>${extra}</div>${body}</div>` : '';
  const chip = (text, cls = '') => `<span class="chip ${cls}">${text}</span>`;
  function ring(frac, state) {
    const r = 23, c = 2 * Math.PI * r, f = Math.max(0, Math.min(1, frac || 0));
    return `<svg class="ring ${state}" width="58" height="58" viewBox="0 0 58 58"><circle cx="29" cy="29" r="${r}" class="track"/>
      <circle cx="29" cy="29" r="${r}" class="fill" stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - f)}" transform="rotate(-90 29 29)"/>
      <text x="29" y="33" text-anchor="middle">${f >= 1 ? '✓' : Math.floor(f * 100) + '%'}</text></svg>`;
  }
  function hero(d, frac, status, line, buttons) {
    return `<div class="hero"><div class="hero-l">${ring(frac, d.state)}<div class="hero-t"><b class="st ${d.state}">${esc(status)}</b><span>${line}</span></div></div>
      <div class="hero-r">${buttons}</div></div>`;
  }
  const empty = (ic, text) => `<div class="pane-empty">${icon(ic, 22)}<p>${text}</p></div>`;

  function httpPane(d) {
    if (tab === 'segments') {
      const segs = d.segments || [];
      const total = d.size > 0 ? d.size : 1;
      const multi = d.engine === 'Multi-connection';
      return `<p class="note">${multi
        ? `Tuff splits the file into ranges and fetches them over ${d.connections || 'several'} connections at once. When one range finishes, the biggest one left is split again, so every connection stays busy.`
        : 'WebKit downloads this file over one connection: the server doesn’t allow ranges, or the file is too small to split.'}</p>
        ${segs.length ? `<div class="plate pad"><div class="segs">${segs.map(([s, p]) => `<i style="left:${s / total * 100}%;width:${Math.max(0, (p - s) / total * 100)}%"></i>`).join('')}</div>
        <div class="legend"><span><i class="sw on"></i>Downloaded</span><span><i class="sw"></i>Still to come</span><span class="right">${segs.length} range${segs.length === 1 ? '' : 's'}</span></div></div>
        <div class="plate list">${segs.map(([s, p, e], i) => {
          const f = e > s ? (p - s) / (e - s) : 0;
          return `<div class="lrow seg"><span class="num">${i + 1}</span><span class="grow"><b>${size(s)} – ${e < 0 ? '?' : size(e)}</b><small>${size(p - s)} of ${e < 0 ? '?' : size(e - s)}</small></span>
            <span class="lbar"><span class="bar"><i style="width:${f * 100}%"></i></span><em>${f >= 1 ? 'Done' : pct(f)}</em></span></div>`;
        }).join('')}</div>` : empty('link', 'No ranges yet.')}`;
    }
    if (tab === 'checksum') {
      return `<p class="note">Compare the file with the checksum the site publishes, to be sure it arrived intact and unaltered.</p>
        <div class="plate pad sum">
          <div class="sumrow"><select class="mini" id="sumKind"><option value="sha256">SHA-256</option><option value="sha1">SHA-1</option><option value="md5">MD5</option></select>
          <input class="text grow" id="sumExpected" placeholder="Paste the expected checksum (optional)">
          <button class="pill primary" data-act="checksum" ${d.state === 'finished' ? '' : 'disabled'}>${icon('check', 13)}Calculate</button></div>
          <div id="sumOut" class="sumout">${d.state === 'finished' ? '' : 'Available once the download has finished.'}</div>
        </div>`;
    }
    const frac = d.state === 'finished' ? 1 : (d.progress || 0);
    const line = d.state === 'running'
      ? `${size(d.done)} of ${size(d.size)} · ${speed(d.speed)}${d.eta ? ' · ' + time(d.eta) + ' left' : ''}`
      : d.state === 'finished' ? `${size(d.size)}${d.completed && d.added ? ' · took ' + time((d.completed - d.added) / 1000) : ''}` : `${size(d.done)} of ${size(d.size)}`;
    const buttons = (d.state === 'running' ? pbtn('pause', 'pause', 'Pause') : d.state !== 'finished' && d.resumable ? pbtn('resume', d.state === 'failed' ? 'retry' : 'play', d.state === 'failed' ? 'Try Again' : 'Resume') : '')
      + (d.state === 'finished' ? pbtn('open', 'open', 'Open') + pbtn('reveal', 'folder', 'Show in Finder') : '')
      + pbtn('copy', 'copy', 'Copy Address') + pbtn('remove', 'x', 'Remove', 'danger');
    let host = ''; try { host = new URL(d.url).host; } catch {}
    return hero(d, frac, d.state === 'failed' ? (d.reason || 'Failed') : stateLabel[d.state], line, buttons)
      + `<div class="cols">` + section('Details', plateRows([
        ['From', host], ['Address', d.url, 1], ['Saved to', d.path, 1], ['Started', date(d.added)], ['Finished', d.completed ? date(d.completed) : ''],
      ])) + (adv() ? section('Connection', plateRows([
        ['Engine', d.engine], ['Connections', d.connections || ''], ['Resumable', d.ranges === undefined ? '' : d.ranges ? 'Yes' : 'No'],
        ['ETag', d.etag || '', 1], ['Last modified', d.modified || ''],
      ])) : '') + `</div>`;
  }

  function torrentPane(d) {
    if (tab === 'files') {
      const files = d.files || [];
      if (!files.length) return '<p class="note">The file list arrives once Tuff has the torrent’s details from other people.</p>';
      // The torrent's own folder is the same for every file: show it once, above the list.
      const parts = files.map((f) => f.path.split('/'));
      const root = parts.every((p) => p.length > 1 && p[0] === parts[0][0]) ? parts[0][0] : '';
      const wanted = files.filter((f) => f.priority > 0);
      const media = /\.(mp4|mkv|mov|avi|webm|m4v|mp3|m4a|flac|wav|aac|ogg|opus)$/i;
      const row = (f) => {
        const p = f.path.split('/'); if (root) p.shift();
        const name = p.pop(), folder = p.join(' / ');
        const frac = f.size ? f.done / f.size : 1, done = frac >= 1, on = f.priority > 0;
        const btn = (act, ic, title, extra = '') => `<button class="icon-btn" data-act="${act}" data-file="${f.i}" data-path="${esc(f.full)}" data-name="${esc(name)}" title="${title}"${extra}>${icon(ic, 14)}</button>`;
        return `<div class="frow${on ? '' : ' skipped'}">
          <label class="fcheck" title="${on ? 'Skip this file' : 'Download this file'}"><input type="checkbox" data-want="${f.i}" data-priority="${f.priority}"${on ? ' checked' : ''}></label>
          <span class="fglyph">${icon(fileKind(name), 16)}</span>
          <span class="fname"><b title="${esc(f.path)}">${esc(name)}</b>${folder ? `<small>${esc(folder)}</small>` : ''}</span>
          <span class="fsize">${size(f.size)}</span>
          <span class="fprog">${!on ? '<em>Skipped</em>' : done ? '<em class="ok">Done</em>' : `<span class="bar"><i style="width:${frac * 100}%"></i></span><span>${pct(frac)}</span>`}</span>
          <span class="fpri">${adv() && on ? `<select class="mini" data-file="${f.i}">${[[1, 'Normal'], [2, 'High'], [3, 'Maximum']].map(([v, l]) => `<option value="${v}"${f.priority === v ? ' selected' : ''}>${l}</option>`).join('')}</select>` : ''}</span>
          <span class="facts">${done ? btn('openFile', 'open', 'Open') : on && media.test(name) ? btn('stream', 'play', 'Play while downloading: fetch the start first') : ''}${btn('revealFile', 'folder', 'Show in Finder')}${adv() ? btn('renameFile', 'pencil', 'Rename') : ''}</span>
        </div>`;
      };
      return `<div class="controls"><button class="pill" data-act="filesAll">Download All</button><button class="pill" data-act="filesNone">Skip All</button>
        <span class="note" style="margin:0">${wanted.length} of ${files.length} file${files.length === 1 ? '' : 's'} · ${size(wanted.reduce((a, f) => a + f.size, 0))} to download. Skipped files never land on disk.</span></div>
        ${root ? `<div class="froot">${icon('folder', 14)}${esc(root)}</div>` : ''}
        <div class="flist">${files.map(row).join('')}</div>`;
    }
    if (tab === 'peers') {
      const peers = (d.peerList || []).sort((a, b) => (b.down + b.up) - (a.down + a.up));
      const head = `<div class="tiles">${tile('Connected', peers.length)}${tile('Known', d.candidates || 0)}${tile('Downloading from', peers.filter((p) => p.down > 0).length)}${tile('Banned', d.banned || 0, 'sent bad data')}</div>`;
      const add = `<div class="addrow"><input class="text grow" id="peerAddr" placeholder="Add a peer by address, like 203.0.113.5:6881"><button class="pill" data-act="addPeer">${icon('plus', 13)}Add</button></div>`;
      if (!peers.length) return head + empty('magnet', 'No one connected yet. Tuff keeps looking through trackers, DHT and peer exchange.') + add;
      return head + `<div class="plate list">${peers.map((p) => {
        const seed = p.progress >= 1;
        const chips = (p.utp ? chip('µTP') : chip('TCP')) + (p.encrypted ? chip('Encrypted', 'good') : '') + (p.flags.includes('I') ? chip('Incoming') : '')
          + (seed ? chip('Seed', 'seed') : '') + (p.flags.includes('S') ? chip('Snubbed', 'warn') : '') + (p.source ? chip(esc(p.source), 'dim') : '');
        return `<div class="lrow peer"><span class="pglyph">${icon(seed ? 'seed' : 'link', 15)}</span>
          <span class="grow"><b>${esc(p.client || 'Unknown client')}</b><small class="mono">${esc(p.addr)}</small></span>
          <span class="chips">${chips}</span>
          <span class="lbar"><span class="bar ${seed ? 'seeding' : ''}"><i style="width:${p.progress * 100}%"></i></span><em>${pct(p.progress)}</em></span>
          <span class="rates"><span>${icon('down', 11)}${speed(p.down)}</span><span>${icon('up', 11)}${speed(p.up)}</span></span></div>`;
      }).join('')}</div>` + add;
    }
    if (tab === 'trackers') {
      const all = d.trackers || [];
      const special = all.filter((x) => x.special), list = all.filter((x) => !x.special);
      const dot = (status) => /^Working/.test(status) ? 'ok' : /Updating/.test(status) ? 'busy' : /^Off|Stopped|Not contacted/.test(status) ? 'off' : 'bad';
      const sources = `<div class="sources">${special.map((x) => `<div class="source"><i class="dot ${dot(x.status)}"></i><b>${esc(x.url)}</b><span>${x.status === 'Working' ? `${x.peers} found` : esc(x.status)}</span></div>`).join('')}</div>`;
      const rows = list.map((x) => {
        let host = x.url; try { host = new URL(x.url).host; } catch {}
        const counts = [x.seeds >= 0 ? `${x.seeds} seeds` : '', x.leechers >= 0 ? `${x.leechers} downloading` : '', x.completed >= 0 ? `${x.completed} finished` : ''].filter(Boolean).join(' · ');
        return `<div class="lrow trk"><i class="dot ${dot(x.status)}"></i>
          <span class="grow"><b title="${esc(x.url)}">${esc(host)}</b><small title="${esc(x.message || x.url)}">${esc(x.message || x.url)}</small></span>
          <span class="tstat">${esc(x.status)}${counts ? `<small>${counts}</small>` : ''}</span>
          <span class="tnext">${x.next === undefined ? '' : x.next ? 'next in ' + time(x.next) : 'now'}<small>tier ${x.tier + 1}</small></span>
          <button class="icon-btn" data-act="removeTracker" data-url="${esc(x.url)}" title="Remove this tracker">${icon('x', 12)}</button></div>`;
      }).join('');
      const seeds = (d.webSeeds || []).map((w) => `<div class="lrow trk"><i class="dot ${dot(w.status === 'Idle' ? 'Off' : w.status)}"></i>
        <span class="grow"><b class="mono">${esc(w.url)}</b><small>${w.kind} web seed</small></span><span class="tstat">${esc(w.status)}<small>${size(w.downloaded)} from here</small></span></div>`).join('');
      return sources + section('Trackers', rows ? `<div class="plate list">${rows}</div>` : empty('broadcast', 'This torrent has no trackers; Tuff finds people through DHT and peer exchange.'))
        + section('Web seeds', seeds ? `<div class="plate list">${seeds}</div>` : '')
        + section('Add trackers', `<div class="addrow"><textarea class="text grow" id="newTrackers" rows="2" placeholder="udp://tracker.example.org:1337/announce — one per line"></textarea><button class="pill" data-act="addTrackers">${icon('plus', 13)}Add</button></div>`);
    }
    if (tab === 'log') {
      const ev = (data.events || []).filter((e) => e.id === d.id).slice().reverse();
      if (!ev.length) return empty('active', 'Nothing has happened yet.');
      return `<div class="plate list">${ev.map((e) => `<div class="lrow log"><span class="ltime">${new Date(e.time).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', second: '2-digit' })}<small>${new Date(e.time).toLocaleDateString([], { month: 'short', day: 'numeric' })}</small></span><span class="grow">${esc(e.text)}</span></div>`).join('')}</div>`;
    }
    const stopped = ['paused', 'completed', 'error', 'off'].includes(d.state);
    const frac = d.progress || 0;
    const line = d.state === 'downloading' || d.state === 'stalled'
      ? `${size(d.done)} of ${size(d.size)} · ${speed(d.down)}${d.eta > 0 ? ' · ' + time(d.eta) + ' left' : ''}`
      : d.state === 'metadata' ? 'Asking other people for the list of files…' : d.state === 'checking' ? 'Checking what’s already on disk…'
      : `${size(d.done)} of ${size(d.size)}`;
    const main = d.state === 'off' ? '' : d.state === 'completed' ? (adv() ? pbtn('seed', 'seed', 'Seed') : '') : stopped ? pbtn('resume', 'play', 'Resume') : pbtn('pause', 'pause', 'Pause');
    const buttons = main + pbtn('open', 'open', 'Open') + pbtn('reveal', 'folder', 'Show in Finder') + pbtn('copyMagnet', 'link', 'Copy Magnet') + pbtn('remove', 'x', 'Remove', 'danger');
    const top = hero(d, frac, d.error || stateLabel[d.state], line, buttons);
    // The piece map: torrents arrive in small pieces, in any order, from many people at once.
    const pieces = d.pieceCount ? section('Pieces', `<div class="plate pad"><canvas id="pieces" width="1200" height="40"></canvas>
      <div class="legend"><span><i class="sw on"></i>Downloaded</span><span><i class="sw busy"></i>On its way</span><span><i class="sw"></i>Not yet</span>
      <span class="right">${(d.havePieces ?? 0).toLocaleString()} of ${d.pieceCount.toLocaleString()} pieces${adv() ? ` · ${size(d.pieceSize)} each` : ''}</span></div></div>`) : '';
    const people = d.seeds + d.peers;
    if (!adv()) {
      return top + `<div class="tiles">${tile('Downloaded', size(d.done), `of ${size(d.size)}`)}${tile('Speed', d.state === 'downloading' ? speed(d.down) : '—')}${tile('Time left', d.eta > 0 && d.state === 'downloading' ? time(d.eta) : '—')}${tile('Downloading from', people, people === 1 ? 'person' : 'people')}</div>`
        + pieces + section('Details', plateRows([['Saved to', d.path, 1], ['Added', date(d.added)], ['Finished', d.completed ? date(d.completed) : '']]));
    }
    const toggle = (key, label, help) => `<label class="opt-row"><span><b>${label}</b><small>${help}</small></span><input type="checkbox" data-toggle="${key}"${d[key] ? ' checked' : ''}></label>`;
    const limit = (key, label, v) => `<label class="opt-row"><span><b>${label}</b><small>KB/s · 0 for no limit</small></span><input class="mini" type="number" min="0" data-limit="${key}" value="${Math.round((v || 0) / 1000)}"></label>`;
    return top
      + `<div class="tiles">${tile('Downloaded', size(d.downloaded))}${tile('Uploaded', size(d.uploaded), 'ratio ' + (d.ratio || 0).toFixed(2))}${tile('Download', speed(d.down))}${tile('Upload', speed(d.up))}
        ${tile('Seeds', d.seeds, d.swarmSeeds >= 0 ? `${d.swarmSeeds} in swarm` : '')}${tile('Peers', d.peers, d.swarmPeers >= 0 ? `${d.swarmPeers} in swarm` : '')}</div>`
      + pieces + `<div class="actions2">${pbtn('forceStart', 'bolt', 'Force Start')}${pbtn('recheck', 'check', 'Check Files')}${pbtn('reannounce', 'broadcast', 'Ask for Peers')}${pbtn('export', 'export', 'Export .torrent')}${pbtn('move', 'move', 'Move…')}${pbtn('rename', 'pencil', 'Rename…')}</div>`
      + `<div class="cols">`
      + section('Options', `<div class="plate kvs">${toggle('sequential', 'Download in order', 'Pieces arrive start to finish')}${toggle('firstLast', 'First and last pieces first', 'Lets media players read the file sooner')}${toggle('superSeed', 'Super-seeding', 'Hand out rare pieces one at a time while seeding')}${limit('down', 'Download limit', d.downloadLimit)}${limit('up', 'Upload limit', d.uploadLimit)}</div>`)
      + section('Torrent', plateRows([
        ['Size', size(d.size) + (d.total > d.size ? ` (of ${size(d.total)})` : '')], ['Pieces', d.pieceCount ? `${d.havePieces} of ${d.pieceCount} × ${size(d.pieceSize)}` : ''],
        ['Availability', d.availability ? d.availability.toFixed(2) : ''], ['Wasted', size(d.wasted)], ['Version', d.version || ''],
        ['Private', d.private ? 'Yes: no DHT, peer exchange or local discovery' : d.private === false ? 'No' : ''],
        ['Created', d.created ? date(d.created) : ''], ['Created by', d.createdBy || ''], ['Comment', d.comment || ''],
      ]))
      + section('History', plateRows([
        ['Added', date(d.added)], ['Completed', d.completed ? date(d.completed) : ''], ['Active for', time(d.active)], ['Seeded for', d.seeding ? time(d.seeding) : ''],
        ['Saved to', d.path, 1], ['Info hash', d.hashV2 && d.version === 'v2' ? '' : d.hash, 1], ['Info hash v2', d.hashV2 || '', 1],
      ]))
      + `</div>`;
  }

  function drawPieces(d) {
    const c = $('pieces'); if (!c || !d.pieces) return;
    const ctx = c.getContext('2d'); const w = c.width, h = c.height, n = d.pieces.length;
    const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
    ctx.clearRect(0, 0, w, h);
    for (let i = 0; i < n; i++) {
      const ch = d.pieces[i];
      if (ch === '0') continue;
      ctx.fillStyle = accent;
      ctx.globalAlpha = ch === 'd' ? .3 : (Number(ch) + 1) / 10;
      ctx.fillRect(Math.floor(i * w / n), 0, Math.ceil(w / n), h);
    }
    ctx.globalAlpha = 1;
  }

  // Menus
  function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; } }
  function showMenu(d, x, y) {
    closeMenu();
    // [action, title, icon, danger]; the second list's advanced-only rows are left out of the simple menu.
    const a = adv(), off = d.state === 'off';
    const items = d.kind === 'http' ? [
      d.state === 'running' ? ['pause', 'Pause', 'pause'] : d.resumable && d.state !== 'finished' ? ['resume', d.state === 'failed' ? 'Try Again' : 'Resume', d.state === 'failed' ? 'retry' : 'play'] : null,
      d.state === 'finished' ? ['open', 'Open', 'open'] : null, d.state === 'finished' ? ['reveal', 'Show in Finder', 'folder'] : null, '-',
      ['copy', 'Copy Address', 'copy'], ['again', 'Download Again', 'retry'], '-',
      d.state === 'running' ? ['stop', 'Stop', 'stop'] : null, ['remove', 'Remove from List', 'x'], d.state === 'finished' ? ['removeFile', 'Move File to Trash', 'trash', 1] : null,
    ] : [
      off ? null : ['paused', 'error'].includes(d.state) ? ['resume', 'Resume', 'play'] : d.state === 'completed' ? (a ? ['seed', 'Seed', 'seed'] : null) : ['pause', 'Pause', 'pause'],
      a && !off ? ['forceStart', 'Force Start', 'bolt'] : null, ['open', 'Open', 'open'], ['reveal', 'Show in Finder', 'folder'], '-',
      ['copyMagnet', 'Copy Magnet Link', 'link'], a ? ['export', 'Export .torrent…', 'export'] : null, a ? ['recheck', 'Check Files', 'check'] : null,
      a && !off ? ['reannounce', 'Ask for More Peers', 'broadcast'] : null, ['move', 'Move Files…', 'move'], ['rename', 'Rename…', 'pencil'],
      a ? '-' : null, a ? ['queueTop', 'Move to Top of Queue', 'top'] : null, a ? ['queueUp', 'Move Up in Queue', 'arrowUp'] : null,
      a ? ['queueDown', 'Move Down in Queue', 'arrowDown'] : null, a ? ['queueBottom', 'Move to Bottom of Queue', 'bottom'] : null, '-',
      ['remove', 'Remove', 'x'], ['removeWithFiles', 'Remove and Trash Files', 'trash', 1],
    ];
    menuEl = document.createElement('div');
    menuEl.className = 'menu';
    const rows = items.filter(Boolean).filter((i, n, all) => i !== '-' || (n > 0 && all[n - 1] !== '-' && n < all.length - 1));
    menuEl.innerHTML = rows.map((i) => i === '-' ? '<hr>' : `<button data-act="${i[0]}"${i[3] ? ' class="danger"' : ''}>${icon(i[2], 14)}${i[1]}</button>`).join('');
    document.body.appendChild(menuEl);
    const r = menuEl.getBoundingClientRect();
    menuEl.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
    menuEl.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
    menuEl.onclick = (e) => { const b = e.target.closest('button'); if (b) { closeMenu(); act(d, b.dataset.act, b); } };
  }

  // Actions
  async function act(d, a, el) {
    if (!d) return;
    if (a === 'menu') { const r = el.getBoundingClientRect(); showMenu(d, r.left - 170, r.bottom + 4); return; }
    if (a === 'closeDetail') { sel = null; draw(); return; }
    if (d.kind === 'http') {
      if (a === 'checksum') {
        const kind = $('sumKind').value, expected = $('sumExpected').value.trim().toLowerCase();
        $('sumOut').textContent = 'Calculating…';
        busy = true;
        try {
          const sum = await send('dl.http', { id: d.id, action: 'checksum', hash: kind });
          $('sumOut').innerHTML = esc(sum) + (expected ? (expected === sum ? ' <span class="chip good">Matches</span>' : ' <span class="chip warn">Doesn’t match</span>') : '');
        } finally { busy = false; }
        return;
      }
      await send('dl.http', { id: d.id, action: a === 'removeFile' ? 'removeFile' : a });
      if (a === 'remove' || a === 'removeFile') sel = null;
      if (a === 'copy') toast('Copied the address');
      return refresh();
    }
    const base = { id: d.id };
    switch (a) {
      case 'remove': await send('dl.torrent', { ...base, action: 'remove' }); sel = null; break;
      case 'removeWithFiles': if (await send('dl.torrent', { ...base, action: 'removeWithFiles' })) sel = null; break;
      case 'copyMagnet': await send('dl.torrent', { ...base, action: 'copyMagnet' }); toast('Copied the magnet link'); break;
      case 'stream': await send('dl.torrent', { ...base, action: 'stream', file: Number(el.dataset.file) }); toast('Downloading the start of that file first'); break;
      case 'openFile': await send('dl.torrent', { ...base, action: 'openFile', path: el.dataset.path }); break;
      case 'revealFile': await send('dl.torrent', { ...base, action: 'reveal', path: el.dataset.path }); break;
      case 'renameFile': await send('dl.torrent', { ...base, action: 'rename', file: Number(el.dataset.file), current: el.dataset.name }); break;
      case 'filesAll': case 'filesNone': {
        const changes = {}; (data.detail?.files || []).forEach((f) => { changes[f.i] = a === 'filesAll' ? Math.max(1, f.priority) : 0; });
        await send('dl.torrent', { ...base, action: 'files', changes }); break;
      }
      case 'addPeer': await send('dl.torrent', { ...base, action: 'addPeer', addr: $('peerAddr').value.trim() }); toast('Connecting…'); break;
      case 'addTrackers': await send('dl.torrent', { ...base, action: 'addTrackers', text: $('newTrackers').value }); break;
      case 'removeTracker': await send('dl.torrent', { ...base, action: 'removeTracker', url: el.dataset.url }); break;
      default: await send('dl.torrent', { ...base, action: a });
    }
    refresh();
  }

  // Sheets
  function sheet(kindName, html, onConfirm) {
    sheetKind = kindName;
    $('sheet').innerHTML = html;
    $('shade').hidden = false;
    paintIcons($('sheet'));
    const first = kindName === 'settings' ? null : $('sheet').querySelector('textarea, input[type=text]');
    if (first) setTimeout(() => first.focus(), 30);
    $('sheet').onclick = async (e) => {
      const b = e.target.closest('[data-sheet]');
      if (!b) return;
      if (b.dataset.sheet === 'cancel') return closeSheet(true);
      if (b.dataset.sheet === 'ok') { b.disabled = true; try { if (await onConfirm() !== false) closeSheet(); } catch { } finally { b.disabled = false; } }
      if (b.dataset.sheet === 'folder') { const p = await send('dl.chooseFolder'); if (p) $('sheet').querySelector('[data-path]').value = p; }
      if (b.dataset.sheet === 'source') { const p = await send(b.dataset.file ? 'dl.chooseFile' : 'dl.chooseSource'); if (p) $('srcPath').value = p; }
    };
  }
  function closeSheet(cancelled) {
    if (cancelled && sheetKind === 'pending' && shownPending) send('dl.pending', { token: shownPending, add: false });
    if (sheetKind === 'pending') shownPending = null;
    sheetKind = null;
    $('shade').hidden = true;
    $('sheet').innerHTML = '';
    refresh();
  }
  const foot = (label, destructive) => `<div class="foot"><button class="pill" data-sheet="cancel">Cancel <kbd>Esc</kbd></button><button class="pill primary" data-sheet="ok">${label} <kbd>${destructive ? '⌘↩' : '↩'}</kbd></button></div>`;

  function openAdd(prefill = '') {
    sheet('add', `<h2>Add a Download</h2><div class="sub">Web addresses download with several connections when the server allows it. Magnet links and .torrent addresses open as torrents.</div>
      <div class="body"><div class="field"><span>Addresses or magnet links, one per line</span><textarea id="addText" placeholder="https://… or magnet:?xt=…">${esc(prefill)}</textarea></div>
      <button class="pill" id="addOpenTorrent">Open Torrent File…</button></div>${foot('Download')}`, async () => {
      const n = await send('dl.add', { text: $('addText').value });
      if (n) toast(n === 1 ? 'Added 1 download' : `Added ${n} downloads`);
      return n > 0;
    });
    $('addOpenTorrent').onclick = async () => { closeSheet(); await send('dl.openTorrent'); refresh(); };
  }

  function openPending(p) {
    shownPending = p.token;
    const files = p.files || [];
    sheet('pending', `<h2>Add Torrent</h2><div class="sub" title="${esc(p.name)}">${esc(p.name)}${p.size ? ' · ' + size(p.size) : ''}${p.version ? ' · ' + p.version : ''}${p.private ? ' · private' : ''}</div>
      <div class="body">
        ${p.magnet ? '<p class="note">This is a magnet link: the file list arrives from peers once it starts. You can pick files in its Files tab then.</p>' : `
        <div class="controls"><button class="pill" id="pickAll">Select All</button><button class="pill" id="pickNone">Select None</button><span class="note" id="pickSize" style="margin:0"></span></div>
        <div class="files">${files.map((f) => `<label><input type="checkbox" data-pick="${f.i}"${f.on ? ' checked' : ''}><span title="${esc(f.path)}">${esc(f.path)}</span><span>${size(f.size)}</span></label>`).join('')}</div>`}
        ${p.comment ? `<p class="note">${esc(p.comment)}</p>` : ''}
        <div class="field"><span>Save to</span><div class="pathrow"><input type="text" data-path value="${esc(p.path)}"><button class="pill" data-sheet="folder">Choose…</button></div></div>
        <div class="controls"><label class="check"><input type="checkbox" id="pPaused">Don’t start yet</label>
        <label class="check"><input type="checkbox" id="pSeq">Download in order</label><label class="check"><input type="checkbox" id="pFL">First and last pieces first</label></div>
      </div>${foot('Add Torrent')}`, async () => {
      const picked = [...document.querySelectorAll('[data-pick]')].filter((c) => c.checked).map((c) => Number(c.dataset.pick));
      if (!p.magnet && files.length && !picked.length) { toast('Pick at least one file'); return false; }
      await send('dl.pending', { token: p.token, add: true, path: $('sheet').querySelector('[data-path]').value, paused: $('pPaused').checked, sequential: $('pSeq').checked, firstLast: $('pFL').checked, files: p.magnet ? undefined : picked });
      shownPending = null;
    });
    const total = () => { const on = new Set([...document.querySelectorAll('[data-pick]')].filter((c) => c.checked).map((c) => Number(c.dataset.pick))); const s = files.filter((f) => on.has(f.i)).reduce((a, f) => a + f.size, 0); const e = $('pickSize'); if (e) e.textContent = `${on.size} of ${files.length} files · ${size(s)}`; };
    document.querySelectorAll('[data-pick]').forEach((c) => c.onchange = total);
    if ($('pickAll')) { $('pickAll').onclick = () => { document.querySelectorAll('[data-pick]').forEach((c) => c.checked = true); total(); }; $('pickNone').onclick = () => { document.querySelectorAll('[data-pick]').forEach((c) => c.checked = false); total(); }; total(); }
  }

  function openCreate() {
    sheet('create', `<h2>Create a Torrent</h2><div class="sub">Share a file or folder. Hybrid torrents work with every client, old and new.</div><div class="body">
      <div class="field"><span>File or folder</span><div class="pathrow"><input type="text" id="srcPath" placeholder="Choose what to share"><button class="pill" data-sheet="source">Folder…</button><button class="pill" data-sheet="source" data-file="1">File…</button></div></div>
      <div class="controls"><label class="check">Format <select class="mini" id="cFormat"><option value="3">Hybrid (v1 + v2)</option><option value="1">v1</option><option value="2">v2</option></select></label>
      <label class="check">Piece size <select class="mini" id="cPiece"><option value="0">Automatic</option>${[16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384].map((k) => `<option value="${k * 1024}">${k >= 1024 ? k / 1024 + ' MB' : k + ' KB'}</option>`).join('')}</select></label>
      <label class="check"><input type="checkbox" id="cPrivate">Private</label><label class="check"><input type="checkbox" id="cSeed" checked>Start seeding</label></div>
      <div class="field"><span>Trackers (one per line; a blank line starts a new tier)</span><textarea id="cTrackers"></textarea></div>
      <div class="field"><span>Web seeds (one per line)</span><textarea id="cSeeds" style="height:52px"></textarea></div>
      <div class="field"><span>Comment</span><input type="text" id="cComment"></div><div class="field"><span>Source tag</span><input type="text" id="cSource"></div>
      </div>${foot('Create…')}`, async () => {
      toast('Hashing… this can take a while for big folders');
      return await send('dl.create', { path: $('srcPath').value, format: Number($('cFormat').value), pieceLength: Number($('cPiece').value), private: $('cPrivate').checked, seed: $('cSeed').checked, trackers: $('cTrackers').value, webSeeds: $('cSeeds').value, comment: $('cComment').value, source: $('cSource').value }) !== false;
    });
  }

  async function openSettings() {
    const s = await send('dl.settings');
    const t = s.torrent, h = s.http, a = adv();
    const kb = (v) => Math.round((v || 0) / 1000);
    const opt = (label, help, control) => `<div class="opt"><div>${label}${help ? `<small>${help}</small>` : ''}</div>${control}</div>`;
    const num = (scope, key, v, scale = 1) => `<input type="number" min="0" data-scope="${scope}" data-key="${key}" data-scale="${scale}" value="${scale === 1000 ? kb(v) : v}">`;
    const chk = (scope, key, v) => `<input type="checkbox" data-scope="${scope}" data-key="${key}"${v ? ' checked' : ''}>`;
    const txt = (scope, key, v, ph = '') => `<input type="text" data-scope="${scope}" data-key="${key}" value="${esc(v)}" placeholder="${ph}">`;
    const sel = (scope, key, v, opts) => `<select data-scope="${scope}" data-key="${key}">${opts.map(([val, l]) => `<option value="${val}"${v == val ? ' selected' : ''}>${l}</option>`).join('')}</select>`;
    sheet('settings', `<h2>Download Settings</h2><div class="sub">Changes apply straight away.</div><div class="body settings">
      <section><h4>General</h4>
        ${opt('Save files to', '', `<div class="pathrow" style="width:300px"><input type="text" data-path data-scope="torrent" data-key="folder" value="${esc(s.folder)}"><button class="pill" data-sheet="folder">Choose…</button></div>`)}
      </section>
      <section><h4>Web downloads</h4>
        ${opt('Use several connections', 'Big files from servers that allow it download in parallel, much faster.', chk('http', 'turbo', h.turbo))}
        ${a ? opt('Connections per download', '1–32', num('http', 'connections', h.connections)) : ''}
        ${a ? opt('Downloads at once', 'The rest wait in a queue.', num('http', 'maxActive', h.maxActive)) : ''}
        ${opt('Speed limit (KB/s)', '0 means no limit', num('http', 'speedLimit', h.speedLimit, 1000))}
        ${data.torrentsEnabled ? opt('Open .torrent files in Tuff', 'Torrent files you download become torrents here.', chk('http', 'openTorrents', h.openTorrents)) : ''}
      </section>
      ${data.torrentsEnabled && !a ? `<section><h4>Torrents</h4>
        ${opt('Share while downloading', 'Off: Tuff only downloads. On: others can get pieces from you, which some of them reward with more speed.', chk('torrent', 'uploadWhileDownloading', t.uploadWhileDownloading))}
        ${opt('Keep sharing after downloading', 'Off: a torrent stops once it has finished.', chk('torrent', 'seedAfterDownload', t.seedAfterDownload))}
        ${opt('Download limit (KB/s)', '0 means no limit', num('torrent', 'downloadLimit', t.downloadLimit, 1000))}
        ${t.uploadWhileDownloading || t.seedAfterDownload ? opt('Upload limit (KB/s)', '0 means no limit', num('torrent', 'uploadLimit', t.uploadLimit, 1000)) : ''}
      </section>` : ''}
      ${a ? `<section><h4>Torrents: sharing</h4>
        ${opt('Share while downloading', 'Off: nothing is uploaded until a torrent finishes (and then only if it seeds).', chk('torrent', 'uploadWhileDownloading', t.uploadWhileDownloading))}
        ${opt('Keep sharing after downloading', 'Off: a torrent stops once it has finished. Choose Seed on one to share it anyway.', chk('torrent', 'seedAfterDownload', t.seedAfterDownload))}
        ${opt('Stop at share ratio', '0 means no limit', `<input type="number" min="0" step="0.1" data-scope="torrent" data-key="ratioLimit" data-float="1" value="${t.ratioLimit}">`)}
        ${opt('Stop after seeding for (minutes)', '0 means no limit', num('torrent', 'seedTimeLimit', t.seedTimeLimit))}
        ${opt('Stop when nobody downloads for (minutes)', '0 means no limit', num('torrent', 'inactiveSeedLimit', t.inactiveSeedLimit))}
        ${opt('Upload slots per torrent', '', num('torrent', 'uploadSlots', t.uploadSlots))}
        ${opt('Seeding strategy', '', sel('torrent', 'seedStrategy', t.seedStrategy, [[0, 'Fastest upload'], [1, 'Round robin'], [2, 'Anti-leech']]))}
      </section>
      <section><h4>Torrents: speed and queue</h4>
        ${opt('Download limit (KB/s)', '0 means no limit', num('torrent', 'downloadLimit', t.downloadLimit, 1000))}
        ${opt('Upload limit (KB/s)', '0 means no limit', num('torrent', 'uploadLimit', t.uploadLimit, 1000))}
        ${opt('No limits for peers on this network', '', chk('torrent', 'lanUnlimited', t.lanUnlimited))}
        ${opt('Active downloads', 'Others queue; 0 means no limit', num('torrent', 'maxActiveDownloads', t.maxActiveDownloads))}
        ${opt('Active seeds', '0 means no limit', num('torrent', 'maxActiveSeeds', t.maxActiveSeeds))}
      </section>
      <section><h4>Torrents: connections</h4>
        ${opt('Listening port', 'Peers connect to this port (TCP and UDP).', num('torrent', 'port', t.port))}
        ${opt('New random port each launch', '', chk('torrent', 'randomPort', t.randomPort))}
        ${opt('Open the port on the router', 'UPnP, NAT-PMP and PCP.', chk('torrent', 'portMapping', t.portMapping))}
        ${opt('µTP', 'Uses UDP and backs off when other traffic needs the line.', chk('torrent', 'utp', t.utp))}
        ${opt('TCP', '', chk('torrent', 'tcp', t.tcp))}
        ${opt('Encryption', '', sel('torrent', 'encryption', t.encryption, [[1, 'Prefer encrypted'], [2, 'Require encryption'], [0, 'Off']]))}
        ${opt('Peers in total', '', num('torrent', 'maxPeers', t.maxPeers))}
        ${opt('Peers per torrent', '', num('torrent', 'maxPeersPerTorrent', t.maxPeersPerTorrent))}
        ${opt('Connection attempts at once', '', num('torrent', 'maxHalfOpen', t.maxHalfOpen))}
        ${opt('Network interface', 'Like en0 or utun3; empty for any.', txt('torrent', 'bindInterface', t.bindInterface, 'Any'))}
      </section>
      <section><h4>Torrents: finding peers</h4>
        ${opt('DHT', 'Find peers without a tracker.', chk('torrent', 'dht', t.dht))}
        ${opt('Peer exchange', '', chk('torrent', 'pex', t.pex))}
        ${opt('Local peer discovery', 'Find peers on this network.', chk('torrent', 'lsd', t.lsd))}
        ${opt('Announce to every tracker in a tier', '', chk('torrent', 'announceToAllTrackers', t.announceToAllTrackers))}
        ${opt('Announce to every tier', '', chk('torrent', 'announceToAllTiers', t.announceToAllTiers))}
      </section>
      <section><h4>Torrents: disk</h4>
        ${opt('Allocate whole files up front', 'Less fragmentation, uses the space at once.', chk('torrent', 'preallocate', t.preallocate))}
        ${opt('Keep skipped files’ pieces in a hidden .parts file', '', chk('torrent', 'partFile', t.partFile))}
        ${opt('Add “.part” to unfinished files', '', chk('torrent', 'incompleteSuffix', t.incompleteSuffix))}
        ${opt('Memory for disk buffers (MB)', '', num('torrent', 'diskCacheMB', t.diskCacheMB))}
      </section>
      <section><h4>Torrents: proxy</h4>
        ${opt('Proxy', '', sel('torrent', 'proxyType', t.proxyType, [[0, 'None'], [1, 'SOCKS5'], [2, 'HTTP']]))}
        ${opt('Server', '', txt('torrent', 'proxyHost', t.proxyHost, 'proxy.example.com'))}
        ${opt('Port', '', num('torrent', 'proxyPort', t.proxyPort))}
        ${opt('User name', '', txt('torrent', 'proxyUser', t.proxyUser))}
        ${opt('Password', '', `<input type="password" data-scope="torrent" data-key="proxyPassword" value="${esc(t.proxyPassword)}">`)}
        ${opt('Use for peers', '', chk('torrent', 'proxyPeers', t.proxyPeers))}
        ${opt('Use for trackers and web seeds', '', chk('torrent', 'proxyTrackers', t.proxyTrackers))}
        ${opt('Only through the proxy', 'Turns off µTP, DHT and local discovery, which can’t use it.', chk('torrent', 'proxyOnly', t.proxyOnly))}
      </section>
      <section><h4>Torrents: IP filter</h4>
        ${opt('Block addresses in a list', 'PeerGuardian (.p2p), eMule (.dat) or CIDR lines.', chk('torrent', 'ipFilterEnabled', t.ipFilterEnabled))}
        ${opt('Filter file', '', `<div class="pathrow" style="width:300px"><input type="text" id="filterPath" data-scope="torrent" data-key="ipFilterPath" value="${esc(t.ipFilterPath)}"><button class="pill" id="chooseFilter">Choose…</button></div>`)}
      </section>` : ''}
    </div><div class="foot"><button class="pill primary" data-sheet="cancel">Done <kbd>↩</kbd></button></div>`, () => true);
    $('sheet').onchange = (e) => {
      const el = e.target; if (!el.dataset.key) return;
      let value = el.type === 'checkbox' ? el.checked : el.type === 'number' ? (el.dataset.float ? parseFloat(el.value) || 0 : Math.round((parseFloat(el.value) || 0) * Number(el.dataset.scale || 1))) : el.value;
      if (el.tagName === 'SELECT') value = Number(el.value);
      send('dl.setting', { scope: el.dataset.scope, key: el.dataset.key, value });
    };
    const folderInput = $('sheet').querySelector('[data-key=folder]');
    $('sheet').addEventListener('click', async (e) => {
      if (e.target.closest('#chooseFilter')) { const p = await send('dl.chooseFile'); if (p) { $('filterPath').value = p; send('dl.setting', { scope: 'torrent', key: 'ipFilterPath', value: p }); } }
      if (e.target.closest('[data-sheet=folder]')) setTimeout(() => send('dl.setting', { scope: 'torrent', key: 'folder', value: folderInput.value }), 400);
    });
  }

  // Events
  $('views').onclick = (e) => { const b = e.target.closest('[data-view]'); if (!b) return; view = b.dataset.view; kind = ''; try { localStorage.setItem('dl.view', view); } catch {} draw(); };
  $('kinds').onclick = (e) => { const b = e.target.closest('[data-kind]'); if (!b) return; kind = kind === b.dataset.kind ? '' : b.dataset.kind; draw(); };
  $('q').oninput = () => { query = $('q').value.trim(); draw(); };
  $('sort').onchange = draw;
  $('addBtn').onclick = () => openAdd();
  $('advancedSwitch').onclick = async () => {
    data.advanced = !data.advanced;
    await send('dl.setting', { scope: 'http', key: 'advanced', value: data.advanced });
    draw();
  };
  $('torrentSwitch').onclick = async () => {
    const on = !data.torrentsEnabled;
    data.torrentsEnabled = await send('dl.torrents', { enabled: on });
    drawHeader();
    toast(data.torrentsEnabled ? 'Torrents on: magnet links and torrent files download here' : 'Torrents off: nothing is shared or downloaded');
    refresh();
  };
  $('openBtn').onclick = async () => { await send('dl.openTorrent'); refresh(); };
  $('createBtn').onclick = openCreate;
  $('settingsBtn').onclick = openSettings;
  $('pauseAll').onclick = async () => { await send('dl.pauseAll'); refresh(); };
  $('resumeAll').onclick = async () => { await send('dl.resumeAll'); refresh(); };
  $('clear').onclick = async () => { await send('dl.clear'); refresh(); };
  $('list').onclick = (e) => {
    const row = e.target.closest('.row'); if (!row) return;
    const d = find(row.dataset.id);
    const b = e.target.closest('[data-act]');
    if (b) { act(d, b.dataset.act, b); return; }
    sel = row.dataset.id; draw(); refresh();
  };
  $('list').ondblclick = (e) => { const row = e.target.closest('.row'); const d = row && find(row.dataset.id); if (d && !e.target.closest('[data-act]')) act(d, 'open'); };
  $('list').oncontextmenu = (e) => { const row = e.target.closest('.row'); if (!row) return; e.preventDefault(); sel = row.dataset.id; draw(); showMenu(find(sel), e.clientX, e.clientY); };
  $('tabs').onclick = (e) => { const b = e.target.closest('[data-tab]'); if (b) { tab = b.dataset.tab; busy = false; drawDetail(); refresh(); } else { const c = e.target.closest('[data-act]'); if (c) act(find(sel), c.dataset.act, c); } };
  $('pane').onclick = (e) => { const b = e.target.closest('[data-act]'); if (b) act(find(sel), b.dataset.act, b); };
  $('pane').onchange = (e) => {
    const el = e.target, d = find(sel); if (!d) return;
    if (el.dataset.want !== undefined) {
      send('dl.torrent', { id: d.id, action: 'files', changes: { [el.dataset.want]: el.checked ? Math.max(1, Number(el.dataset.priority) || 1) : 0 } }).then(refresh);
      el.closest('.frow')?.classList.toggle('skipped', !el.checked);
    }
    if (el.dataset.file !== undefined && el.tagName === 'SELECT') send('dl.torrent', { id: d.id, action: 'files', changes: { [el.dataset.file]: Number(el.value) } });
    if (el.dataset.toggle) send('dl.torrent', { id: d.id, action: el.dataset.toggle, value: el.checked });
    if (el.dataset.limit) send('dl.torrent', { id: d.id, action: 'limits', [el.dataset.limit]: Math.round((parseFloat(el.value) || 0) * 1000) });
  };
  // While something in the panel has focus, it isn't redrawn under the pointer.
  $('pane').addEventListener('focusin', () => { busy = true; });
  $('pane').addEventListener('focusout', () => { setTimeout(() => { busy = $('pane').contains(document.activeElement); }, 0); });
  document.addEventListener('click', (e) => { if (menuEl && !menuEl.contains(e.target)) closeMenu(); }, true);
  $('shade').onclick = (e) => { if (e.target === $('shade')) closeSheet(true); };

  document.addEventListener('keydown', (e) => {
    const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName);
    if (!$('shade').hidden) {
      if (e.key === 'Escape') { e.preventDefault(); closeSheet(true); }
      if (e.key === 'Enter' && (!typing || e.metaKey || document.activeElement.tagName === 'INPUT') && !(document.activeElement.tagName === 'TEXTAREA' && !e.metaKey)) {
        e.preventDefault(); $('sheet').querySelector('[data-sheet=ok], .foot .primary')?.click();
      }
      return;
    }
    if (e.key === 'Escape') { if (menuEl) closeMenu(); else if (typing) document.activeElement.blur(); else { sel = null; draw(); } return; }
    if (typing) return;
    if (e.key === '/') { e.preventDefault(); $('q').focus(); return; }
    const list = visible(), i = list.findIndex((d) => d.id === sel);
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const n = list[Math.max(0, Math.min(list.length - 1, i + (e.key === 'ArrowDown' ? 1 : -1)))];
      if (n) { sel = n.id; draw(); rowCache.get(sel)?.scrollIntoView({ block: 'nearest' }); refresh(); }
      return;
    }
    const d = list[i]; if (!d) return;
    if (e.key === ' ') { e.preventDefault(); act(d, ['running', 'downloading', 'seeding', 'stalled', 'metadata', 'queued'].includes(d.state) ? 'pause' : d.state === 'completed' ? 'seed' : 'resume'); }
    if (e.key === 'Enter') act(d, 'open');
    if (e.key === 'Backspace' || e.key === 'Delete') act(d, e.metaKey ? (d.kind === 'http' ? 'removeFile' : 'removeWithFiles') : 'remove');
  });

  // Drag and drop: .torrent files, magnet links and addresses.
  let dragDepth = 0;
  document.addEventListener('dragenter', (e) => { e.preventDefault(); if (++dragDepth === 1) document.body.classList.add('dragging'); });
  document.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('dragging'); } });
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', async (e) => {
    e.preventDefault(); dragDepth = 0; document.body.classList.remove('dragging');
    const text = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
    if (text) { openAdd(text.split(/\r?\n/).filter((l) => l && !l.startsWith('#')).join('\n')); return; }
    if (e.dataTransfer.files.length) toast('Use Open Torrent File… to pick torrent files from Finder');
  });
  document.addEventListener('paste', (e) => {
    if (/INPUT|TEXTAREA/.test(document.activeElement?.tagName) || !$('shade').hidden) return;
    const text = e.clipboardData.getData('text/plain').trim();
    if (/^(magnet:|https?:\/\/)/i.test(text)) { e.preventDefault(); openAdd(text); }
  });

  // Drawing and polling
  function draw() { drawSidebar(); drawHeader(); drawList(); drawDetail(); }
  let timer = null, inflight = false;
  async function refresh() {
    if (inflight) return;
    inflight = true;
    try {
      data = await send('dl.state', { detail: sel || '' }, 2);
      draw();
      if (!sheetKind && data.pending?.length && shownPending !== data.pending[0].token) openPending(data.pending[0]);
    } catch {} finally { inflight = false; }
  }
  function loop() { clearTimeout(timer); if (!document.hidden) refresh(); timer = setTimeout(loop, 1000); }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) loop(); });
  loop();
})();
</script>
</body></html>
"""#
}
