/* Breaths: a private breathing-rate log for a cat with heart disease.
   Everything is stored on this device (localStorage). Nothing is uploaded. */
'use strict';

(() => {
  const APP_VERSION = '1.1';
  const STORE_KEY = 'breaths.readings.v1';
  const SETTINGS_KEY = 'breaths.settings.v1';
  const COUNT_MS = 60000;
  const DAY_MS = 86400000;
  const RING_C = 2 * Math.PI * 92;

  const STATES = {
    asleep: { label: 'Asleep', short: 'Asleep', csv: 'asleep' },
    half: { label: 'Half-asleep', short: 'Half', csv: 'half-asleep' },
    awake: { label: 'Awake', short: 'Awake', csv: 'awake' },
  };
  const STATE_ORDER = ['asleep', 'half', 'awake'];
  const DRAW_ORDER = ['awake', 'half', 'asleep']; // asleep is drawn last, on top
  const STATE_OPTIONS = STATE_ORDER.map(s => ({ value: s, label: STATES[s].label, state: s }));
  const RANGES = [
    { value: '7', label: '7 days', days: 7 },
    { value: '30', label: '30 days', days: 30 },
    { value: '90', label: '90 days', days: 90 },
    { value: 'all', label: 'All', days: 0 },
  ];
  const VIEW_TITLES = { count: 'Count breaths', log: 'Log', trends: 'Trends', more: 'Settings & data' };
  const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MO = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const MONTHS = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11 };

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  function h(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  const SVG_NS = 'http://www.w3.org/2000/svg';
  function svgEl(tag, attrs, parent) {
    const e = document.createElementNS(SVG_NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.append(e);
    return e;
  }

  // ---------- Storage ----------
  function load(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : fallback;
    } catch {
      return fallback;
    }
  }
  function store(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
      return true;
    } catch {
      toast('Couldn’t save: storage is unavailable');
      return false;
    }
  }

  let readings = load(STORE_KEY, []);
  if (!Array.isArray(readings)) readings = [];
  readings = readings.filter(r => r && Number.isFinite(r.t) && STATES[r.state] && r.bpm > 0);
  readings.sort((a, b) => a.t - b.t);

  const settings = Object.assign(
    { name: 'BB', alert: 30, theme: 'auto', countState: 'asleep', range: '30', logFilter: 'all', lastExport: 0, hideInstall: false, backupSnooze: 0 },
    load(SETTINGS_KEY, {}),
  );
  // Number of changes (adds, edits, deletes) since the last backup.
  if (!Number.isFinite(settings.unsaved)) settings.unsaved = settings.lastExport ? 0 : readings.length;
  const saveSettings = () => store(SETTINGS_KEY, settings);

  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2));

  function persist() {
    readings.sort((a, b) => a.t - b.t);
    store(STORE_KEY, readings);
    // Ask the browser not to evict our data under storage pressure.
    try { if (navigator.storage && navigator.storage.persist) navigator.storage.persist(); } catch { /* not supported */ }
  }
  function addReadings(list, alreadyBackedUp) {
    for (const r of list) readings.push({ id: uid(), t: r.t, state: r.state, bpm: r.bpm, note: r.note || '' });
    persist();
    if (!alreadyBackedUp) markChanged(list.length);
  }
  function markChanged(n) {
    settings.unsaved += n;
    saveSettings();
  }
  const isOverAlert = (state, bpm) => state !== 'awake' && bpm > settings.alert;

  // ---------- Dates ----------
  const pad2 = n => String(n).padStart(2, '0');
  const fmtTime = t => { const d = new Date(t); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`; };
  function fmtDay(t, withYear) {
    const d = new Date(t);
    return `${WD[d.getDay()]} ${d.getDate()} ${MO[d.getMonth()]}${withYear ? ' ' + d.getFullYear() : ''}`;
  }
  const dayKey = t => { const d = new Date(t); return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate(); };
  const startOfDay = t => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const toDateInput = t => { const d = new Date(t); return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; };
  function fromInputs(dateStr, timeStr) {
    const [y, m, d] = dateStr.split('-').map(Number);
    const [hh, mm] = timeStr.split(':').map(Number);
    return new Date(y, m - 1, d, hh, mm).getTime();
  }
  function relDays(t) {
    const d = Math.round((startOfDay(Date.now()) - startOfDay(t)) / DAY_MS);
    return d <= 0 ? 'today' : d === 1 ? 'yesterday' : `${d} days ago`;
  }

  // ---------- Small UI helpers ----------
  let toastTimer = 0;
  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
  }

  function makeSeg(el, options, value, onChange) {
    el.replaceChildren();
    el.setAttribute('role', 'radiogroup');
    for (const o of options) {
      const b = h('button');
      b.type = 'button';
      b.setAttribute('role', 'radio');
      b.dataset.value = o.value;
      if (o.state) b.append(h('span', 'key s-' + o.state));
      b.append(o.label);
      b.addEventListener('click', () => {
        setSeg(el, o.value);
        if (onChange) onChange(o.value);
      });
      el.append(b);
    }
    setSeg(el, value);
  }
  function setSeg(el, value) {
    el.dataset.value = value;
    for (const b of el.children) b.setAttribute('aria-checked', String(b.dataset.value === value));
  }
  const segValue = el => el.dataset.value;

  function applyTheme() {
    if (settings.theme === 'auto') delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = settings.theme;
  }
  function renderTitle() {
    const n = settings.name.trim();
    $('#eyebrow').textContent = n ? `${n}’s breathing` : 'Breathing tracker';
    $('#count-state-label').textContent = n ? `${n} is…` : 'Your cat is…';
  }

  // ---------- Views ----------
  let currentView = 'count';
  function showView(name) {
    currentView = name;
    for (const v of $$('.view')) v.hidden = v.dataset.view !== name;
    for (const b of $$('.tabbar button')) {
      if (b.dataset.tab === name) b.setAttribute('aria-current', 'page');
      else b.removeAttribute('aria-current');
    }
    $('#view-title').textContent = VIEW_TITLES[name];
    renderView();
    window.scrollTo(0, 0);
  }
  function renderView() {
    renderBackupBanners();
    if (currentView === 'count') renderCountInfo();
    if (currentView === 'log') renderLog();
    if (currentView === 'trends') renderTrends();
    if (currentView === 'more') renderMore();
  }

  // ---------- Haptics & screen wake (best effort; silently ignored if unsupported) ----------
  function haptic() {
    try {
      if (navigator.vibrate) { navigator.vibrate(12); return; }
      // iOS 18+ Safari gives a light tap when a switch control toggles.
      const label = document.createElement('label');
      label.ariaHidden = 'true';
      label.style.display = 'none';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.setAttribute('switch', '');
      label.append(input);
      document.head.append(label);
      label.click();
      label.remove();
    } catch { /* no haptics */ }
  }
  async function keepAwake() {
    try {
      if ('wakeLock' in navigator && !counter.wake) {
        counter.wake = await navigator.wakeLock.request('screen');
        counter.wake.addEventListener('release', () => { counter.wake = null; });
      }
    } catch { /* not allowed */ }
  }
  function releaseWake() {
    try { if (counter.wake) counter.wake.release(); } catch { /* already released */ }
    counter.wake = null;
  }

  // ---------- Breath counter ----------
  const pad = $('#pad');
  const counter = { phase: 'idle', start: 0, count: 0, raf: 0, timer: 0, lockUntil: 0, wake: null };

  function tapBreath() {
    const now = Date.now();
    if (counter.phase === 'idle') {
      if (now < counter.lockUntil) return; // swallow stray taps right after a count
      counter.phase = 'running';
      counter.start = now;
      counter.count = 1;
      counter.timer = setTimeout(finishCount, COUNT_MS + 30);
      counter.raf = requestAnimationFrame(tick);
      keepAwake();
    } else if (counter.phase === 'running') {
      if (now - counter.start >= COUNT_MS) { finishCount(); return; }
      counter.count++;
    } else {
      return;
    }
    haptic();
    pad.classList.remove('pulse');
    void pad.offsetWidth; // restart the animation
    pad.classList.add('pulse');
    renderPad();
  }
  function tick() {
    if (counter.phase !== 'running') return;
    if (Date.now() - counter.start >= COUNT_MS) { finishCount(); return; }
    renderPad();
    counter.raf = requestAnimationFrame(tick);
  }
  function finishCount() {
    if (counter.phase !== 'running') return;
    cancelAnimationFrame(counter.raf);
    clearTimeout(counter.timer);
    counter.phase = 'done';
    releaseWake();
    renderPad();
    openResult(counter.count, counter.start);
  }
  function resetCount() {
    cancelAnimationFrame(counter.raf);
    clearTimeout(counter.timer);
    counter.phase = 'idle';
    counter.count = 0;
    counter.lockUntil = Date.now() + 700;
    releaseWake();
    renderPad();
  }
  function renderPad() {
    const { phase } = counter;
    const elapsed = phase === 'running' ? Math.min(COUNT_MS, Date.now() - counter.start) : phase === 'done' ? COUNT_MS : 0;
    pad.dataset.phase = phase;
    $('#pad-count').textContent = phase === 'idle' ? 'Tap' : String(counter.count);
    $('#pad-sub').textContent =
      phase === 'idle' ? 'on the first breath' : phase === 'running' ? `${Math.ceil((COUNT_MS - elapsed) / 1000)} s left` : 'Time’s up';
    $('#ring-prog').style.strokeDashoffset = String(RING_C * (1 - elapsed / COUNT_MS));
    $('#btn-reset').style.visibility = phase === 'running' ? 'visible' : 'hidden';
  }
  function syncPadColor() {
    pad.classList.remove('s-asleep', 's-half', 's-awake');
    pad.classList.add('s-' + segValue($('#count-state')));
  }
  function renderCountInfo() {
    const el = $('#last-asleep');
    let last = null;
    for (let i = readings.length - 1; i >= 0; i--) if (readings[i].state === 'asleep') { last = readings[i]; break; }
    el.hidden = !last;
    if (!last) return;
    el.replaceChildren('Last asleep reading: ', h('strong', null, `${last.bpm}/min`), ` · ${fmtDay(last.t)}, ${fmtTime(last.t)}`);
  }

  // ---------- Result sheet ----------
  const dlgResult = $('#sheet-result');
  let pending = null;
  function openResult(bpm, t) {
    pending = { bpm, t };
    setSeg($('#res-state'), segValue($('#count-state')));
    $('#res-note').value = '';
    $('#res-when').textContent = `${fmtDay(t)} · started ${fmtTime(t)}`;
    renderResult();
    dlgResult.showModal();
  }
  function renderResult() {
    $('#res-bpm').textContent = pending.bpm;
    const over = isOverAlert(segValue($('#res-state')), pending.bpm);
    $('#res-alert').hidden = !over;
    $('#res-alert-text').textContent = `Above your alert level of ${settings.alert}. Consider counting again in a few minutes, and follow your vet’s advice.`;
  }

  // ---------- Add / edit sheet ----------
  const dlgEntry = $('#sheet-entry');
  let editingId = null;
  function openEntry(r) {
    editingId = r ? r.id : null;
    $('#entry-title').textContent = r ? 'Edit reading' : 'Add a reading';
    const t = r ? r.t : Date.now();
    $('#f-date').value = toDateInput(t);
    $('#f-date').max = toDateInput(Date.now());
    $('#f-time').value = fmtTime(t);
    setSeg($('#f-state'), r ? r.state : settings.countState);
    $('#f-bpm').value = r ? r.bpm : '';
    $('#f-note').value = r ? r.note || '' : '';
    $('#f-delete').hidden = !r;
    $('#f-error').hidden = true;
    dlgEntry.showModal();
  }
  function entryError(msg) {
    $('#f-error').textContent = msg;
    $('#f-error').hidden = false;
  }

  // ---------- Log ----------
  function renderLog() {
    const filter = settings.logFilter;
    const list = readings.filter(r => filter === 'all' || r.state === filter).sort((a, b) => b.t - a.t);
    const root = $('#log-list');
    root.replaceChildren();
    const empty = $('#log-empty');
    empty.hidden = list.length > 0;
    empty.textContent = readings.length
      ? 'No readings match this filter.'
      : 'No readings yet. Count breaths on the Count tab, add a past reading above, or restore a backup under More.';

    const thisYear = new Date().getFullYear();
    let lastKey = null;
    let ul = null;
    for (const r of list) {
      const k = dayKey(r.t);
      if (k !== lastKey) {
        lastKey = k;
        root.append(h('h3', 'day', fmtDay(r.t, new Date(r.t).getFullYear() !== thisYear)));
        ul = h('ul', 'rows');
        root.append(ul);
      }
      const b = h('button', 'row');
      b.type = 'button';
      const txt = h('span', 'row-txt');
      txt.append(h('span', null, STATES[r.state].label));
      if (r.note) txt.append(h('span', 'row-note', r.note));
      const st = h('span', 'row-state s-' + r.state);
      st.append(h('span', 'key'), txt);
      const val = h('span', 'row-bpm');
      const over = isOverAlert(r.state, r.bpm);
      if (over) val.append(h('span', 'flag', '▲'));
      val.append(String(r.bpm));
      b.append(h('span', 'row-time', fmtTime(r.t)), st, val);
      b.setAttribute('aria-label',
        `${fmtTime(r.t)}, ${STATES[r.state].label}, ${r.bpm} breaths per minute${over ? ', above alert level' : ''}${r.note ? ', ' + r.note : ''}`);
      b.addEventListener('click', () => openEntry(r));
      const li = h('li');
      li.append(b);
      ul.append(li);
    }
  }

  // ---------- Trends ----------
  const hiddenStates = new Set();
  let chartPoints = [];
  let chartHl = null;

  function rangeBounds() {
    const now = Date.now();
    const r = RANGES.find(x => x.value === settings.range) || RANGES[1];
    let from;
    let to = now;
    if (r.days) {
      from = now - r.days * DAY_MS;
    } else {
      from = readings.length ? startOfDay(readings[0].t) : now - 7 * DAY_MS;
      if (readings.length) to = Math.max(now, readings[readings.length - 1].t);
      if (to - from < 2 * DAY_MS) from = to - 2 * DAY_MS;
    }
    return { from, to, items: readings.filter(x => x.t >= from && x.t <= to) };
  }

  function renderTrends() {
    const bounds = rangeBounds();
    renderTiles(bounds.items);
    renderLegend(bounds.items);
    drawChart(bounds);
  }

  function renderTiles(items) {
    const root = $('#tiles');
    root.replaceChildren();
    for (const s of STATE_ORDER) {
      const v = items.filter(r => r.state === s).map(r => r.bpm);
      const tile = h('div', 'tile s-' + s);
      const lbl = h('div', 'tile-lbl');
      lbl.append(h('span', 'key'), STATES[s].label);
      const val = h('div', 'tile-val');
      tile.append(lbl, val);
      if (v.length) {
        const avg = v.reduce((a, b) => a + b, 0) / v.length;
        val.append(String(Math.round(avg)), h('small', null, 'avg'));
        tile.append(h('div', 'tile-sub', `${v.length} reading${v.length > 1 ? 's' : ''}`),
          h('div', 'tile-sub', v.length > 1 ? `range ${Math.min(...v)}–${Math.max(...v)}` : ' '));
      } else {
        val.textContent = '–';
        tile.append(h('div', 'tile-sub', 'No readings'));
      }
      root.append(tile);
    }
  }

  function renderLegend(items) {
    const root = $('#legend');
    root.replaceChildren();
    for (const s of STATE_ORDER) {
      const n = items.filter(r => r.state === s).length;
      const b = h('button', 'lg-item s-' + s);
      b.type = 'button';
      b.setAttribute('aria-pressed', String(!hiddenStates.has(s)));
      b.append(h('span', 'key'), `${STATES[s].label} (${n})`);
      b.addEventListener('click', () => {
        if (hiddenStates.has(s)) hiddenStates.delete(s);
        else hiddenStates.add(s);
        renderTrends();
      });
      root.append(b);
    }
    const th = h('span', 'lg-item lg-static');
    th.append(h('span', 'dashkey'), `Alert ${settings.alert}`);
    root.append(th);
  }

  function timeTicks(from, to, width) {
    const maxTicks = Math.max(2, Math.floor(width / 58));
    const spanDays = (to - from) / DAY_MS;
    const ticks = [];
    const step = [1, 2, 3, 7, 14].find(s => spanDays / s <= maxTicks);
    const d = new Date(from);
    d.setHours(0, 0, 0, 0);
    if (step) {
      if (d.getTime() < from) d.setDate(d.getDate() + 1);
      if (step >= 7) while (d.getDay() !== 1) d.setDate(d.getDate() + 1); // weeks start Monday
      while (d.getTime() <= to) {
        ticks.push({ t: d.getTime(), label: `${d.getDate()} ${MO[d.getMonth()]}` });
        d.setDate(d.getDate() + step);
      }
    } else {
      const mstep = [1, 2, 3, 6, 12].find(s => spanDays / 30.44 / s <= maxTicks) || 12;
      d.setDate(1);
      if (d.getTime() < from) d.setMonth(d.getMonth() + 1);
      while (d.getMonth() % mstep) d.setMonth(d.getMonth() + 1);
      while (d.getTime() <= to) {
        ticks.push({ t: d.getTime(), label: d.getMonth() === 0 ? String(d.getFullYear()) : MO[d.getMonth()] });
        d.setMonth(d.getMonth() + mstep);
      }
    }
    return ticks;
  }

  function drawChart({ from, to, items }) {
    const svg = $('#chart');
    const W = Math.max(260, Math.floor($('#chart-wrap').clientWidth));
    const H = 250;
    const m = { l: 30, r: 8, t: 14, b: 26 };
    const pw = W - m.l - m.r;
    const ph = H - m.t - m.b;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);
    svg.replaceChildren();
    hideTip();
    chartPoints = [];

    const alert = settings.alert;
    const vals = items.map(r => r.bpm);
    const lo = Math.min(15, vals.length ? Math.min(...vals) - 2 : 15);
    const hi = Math.max(40, alert + 5, vals.length ? Math.max(...vals) + 2 : 40);
    const yMin = Math.max(0, Math.floor(lo / 5) * 5);
    const yMax = Math.ceil(hi / 5) * 5;
    const yStep = yMax - yMin > 50 ? 10 : 5;
    const padT = (to - from) * 0.03;
    const x0 = from - padT;
    const x1 = to + padT;
    const X = t => m.l + ((t - x0) / (x1 - x0)) * pw;
    const Y = v => m.t + (1 - (v - yMin) / (yMax - yMin)) * ph;

    // Grid + y labels
    for (let v = yMin; v <= yMax; v += yStep) {
      const y = Math.round(Y(v)) + 0.5;
      svgEl('line', { x1: m.l, x2: W - m.r, y1: y, y2: y, class: v === yMin ? 'axis' : 'grid' }, svg);
      svgEl('text', { x: m.l - 7, y: y + 4, class: 'tick', 'text-anchor': 'end' }, svg).textContent = v;
    }
    // X ticks
    for (const tk of timeTicks(from, to, pw)) {
      const x = X(tk.t);
      if (x < m.l || x > W - m.r) continue;
      const base = Math.round(Y(yMin)) + 0.5;
      svgEl('line', { x1: x, x2: x, y1: base, y2: base + 4, class: 'axis' }, svg);
      const anchor = x < m.l + 18 ? 'start' : x > W - m.r - 18 ? 'end' : 'middle';
      svgEl('text', { x, y: H - 6, class: 'tick', 'text-anchor': anchor }, svg).textContent = tk.label;
    }
    // Alert threshold
    const ya = Math.round(Y(alert)) + 0.5;
    svgEl('line', { x1: m.l, x2: W - m.r, y1: ya, y2: ya, class: 'threshold' }, svg);

    const visible = DRAW_ORDER.filter(s => !hiddenStates.has(s));
    const shown = items.filter(r => visible.includes(r.state));
    if (!shown.length) {
      svgEl('text', { x: m.l + pw / 2, y: m.t + ph / 2, class: 'empty-label', 'text-anchor': 'middle' }, svg)
        .textContent = items.length ? 'All states hidden' : 'No readings in this period';
      return;
    }

    // Daily-average lines first, then dots on top.
    const groups = visible.map(s => ({ s, pts: items.filter(r => r.state === s) })).filter(g => g.pts.length);
    for (const { s, pts } of groups) {
      const byDay = new Map();
      for (const r of pts) {
        const k = dayKey(r.t);
        const a = byDay.get(k) || { ts: 0, vs: 0, n: 0 };
        a.ts += r.t; a.vs += r.bpm; a.n++;
        byDay.set(k, a);
      }
      const means = [...byDay.values()].map(a => ({ t: a.ts / a.n, v: a.vs / a.n })).sort((a, b) => a.t - b.t);
      if (means.length > 1) {
        const d = means.map((p, i) => `${i ? 'L' : 'M'}${X(p.t).toFixed(1)} ${Y(p.v).toFixed(1)}`).join(' ');
        svgEl('path', { d, class: 'line s-' + s }, svg);
      }
    }
    for (const { s, pts } of groups) {
      const g = svgEl('g', { class: 's-' + s }, svg);
      for (const r of pts) {
        const cx = X(r.t);
        const cy = Y(r.bpm);
        svgEl('circle', { cx: cx.toFixed(1), cy: cy.toFixed(1), r: 4, class: 'dot' }, g);
        chartPoints.push({ x: cx, y: cy, r });
      }
    }
    chartHl = svgEl('circle', { r: 7.5, class: 'hl', visibility: 'hidden' }, svg);
  }

  function onChartPointer(e) {
    const rect = $('#chart').getBoundingClientRect();
    const px = e.clientX - rect.left;
    const py = e.clientY - rect.top;
    let best = null;
    let bd = Infinity;
    for (const p of chartPoints) {
      const d = Math.hypot(p.x - px, p.y - py);
      if (d < bd) { bd = d; best = p; }
    }
    if (!best || bd > 32) { hideTip(); return; }
    showTip(best);
  }
  function showTip(p) {
    const tip = $('#tip');
    const r = p.r;
    const val = h('div', 'tip-val', String(r.bpm));
    val.append(h('span', 'tip-unit', ' /min'));
    const st = h('div', 'tip-state s-' + r.state);
    st.append(h('span', 'linekey'), STATES[r.state].label);
    tip.replaceChildren(val, st, h('div', 'tip-when', `${fmtDay(r.t)} · ${fmtTime(r.t)}`));
    if (r.note) tip.append(h('div', 'tip-note', r.note));
    tip.hidden = false;
    const wrapW = $('#chart-wrap').clientWidth;
    const tw = tip.offsetWidth;
    const th = tip.offsetHeight;
    const left = Math.max(0, Math.min(wrapW - tw, p.x - tw / 2));
    let top = p.y - th - 14;
    if (top < 0) top = p.y + 14;
    tip.style.left = left + 'px';
    tip.style.top = top + 'px';
    if (chartHl) {
      chartHl.setAttribute('cx', p.x.toFixed(1));
      chartHl.setAttribute('cy', p.y.toFixed(1));
      chartHl.setAttribute('visibility', 'visible');
    }
  }
  function hideTip() {
    $('#tip').hidden = true;
    if (chartHl) chartHl.setAttribute('visibility', 'hidden');
  }

  // ---------- Backup reminder ----------
  // Shown when there are changes not yet backed up and the last backup is a week old
  // (or there are lots of changes). "Later" hides it for a day.
  function renderBackupBanners() {
    const now = Date.now();
    const due = readings.length > 0 && settings.unsaved > 0 && now >= settings.backupSnooze &&
      (now - settings.lastExport >= 7 * DAY_MS || settings.unsaved >= 20);
    for (const el of $$('.backup-banner')) {
      el.hidden = !due;
      if (!due) continue;
      const n = settings.unsaved;
      const text = h('p', 'banner-text');
      text.append(h('strong', null, settings.lastExport ? 'Time for a backup' : 'Back up your readings'),
        h('span', null, settings.lastExport
          ? `${n} change${n === 1 ? '' : 's'} since your last backup ${relDays(settings.lastExport)}.`
          : `${n} reading${n === 1 ? ' isn’t' : 's aren’t'} backed up yet. Save a copy to iCloud Drive.`));
      const go = h('button', 'btn primary small', 'Back up');
      go.type = 'button';
      go.addEventListener('click', exportCSV);
      const later = h('button', 'btn ghost small', 'Later');
      later.type = 'button';
      later.addEventListener('click', () => { settings.backupSnooze = Date.now() + DAY_MS; saveSettings(); renderBackupBanners(); });
      const btns = h('div', 'banner-btns');
      btns.append(later, go);
      el.replaceChildren(text, btns);
    }
  }

  // ---------- Settings & data ----------
  function renderMore() {
    $('#s-name').value = settings.name;
    $('#s-alert').value = settings.alert;
    setSeg($('#s-theme'), settings.theme);
    const n = readings.length;
    $('#data-count').textContent = n
      ? `${n} reading${n === 1 ? '' : 's'} saved on this device, starting ${fmtDay(readings[0].t, true)}.`
      : 'No readings saved yet.';
    $('#last-export').textContent = settings.lastExport
      ? `Last backup: ${relDays(settings.lastExport)}${settings.unsaved ? ` (${settings.unsaved} change${settings.unsaved === 1 ? '' : 's'} since)` : ', up to date'}.`
      : 'No backup yet.';
    $('#app-version').textContent = `Version ${APP_VERSION}`;
  }

  function csvCell(v) {
    const s = String(v);
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  }
  function toCSV() {
    const rows = [['date', 'time', 'state', 'breaths_per_min', 'note']];
    for (const r of readings) rows.push([toDateInput(r.t), fmtTime(r.t), STATES[r.state].csv, r.bpm, r.note || '']);
    return rows.map(row => row.map(csvCell).join(',')).join('\r\n') + '\r\n';
  }
  async function exportCSV() {
    if (!readings.length) { toast('Nothing to back up yet'); return; }
    const cat = settings.name.trim().replace(/[^\p{L}\p{N} _-]+/gu, '').trim();
    const name = `${cat ? cat + ' ' : ''}breathing backup ${toDateInput(Date.now())}.csv`;
    const blob = new Blob([toCSV()], { type: 'text/csv' });
    const markDone = () => {
      settings.lastExport = Date.now();
      settings.unsaved = 0;
      saveSettings();
      renderView();
      toast('Backup saved');
    };
    try {
      const file = new File([blob], name, { type: 'text/csv' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({ files: [file], title: name });
        markDone();
        return;
      }
    } catch (err) {
      if (err && err.name === 'AbortError') return; // user closed the share sheet
    }
    const url = URL.createObjectURL(blob);
    const a = h('a');
    a.href = url;
    a.download = name;
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
    markDone();
  }

  // ---------- Import ----------
  function normState(s) {
    s = String(s || '').toLowerCase();
    if (/half|drows|doz/.test(s)) return 'half';
    if (/sleep/.test(s)) return 'asleep';
    if (/awake|wake/.test(s)) return 'awake';
    return null;
  }
  function makeTime(y, mo, d, hh, mm) {
    if (hh > 23 || mm > 59) return null;
    const dt = new Date(y, mo, d, hh, mm);
    if (dt.getMonth() !== mo || dt.getDate() !== d) return null;
    return dt.getTime();
  }
  function to24h(hh, ampm) {
    if (!ampm) return hh;
    const pm = ampm.toLowerCase() === 'pm';
    if (hh === 12) return pm ? 12 : 0;
    return pm ? hh + 12 : hh;
  }
  function guessYear(mo, d, hh, mm) {
    // Logs often omit the year: use this year, unless that would be in the future.
    const now = new Date();
    const y = now.getFullYear();
    const t = makeTime(y, mo, d, hh, mm);
    return t != null && t > now.getTime() + DAY_MS ? y - 1 : y;
  }

  // e.g. "Monday 21st Sept 23:00 (awake)  32", "3 Oct 2026 2:14pm asleep - 23"
  const FREE_RE = /(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,9})\.?,?(?:\s+(\d{4}))?[\s,]+(\d{1,2})[:.](\d{2})\s*(am|pm)?\s*(?:\(([^)]*)\)|\b(asleep|sleeping|half[\s-]?asleep|drowsy|awake)\b)?\s*[-–—:=,]?\s*(\d{1,3})\D*$/i;
  function parseFreeLine(line) {
    const m = FREE_RE.exec(line);
    if (!m) return null;
    const mo = MONTHS[m[2].slice(0, 3).toLowerCase()];
    if (mo == null) return null;
    const d = +m[1];
    const hh = to24h(+m[4], m[6]);
    const mm = +m[5];
    const state = normState(m[7] || m[8]);
    const bpm = +m[9];
    if (!state || !(bpm > 0 && bpm < 300)) return null;
    const y = m[3] ? +m[3] : guessYear(mo, d, hh, mm);
    const t = makeTime(y, mo, d, hh, mm);
    return t == null ? null : { t, state, bpm, note: '' };
  }

  function parseCSV(text, delim) {
    const rows = [];
    let row = [];
    let cell = '';
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (quoted) {
        if (c === '"') {
          if (text[i + 1] === '"') { cell += '"'; i++; } else quoted = false;
        } else cell += c;
      } else if (c === '"') quoted = true;
      else if (c === delim) { row.push(cell); cell = ''; }
      else if (c === '\n' || c === '\r') {
        if (c === '\r' && text[i + 1] === '\n') i++;
        row.push(cell); rows.push(row); row = []; cell = '';
      } else cell += c;
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
    return rows;
  }
  function csvRowToReading(cells, idx) {
    const get = i => (i >= 0 && cells[i] != null ? String(cells[i]).trim() : '');
    const ds = get(idx.date);
    const ts = get(idx.time) || (ds.match(/\d{1,2}:\d{2}/) || [''])[0];
    let y, mo, d, m;
    if ((m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(ds))) { y = +m[1]; mo = +m[2] - 1; d = +m[3]; }
    else if ((m = /^(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})/.exec(ds))) { d = +m[1]; mo = +m[2] - 1; y = +m[3]; if (y < 100) y += 2000; }
    else return null;
    const tm = /^(\d{1,2})[:.](\d{2})(?::\d{2})?\s*(am|pm)?/i.exec(ts);
    if (!tm) return null;
    const state = normState(get(idx.state));
    const bpm = parseInt(get(idx.bpm), 10);
    if (!state || !(bpm > 0 && bpm < 300)) return null;
    const t = makeTime(y, mo, d, to24h(+tm[1], tm[3]), +tm[2]);
    return t == null ? null : { t, state, bpm, note: get(idx.note) };
  }
  function parseImport(text) {
    text = text.replace(/^﻿/, '');
    const firstLine = text.split(/\r\n|\n|\r/).find(l => l.trim()) || '';
    const found = [];
    const bad = [];
    if (/^\s*"?date"?\s*[,;\t]/i.test(firstLine)) {
      const delim = [',', ';', '\t'].sort((a, b) => firstLine.split(b).length - firstLine.split(a).length)[0];
      const rows = parseCSV(text, delim).filter(r => r.some(c => c.trim()));
      const head = rows.shift().map(c => c.trim().toLowerCase());
      const col = re => head.findIndex(c => re.test(c));
      const idx = {
        date: col(/^date|day/), time: col(/time/), state: col(/state|status/),
        bpm: col(/bpm|breath|rate|per.?min|count/), note: col(/note|comment/),
      };
      for (const cells of rows) {
        const r = csvRowToReading(cells, idx);
        if (r) found.push(r); else bad.push(cells.join(delim === '\t' ? '  ' : delim + ' '));
      }
    } else {
      for (const raw of text.split(/\r\n|\n|\r/)) {
        const line = raw.trim();
        if (!line) continue;
        const r = parseFreeLine(line);
        if (r) found.push(r);
        else if (/\d/.test(line)) bad.push(line); // lines without digits are just headings
      }
    }
    return { found, bad };
  }

  const dupKey = r => `${Math.round(r.t / 60000)}|${r.state}|${r.bpm}`;
  function previewImport(text, fromFile) {
    const box = $('#import-result');
    box.replaceChildren();
    box.hidden = false;
    const { found, bad } = parseImport(text);
    const existing = new Set(readings.map(dupKey));
    const fresh = [];
    let dups = 0;
    for (const r of found) {
      const k = dupKey(r);
      if (existing.has(k)) { dups++; continue; }
      existing.add(k);
      fresh.push(r);
    }
    if (!found.length) {
      box.append(h('p', null, 'I couldn’t find any readings there. Each line needs a date, a time, a state (awake, asleep or half-asleep) and the number of breaths.'));
    } else {
      const c = { asleep: 0, half: 0, awake: 0 };
      for (const r of found) c[r.state]++;
      const ts = found.map(r => r.t);
      const head = h('p');
      head.append(h('strong', null, `Found ${found.length} reading${found.length === 1 ? '' : 's'}`),
        ` from ${fmtDay(Math.min(...ts), true)} to ${fmtDay(Math.max(...ts), true)}: ${c.asleep} asleep, ${c.half} half-asleep, ${c.awake} awake.`);
      box.append(head);
      if (dups) box.append(h('p', null, `${dups} ${dups === 1 ? 'is' : 'are'} already in your log and will be skipped.`));
    }
    if (bad.length) {
      box.append(h('p', null, `${bad.length} line${bad.length === 1 ? '' : 's'} couldn’t be read and will be skipped:`));
      const ul = h('ul');
      for (const line of bad.slice(0, 5)) { const li = h('li'); li.append(h('code', null, line)); ul.append(li); }
      if (bad.length > 5) ul.append(h('li', null, `…and ${bad.length - 5} more`));
      box.append(ul);
    }
    if (fresh.length) {
      const row = h('div', 'row-btns');
      const cancel = h('button', 'btn ghost', 'Cancel');
      cancel.type = 'button';
      cancel.addEventListener('click', () => { box.hidden = true; });
      const go = h('button', 'btn primary', `Add ${fresh.length}`);
      go.type = 'button';
      go.addEventListener('click', () => {
        addReadings(fresh, fromFile); // restoring a backup file doesn't need backing up again
        box.hidden = true;
        $('#import-text').value = '';
        renderMore();
        toast(`Added ${fresh.length} reading${fresh.length === 1 ? '' : 's'}`);
      });
      row.append(cancel, go);
      box.append(row);
    } else if (found.length) {
      box.append(h('p', null, 'Nothing new to add.'));
    }
  }

  // ---------- Wire up ----------
  function init() {
    applyTheme();
    renderTitle();

    for (const b of $$('.tabbar button')) b.addEventListener('click', () => showView(b.dataset.tab));

    // Counter
    makeSeg($('#count-state'), STATE_OPTIONS, settings.countState, v => {
      settings.countState = v;
      saveSettings();
      syncPadColor();
    });
    syncPadColor();
    pad.addEventListener('pointerdown', e => {
      if (e.button > 0) return;
      e.preventDefault();
      tapBreath();
    });
    pad.addEventListener('keydown', e => {
      if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); tapBreath(); }
    });
    pad.addEventListener('contextmenu', e => e.preventDefault());
    $('#btn-reset').addEventListener('click', () => { resetCount(); toast('Count reset'); });
    document.addEventListener('visibilitychange', () => {
      if (document.hidden || counter.phase !== 'running') return;
      if (Date.now() - counter.start >= COUNT_MS) finishCount();
      else { cancelAnimationFrame(counter.raf); counter.raf = requestAnimationFrame(tick); keepAwake(); }
    });
    renderPad();

    // Result sheet
    makeSeg($('#res-state'), STATE_OPTIONS, settings.countState, renderResult);
    $('#res-minus').addEventListener('click', () => { if (pending.bpm > 1) { pending.bpm--; renderResult(); } });
    $('#res-plus').addEventListener('click', () => { pending.bpm++; renderResult(); });
    $('#res-save').addEventListener('click', () => {
      const state = segValue($('#res-state'));
      const { bpm, t } = pending;
      addReadings([{ t, state, bpm, note: $('#res-note').value.trim() }]);
      settings.countState = state;
      saveSettings();
      setSeg($('#count-state'), state);
      syncPadColor();
      dlgResult.close();
      resetCount();
      renderCountInfo();
      toast(`Saved: ${bpm}/min, ${STATES[state].label.toLowerCase()}`);
    });
    $('#res-discard').addEventListener('click', () => { dlgResult.close(); resetCount(); toast('Count discarded'); });
    dlgResult.addEventListener('cancel', e => e.preventDefault()); // don't lose a count to the Esc key

    // Add / edit sheet
    makeSeg($('#f-state'), STATE_OPTIONS, settings.countState);
    $('#btn-add').addEventListener('click', () => openEntry(null));
    $('#f-cancel').addEventListener('click', () => dlgEntry.close());
    dlgEntry.addEventListener('click', e => { if (e.target === dlgEntry) dlgEntry.close(); });
    $('#entry-form').addEventListener('submit', e => {
      e.preventDefault();
      const ds = $('#f-date').value;
      const tm = $('#f-time').value;
      const bpm = parseInt($('#f-bpm').value, 10);
      if (!ds || !tm) return entryError('Please set a date and a time.');
      if (!(bpm >= 1 && bpm <= 250)) return entryError('Enter the breaths per minute as a number, like 24.');
      const t = fromInputs(ds, tm);
      if (t > Date.now() + 5 * 60000) return entryError('That date and time is in the future.');
      const data = { t, state: segValue($('#f-state')), bpm, note: $('#f-note').value.trim() };
      if (editingId) {
        const r = readings.find(x => x.id === editingId);
        if (r) Object.assign(r, data);
        persist();
        markChanged(1);
      } else {
        addReadings([data]);
      }
      dlgEntry.close();
      renderView();
      toast(editingId ? 'Reading updated' : 'Reading added');
    });
    $('#f-delete').addEventListener('click', () => {
      if (!editingId || !confirm('Delete this reading?')) return;
      readings = readings.filter(x => x.id !== editingId);
      persist();
      markChanged(1);
      dlgEntry.close();
      renderView();
      toast('Reading deleted');
    });

    // Log
    makeSeg($('#log-filter'),
      [{ value: 'all', label: 'All' }, ...STATE_ORDER.map(s => ({ value: s, label: STATES[s].short, state: s }))],
      settings.logFilter,
      v => { settings.logFilter = v; saveSettings(); renderLog(); });

    // Trends
    makeSeg($('#range'), RANGES, settings.range, v => { settings.range = v; saveSettings(); renderTrends(); });
    const chart = $('#chart');
    chart.addEventListener('pointerdown', onChartPointer);
    chart.addEventListener('pointermove', e => { if (e.pointerType === 'mouse' || e.buttons) onChartPointer(e); });
    chart.addEventListener('pointerleave', e => { if (e.pointerType === 'mouse') hideTip(); });
    document.addEventListener('pointerdown', e => { if (!e.target.closest('#chart-wrap')) hideTip(); });
    let resizeRaf = 0;
    window.addEventListener('resize', () => {
      cancelAnimationFrame(resizeRaf);
      resizeRaf = requestAnimationFrame(() => { if (currentView === 'trends') renderTrends(); });
    });

    // Settings & data
    $('#s-name').addEventListener('input', e => { settings.name = e.target.value.slice(0, 40); saveSettings(); renderTitle(); });
    $('#s-alert').addEventListener('change', e => {
      const v = parseInt(e.target.value, 10);
      if (v >= 10 && v <= 80) { settings.alert = v; saveSettings(); toast(`Alert level set to ${v}`); }
      else { e.target.value = settings.alert; toast('Alert level should be between 10 and 80'); }
    });
    makeSeg($('#s-theme'), [{ value: 'auto', label: 'Auto' }, { value: 'light', label: 'Light' }, { value: 'dark', label: 'Dark' }],
      settings.theme, v => { settings.theme = v; saveSettings(); applyTheme(); });
    $('#btn-export').addEventListener('click', exportCSV);
    $('#btn-import-parse').addEventListener('click', () => {
      const text = $('#import-text').value;
      if (!text.trim()) { toast('Paste your log into the box first'); return; }
      previewImport(text);
    });
    $('#btn-import-file').addEventListener('click', () => $('#import-file').click());
    $('#import-file').addEventListener('change', async e => {
      const f = e.target.files && e.target.files[0];
      e.target.value = '';
      if (f) previewImport(await f.text(), true);
    });
    $('#btn-wipe').addEventListener('click', () => {
      if (!readings.length) { toast('There’s nothing to delete'); return; }
      if (!confirm(`Delete all ${readings.length} readings from this device? This can’t be undone. Export a backup first if you might want them.`)) return;
      readings = [];
      persist();
      settings.unsaved = 0;
      saveSettings();
      renderView();
      toast('All readings deleted');
    });

    // "Add to Home Screen" hint for iPhone Safari
    const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const standalone = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
    $('#install-hint').hidden = !(isIOS && !standalone && !settings.hideInstall);
    $('#install-close').addEventListener('click', () => { settings.hideInstall = true; saveSettings(); $('#install-hint').hidden = true; });

    showView('count');

    if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
      navigator.serviceWorker.register('sw.js').catch(() => { /* offline support unavailable */ });
    }
  }

  init();
})();
