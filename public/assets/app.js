/* Efficiency Reporter: the page.
 *
 * Loads the user's jobs (sacct), then asks the app to run seff on the finished
 * ones in batches, newest first, filling the table in as the reports arrive.
 * Opening a job shows seff's full report, sacct's view of the job and its
 * steps, its batch script and, if it was run with --profile task, the chart
 * profile_plot draws for it.
 *
 * Every per-job number comes from seff's own output, unchanged. The only
 * numbers worked out here are the medians in the summary tiles.
 * Text from the cluster is always put on the page as text, never as HTML.
 */
(function () {
  'use strict';

  const CONFIG = JSON.parse(document.getElementById('er-config').textContent);
  const BASE = document.body.dataset.base || '';
  const APP = document.getElementById('app');
  const T = CONFIG.thresholds || { good: 70, warning: 40, serious: 20 };
  const CMD = CONFIG.commands || { sacct: 'sacct', seff: 'seff', profilePlot: 'profile_plot' };
  const DOCS = CONFIG.docs || {};
  // seff runs on one batch of jobs at a time, starting with the most recent
  // and working back. The first batch is small, so that the newest jobs'
  // figures appear quickly.
  const FIRST_BATCH = 20;
  const EACH_BATCH = 20;

  // Slurm states in which a job has not finished, so seff has nothing to say yet.
  const ACTIVE = new Set(['PENDING', 'RUNNING', 'REQUEUED', 'REQUEUE_FED', 'REQUEUE_HOLD', 'RESIZING',
    'SUSPENDED', 'COMPLETING', 'CONFIGURING', 'STAGE_OUT', 'SIGNALING', 'SPECIAL_EXIT', 'STOPPED']);

  // state -> [label, tone, filter group]
  const STATES = {
    COMPLETED: ['Completed', 'good', 'completed'],
    FAILED: ['Failed', 'critical', 'failed'],
    NODE_FAIL: ['Node failure', 'critical', 'failed'],
    BOOT_FAIL: ['Boot failure', 'critical', 'failed'],
    OUT_OF_MEMORY: ['Out of memory', 'critical', 'oom'],
    TIMEOUT: ['Timed out', 'serious', 'timeout'],
    DEADLINE: ['Deadline', 'serious', 'timeout'],
    PREEMPTED: ['Preempted', 'serious', 'other'],
    CANCELLED: ['Cancelled', 'neutral', 'cancelled'],
    RUNNING: ['Running', 'active', 'active'],
    PENDING: ['Waiting', 'pending', 'active'],
    REQUEUED: ['Requeued', 'pending', 'active'],
    SUSPENDED: ['Suspended', 'pending', 'active']
  };

  // The State filter. "finished" is every job that has ended, however it
  // ended; the choices under it pick one kind of ending.
  const STATE_FILTERS = [
    ['all', 'All states'],
    ['Finished', [
      ['finished', 'All finished jobs'], ['completed', 'Completed'], ['failed', 'Failed'], ['oom', 'Out of memory'],
      ['timeout', 'Timed out'], ['cancelled', 'Cancelled'], ['other', 'Other endings']
    ]],
    ['active', 'Running or waiting']
  ];

  // The kinds of measurement seff reports. "judged" ones are coloured by how
  // well the job used what it asked for; the others are shown in plain blue.
  const KINDS = {
    time: { title: 'Time limit used', judged: false },
    cpu: { title: 'CPU efficiency', judged: true },
    mem: { title: 'Memory efficiency', judged: true },
    gpu: { title: 'GPU utilisation', judged: true },
    gpu_mem: { title: 'GPU memory use', judged: true }
  };

  const ATTENTION_STATES = new Set(['FAILED', 'OUT_OF_MEMORY', 'TIMEOUT', 'NODE_FAIL', 'BOOT_FAIL', 'DEADLINE']);
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  const S = {
    status: 'loading',
    error: null,
    jobs: [],
    byId: new Map(),
    about: {},
    range: null,
    hasGpu: false,
    filters: { days: 0, state: 'all', text: '', profiled: false, attention: false },
    sort: { key: 'when', dir: -1 },
    page: 1,
    pageSize: 50,
    open: new Set(),
    panels: new Map(),
    details: new Map(),
    profiles: new Map(),
    queue: { todo: [], inflight: 0, sent: 0, paused: false, error: null, mode: 'batch', batchSize: CONFIG.batchSize || 100 },
    listing: new Set(),
    listed: new Set(),
    listErrors: []
  };

  let shell = null;

  // ---- Small helpers --------------------------------------------------------

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [key, value] of Object.entries(attrs)) {
        if (value === null || value === undefined || value === false) continue;
        if (key === 'class') node.className = value;
        else if (key === 'style') node.style.cssText = value;
        else if (key === 'dataset') Object.assign(node.dataset, value);
        else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2), value);
        else if (key in node && typeof value !== 'string') node[key] = value;
        else node.setAttribute(key, value === true ? '' : value);
      }
    }
    append(node, children);
    return node;
  }

  function append(node, children) {
    for (const child of children.flat(Infinity)) {
      if (child === null || child === undefined || child === false) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  const SVG_NS = 'http://www.w3.org/2000/svg';
  const ICONS = {
    chevron: 'M9 6l6 6-6 6',
    chart: 'M4 19V5M4 19h16M8 15l3-4 3 2 5-6',
    refresh: 'M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6'
  };

  function icon(name, cls, title) {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    if (cls) svg.setAttribute('class', cls);
    if (title) {
      svg.setAttribute('role', 'img');
      const t = document.createElementNS(SVG_NS, 'title');
      t.textContent = title;
      svg.append(t);
    } else {
      svg.setAttribute('aria-hidden', 'true');
    }
    const path = document.createElementNS(SVG_NS, 'path');
    path.setAttribute('d', ICONS[name]);
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '2');
    path.setAttribute('stroke-linecap', 'round');
    path.setAttribute('stroke-linejoin', 'round');
    svg.append(path);
    return svg;
  }

  function code(text) {
    return el('code', null, text);
  }

  function link(href, text) {
    if (!href) return text;
    return el('a', { href, target: '_blank', rel: 'noopener' }, text);
  }

  function spinnerLine(text) {
    return el('p', { class: 'muted small' }, el('span', { class: 'spinner', 'aria-hidden': 'true' }), text);
  }

  function fmtInt(n) {
    return Number(n || 0).toLocaleString('en-NZ');
  }

  function fmtPct(p) {
    return `${Math.round(p)}%`;
  }

  function parseTime(text) {
    const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)$/.exec(text || '');
    return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null;
  }

  function fmtDay(text) {
    const d = parseTime(text);
    return d ? `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}` : '';
  }

  function fmtWhen(text) {
    const d = parseTime(text);
    if (!d) return '';
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    const sameYear = d.getFullYear() === new Date().getFullYear();
    return `${d.getDate()} ${MONTHS[d.getMonth()]}${sameYear ? '' : ` ${d.getFullYear()}`} ${hh}:${mm}`;
  }

  // "1-02:03:04", "02:03:04" or "03:04" -> seconds
  function durationSeconds(text) {
    const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/.exec(String(text || '').trim());
    if (!m) return null;
    return (+(m[1] || 0)) * 86400 + (+(m[2] || 0)) * 3600 + (+m[3]) * 60 + parseFloat(m[4]);
  }

  // "284.46 MB" -> bytes (seff counts in powers of 1024)
  function sizeBytes(text) {
    const m = /^([\d.]+)\s*([kKMGTPE]?)i?B$/.exec(String(text || '').trim());
    if (!m) return null;
    const power = { '': 0, k: 1, K: 1, M: 2, G: 3, T: 4, P: 5, E: 6 }[m[2]];
    return parseFloat(m[1]) * Math.pow(1024, power);
  }

  function titleCase(text) {
    return String(text).toLowerCase().replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
  }

  function median(values) {
    if (!values.length) return null;
    const sorted = values.slice().sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  function tone(percent) {
    if (percent >= T.good) return 'good';
    if (percent >= T.warning) return 'warning';
    if (percent >= T.serious) return 'serious';
    return 'critical';
  }

  const TONE_WORDS = { good: 'good', warning: 'fair', serious: 'low', critical: 'very low' };

  function stateInfo(state) {
    const known = STATES[state];
    if (known) return { label: known[0], tone: known[1], group: known[2] };
    const active = ACTIVE.has(state);
    return { label: titleCase(state || 'Unknown'), tone: active ? 'active' : 'neutral', group: active ? 'active' : 'other' };
  }

  // ---- Talking to the app ---------------------------------------------------

  class ApiError extends Error {
    constructor(message, detail, status) {
      super(message);
      this.detail = detail || '';
      this.status = status || 0;
    }
  }

  async function api(path, options) {
    const opts = options || {};
    const init = { method: opts.method || 'GET', credentials: 'same-origin', headers: { Accept: 'application/json' } };
    if (opts.body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(opts.body);
    }
    let response;
    try {
      response = await fetch(`${BASE}/${path}`, init);
    } catch (err) {
      throw new ApiError('Could not reach the app. Check your connection and try again.', err.message);
    }
    const type = response.headers.get('content-type') || '';
    let data = null;
    if (type.includes('application/json')) {
      try {
        data = await response.json();
      } catch (err) {
        data = null;
      }
    }
    if (!data) {
      throw new ApiError('The app did not answer with data. Your OnDemand session may have ended: reload the page to log in again.',
        `HTTP ${response.status}`, response.status);
    }
    if (!response.ok) throw new ApiError(data.error || `The app answered with HTTP ${response.status}.`, data.detail, response.status);
    return data;
  }

  // ---- Jobs -------------------------------------------------------------------

  function prepareJob(job) {
    job.name = job.name || '';
    job.partition = job.partition || '';
    job.account = job.account || '';
    job.sortId = (job.id.match(/\d+/g) || ['0']).map(Number);
    job.lastMs = lastActivity(job);
    setSeff(job, job.seff || null);
    return job;
  }

  function lastActivity(job) {
    if (ACTIVE.has(job.state)) return Date.now();
    const d = parseTime(job.end) || parseTime(job.start) || parseTime(job.submit);
    return d ? d.getTime() : 0;
  }

  // job.m holds the numbers the list, sorting and tiles use. When seff failed
  // part-way through a job, the numbers it printed before stopping are left
  // out of those (the row shows seff's error instead); the opened job still
  // shows everything seff printed.
  function setSeff(job, seff) {
    job.seff = seff;
    job.m = {};
    if (seff && !seff.error && Array.isArray(seff.metrics)) {
      for (const metric of seff.metrics) {
        if (!job.m[metric.kind]) job.m[metric.kind] = metric;
      }
    }
  }

  function seffEligible(job) {
    return !ACTIVE.has(job.state) && (job.cpus || 0) > 0;
  }

  function taskProfile(types) {
    return !!types && String(types).split(',').some((t) => ['task', 'all'].includes(t.trim()));
  }

  function isProfiled(job) {
    return taskProfile(job.profile_submit) || taskProfile(job.seff && job.seff.profile) || taskProfile(job.detailProfile);
  }

  function needsAttention(job) {
    if (ATTENTION_STATES.has(job.state)) return true;
    return ['cpu', 'mem', 'gpu', 'gpu_mem'].some((kind) => job.m[kind] && job.m[kind].percent < T.warning);
  }

  // The job list is fetched in steps that all start at once: the last 7
  // days, the last 30 days and the whole history (0). Each step's jobs are
  // shown as soon as sacct returns them, so recent jobs can be looked at, and
  // seff can start on them, while older ones are still being listed.
  const LIST_STEPS = [7, 30, 0].filter((days) => days === 0 || days < (CONFIG.historyMonths || 3) * 28);

  function loadJobs() {
    const token = (S.loadToken || 0) + 1;
    S.loadToken = token;
    S.status = 'loading';
    S.error = null;
    S.listing = new Set(LIST_STEPS);
    S.listed = new Set();
    S.listErrors = [];
    renderAll();
    for (const days of LIST_STEPS) listStep(days, token);
  }

  async function listStep(days, token) {
    let data = null;
    let error = null;
    try {
      data = await api(days ? `api/jobs?days=${days}` : 'api/jobs');
    } catch (err) {
      error = err;
    }
    if (token !== S.loadToken) return; // Refresh was pressed meanwhile
    S.listing.delete(days);
    if (data) {
      S.listed.add(days);
      mergeJobs(data);
      return;
    }
    S.listErrors.push({ days, error });
    if (S.status === 'ready') {
      renderData();
    } else if (!S.listing.size) {
      // Every step failed, so there is nothing to show.
      S.status = 'error';
      S.error = error;
      renderAll();
    }
  }

  // Adds the jobs a listing step returned that are not in the list yet, and
  // queues the finished ones that have no seff report.
  function mergeJobs(data) {
    const first = S.status !== 'ready';
    if (first) {
      resetJobState();
      S.jobs = [];
      S.byId = new Map();
      S.queue.sent = 0;
      S.status = 'ready';
      if (shell) {
        shell.about.replaceChildren();
        delete shell.about.dataset.built;
      }
    }
    S.about = data.about || S.about;
    S.range = data.range || S.range;
    const added = [];
    for (const raw of data.jobs || []) {
      if (S.byId.has(raw.id)) continue;
      const job = prepareJob(raw);
      S.jobs.push(job);
      S.byId.set(job.id, job);
      added.push(job);
    }
    S.hasGpu = S.jobs.some((job) => (job.gpus && job.gpus.length) || job.m.gpu || job.m.gpu_mem);
    if (first) renderAll();
    else renderData();
    queueJobs(added);
  }

  // Whether every job in a range (in days, 0 for the whole history) has been
  // listed, or is still being listed.
  function rangeListed(days) {
    return [...S.listed].some((step) => step === 0 || (days !== 0 && step >= days));
  }

  function rangeListing(days) {
    return !rangeListed(days) && [...S.listing].some((step) => step === 0 || (days !== 0 && step >= days));
  }

  function resetJobState() {
    for (const promise of S.profiles.values()) {
      promise.then((p) => { if (p && p.url) URL.revokeObjectURL(p.url); });
    }
    S.open.clear();
    S.panels.clear();
    S.details.clear();
    S.profiles.clear();
    S.queue.todo = [];
    S.queue.error = null;
  }

  // ---- Running seff in the background ---------------------------------------

  // Most recent first: by when each job finished (or started, or was
  // submitted), then by job ID.
  function newestFirst(a, b) {
    return (b.lastMs - a.lastMs) || compareValues(b.sortId, a.sortId);
  }

  function queueJobs(jobs) {
    const q = S.queue;
    q.todo.push(...jobs.filter((job) => seffEligible(job) && !job.seff));
    q.todo.sort(newestFirst);
    q.error = null;
    pump();
  }

  // Sends the next batch once the one before has come back, so the reports
  // arrive in order, newest to oldest.
  function pump() {
    const q = S.queue;
    if (!q.paused && !q.error && q.inflight === 0 && q.todo.length) {
      let size = q.mode === 'each' ? Math.min(q.batchSize, EACH_BATCH) : q.batchSize;
      if (q.sent === 0) size = Math.min(size, FIRST_BATCH);
      const batch = q.todo.splice(0, size);
      q.sent += 1;
      q.inflight = 1;
      runBatch(batch).finally(() => {
        q.inflight = 0;
        pump();
      });
    }
    renderProgress();
  }

  async function runBatch(batch) {
    const q = S.queue;
    for (const job of batch) job.seffPending = true;
    scheduleRender();
    try {
      const body = {
        mode: q.mode,
        jobs: batch.map((job) => ({
          id: job.id, raw: job.raw, array_id: job.array_id, elapsed_s: job.elapsed_s, end: job.end
        }))
      };
      const data = await api('api/seff', { method: 'POST', body });
      const results = data.results || {};
      for (const job of batch) {
        job.seffPending = false;
        if (job.seff && job.seff.fresh) continue; // the job was opened meanwhile
        setSeff(job, results[job.id] || { error: 'seff gave no report for this job.', metrics: [], text: '' });
      }
      if (data.batch_supported === false) q.mode = 'each';
    } catch (err) {
      for (const job of batch) job.seffPending = false;
      q.todo.unshift(...batch.filter((job) => !job.seff));
      q.error = err;
    }
    scheduleRender();
  }

  // ---- Filtering and sorting -------------------------------------------------

  function filteredJobs() {
    const f = S.filters;
    const since = f.days ? Date.now() - f.days * 86400000 : 0;
    const text = f.text.trim().toLowerCase();
    return S.jobs.filter((job) => {
      if (since && job.lastMs < since) return false;
      if (f.state === 'finished') {
        if (ACTIVE.has(job.state)) return false;
      } else if (f.state !== 'all' && stateInfo(job.state).group !== f.state) {
        return false;
      }
      if (f.profiled && !isProfiled(job)) return false;
      if (f.attention && !needsAttention(job)) return false;
      if (text) {
        const haystack = `${job.id} ${job.name} ${job.partition} ${job.account}`.toLowerCase();
        if (!haystack.includes(text)) return false;
      }
      return true;
    });
  }

  const SORT_KEYS = {
    id: (job) => job.sortId,
    name: (job) => job.name.toLowerCase(),
    state: (job) => stateInfo(job.state).label,
    when: (job) => job.lastMs,
    elapsed: (job) => (Number.isInteger(job.elapsed_s) ? job.elapsed_s : null),
    asked: (job) => (job.cpus || null),
    time: (job) => metricValue(job, 'time'),
    cpu: (job) => metricValue(job, 'cpu'),
    mem: (job) => metricValue(job, 'mem'),
    gpu: (job) => metricValue(job, 'gpu'),
    gpu_mem: (job) => metricValue(job, 'gpu_mem'),
    profile: (job) => (isProfiled(job) ? 1 : 0)
  };

  function metricValue(job, kind) {
    return job.m[kind] ? job.m[kind].percent : null;
  }

  function compareValues(a, b) {
    if (Array.isArray(a)) {
      for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
        const d = (a[i] === undefined ? -1 : a[i]) - (b[i] === undefined ? -1 : b[i]);
        if (d) return d;
      }
      return 0;
    }
    if (typeof a === 'string') return a.localeCompare(b);
    return a - b;
  }

  function sortedJobs(list) {
    const key = SORT_KEYS[S.sort.key] || SORT_KEYS.when;
    const dir = S.sort.dir;
    return list.slice().sort((x, y) => {
      const a = key(x);
      const b = key(y);
      // Jobs without a value always go last, whichever way the column is sorted.
      if (a === null && b === null) return compareValues(y.sortId, x.sortId);
      if (a === null) return 1;
      if (b === null) return -1;
      return dir * compareValues(a, b) || compareValues(y.sortId, x.sortId);
    });
  }

  // ---- Rendering -----------------------------------------------------------------

  let renderQueued = false;

  // Background updates (seff reports arriving) only touch the rows they change,
  // so an opened job, and whatever has focus inside it, is left alone.
  function scheduleRender() {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => {
      renderQueued = false;
      if (S.status === 'ready' && shell) updateData();
    });
  }

  function updateData() {
    const list = filteredJobs();
    const hadGpu = S.hasGpu;
    S.hasGpu = S.hasGpu || S.jobs.some((job) => job.m.gpu || job.m.gpu_mem);
    renderTiles(list);
    renderProgress();
    renderCount(list);
    if (hadGpu !== S.hasGpu) {
      renderTable(list);
      return;
    }
    const cols = columns();
    for (const tr of shell.table.querySelectorAll('tr.job')) {
      const job = S.byId.get(tr.dataset.id);
      if (!job || tr.dataset.stamp === rowStamp(job)) continue;
      const hadFocus = tr.contains(document.activeElement);
      const fresh = jobRow(job, cols);
      tr.replaceWith(fresh);
      if (hadFocus) fresh.querySelector('.expander button').focus({ preventScroll: true });
    }
    fitTable();
  }

  // Changes whenever anything a job's row shows changes.
  function rowStamp(job) {
    const seff = job.seff;
    return [seff ? `${seff.fetched_at || 0}:${seff.error ? 1 : 0}:${(seff.metrics || []).length}` : '-',
      job.seffPending ? 'p' : '', isProfiled(job) ? 'P' : '', S.open.has(job.id) ? 'o' : ''].join('|');
  }

  function renderCount(list) {
    shell.count.textContent = list.length === S.jobs.length
      ? `${fmtInt(S.jobs.length)} jobs`
      : `${fmtInt(list.length)} of ${fmtInt(S.jobs.length)} jobs`;
  }

  function renderAll() {
    renderTopbar();
    if (S.status === 'error') {
      shell = null;
      APP.replaceChildren(errorCard(S.error));
      return;
    }
    if (S.status === 'loading') {
      if (shell) {
        // Keep the old list in view, dimmed, while the new one loads.
        shell.table.style.opacity = '0.55';
      } else {
        APP.replaceChildren(spinnerLine('Loading your jobs with sacct…'));
      }
      return;
    }
    if (!shell) buildShell();
    shell.table.style.opacity = '';
    renderData();
  }

  // A full redraw, for when the filters, the sort order or the page change.
  function renderData() {
    const list = filteredJobs();
    renderRangeButtons();
    renderIntro();
    renderTiles(list);
    renderTable(list);
    renderProgress();
    renderAbout();
    renderCount(list);
  }

  function renderTopbar() {
    const nav = document.getElementById('topbar-links');
    if (!nav) return;
    if (!nav.dataset.built) {
      nav.dataset.built = '1';
      const refresh = el('button', { class: 'btn', type: 'button', id: 'refresh-button', onclick: () => loadJobs() },
        icon('refresh'), 'Refresh');
      nav.append(refresh);
    }
    const button = document.getElementById('refresh-button');
    if (button) button.disabled = S.status === 'loading';
  }

  function buildShell() {
    shell = {
      intro: el('p', { class: 'intro' }),
      toolbar: el('div', { class: 'toolbar', role: 'group', 'aria-label': 'Filter jobs' }),
      progress: el('div', { class: 'progress', role: 'status', 'aria-live': 'polite', hidden: true }),
      tiles: el('section', { class: 'tiles', 'aria-label': 'Summary of the jobs shown' }),
      table: el('section', { class: 'table-card', 'aria-label': 'Jobs' }),
      about: el('details', { class: 'about' }),
      count: el('span', { class: 'count', 'aria-live': 'polite' })
    };
    shell.root = el('div', null, shell.intro, shell.toolbar, shell.progress, shell.tiles, shell.table, shell.about);
    APP.replaceChildren(shell.root);
    buildToolbar();
  }

  // The filters outlive a reload after an error, so the controls start from them.
  function buildToolbar() {
    const months = CONFIG.historyMonths || 3;
    const ranges = [[7, 'Last 7 days'], [30, 'Last 30 days'], [0, `Last ${months} months`]];
    const segmented = el('div', { class: 'segmented', role: 'group', 'aria-label': 'Time range' });
    shell.rangeButtons = new Map();
    for (const [days, label] of ranges) {
      const button = el('button', { type: 'button', 'aria-pressed': String(S.filters.days === days) }, label);
      shell.rangeButtons.set(days, button);
      button.addEventListener('click', () => {
        S.filters.days = days;
        for (const b of segmented.querySelectorAll('button')) b.setAttribute('aria-pressed', String(b === button));
        S.page = 1;
        renderData();
      });
      segmented.append(button);
    }

    const stateSelect = el('select', { 'aria-label': 'State' },
      STATE_FILTERS.map(([value, label]) => (Array.isArray(label)
        ? el('optgroup', { label: value }, label.map(([v, l]) => el('option', { value: v }, l)))
        : el('option', { value }, label))));
    stateSelect.value = S.filters.state;
    stateSelect.addEventListener('change', () => {
      S.filters.state = stateSelect.value;
      S.page = 1;
      renderData();
    });

    const search = el('input', { type: 'search', placeholder: 'Search job ID, name, project…', 'aria-label': 'Search jobs' });
    search.value = S.filters.text;
    let timer = null;
    search.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        S.filters.text = search.value;
        S.page = 1;
        renderData();
      }, 150);
    });

    const checkbox = (key, label, title) => {
      const input = el('input', { type: 'checkbox', checked: S.filters[key] });
      input.addEventListener('change', () => {
        S.filters[key] = input.checked;
        S.page = 1;
        renderData();
      });
      return el('label', { class: 'check', title }, input, label);
    };

    shell.toolbar.append(
      segmented,
      stateSelect,
      search,
      checkbox('profiled', 'Profiled only', 'Jobs that ran with --profile task, so profile_plot can chart them'),
      checkbox('attention', 'Needs attention',
        `Jobs that failed, ran out of memory or time, or used under ${T.warning}% of the CPU, memory or GPU they asked for`),
      el('span', { class: 'spacer' }),
      shell.count
    );
  }

  // A range whose jobs are still being listed shows a small spinner.
  function renderRangeButtons() {
    for (const [days, button] of shell.rangeButtons || []) {
      const busy = rangeListing(days);
      button.classList.toggle('is-loading', busy);
      button.setAttribute('aria-busy', String(busy));
      button.title = busy ? 'Still listing these jobs with sacct; the ones listed so far are shown' : '';
    }
  }

  function renderIntro() {
    const where = CONFIG.clusterName ? ` on ${CONFIG.clusterName}` : '';
    const range = S.range ? ` from ${fmtDay(S.range.start)} to ${fmtDay(S.range.end)}` : '';
    shell.intro.replaceChildren(
      `Your Slurm jobs${where}${range}, with how well each one used what it asked for, as reported by `,
      code(CMD.seff), '. Select a job to see seff’s full report, its job steps and, if it ran with ',
      code('--profile task'), ', the chart from ', code(CMD.profilePlot), '.'
    );
  }

  function renderTiles(list) {
    const finished = list.filter((job) => !ACTIVE.has(job.state)).length;
    const values = (kind) => list.filter((job) => job.m[kind]).map((job) => job.m[kind].percent);
    const tiles = [
      tile('Jobs', fmtInt(list.length), `${fmtInt(finished)} finished, ${fmtInt(list.length - finished)} running or waiting`),
      percentTile('cpu', values('cpu'), cpuOverall(list)),
      percentTile('mem', values('mem')),
      percentTile('time', values('time')),
      S.hasGpu ? percentTile('gpu', values('gpu')) : null,
      S.hasGpu ? percentTile('gpu_mem', values('gpu_mem')) : null,
      tile('Profiled jobs', fmtInt(list.filter(isProfiled).length), 'ran with --profile task')
    ];
    shell.tiles.replaceChildren(...tiles.filter(Boolean));
  }

  function tile(label, value, sub, extra) {
    return el('div', { class: 'tile' },
      el('p', { class: 'tile-label' }, label),
      el('p', { class: `tile-value${value === '–' ? ' is-empty' : ''}` }, value),
      extra || null,
      sub ? el('p', { class: 'tile-sub' }, sub) : null);
  }

  function percentTile(kind, values, note) {
    const kindInfo = KINDS[kind];
    const mid = median(values);
    if (mid === null) {
      let why = 'seff reported this for none of these jobs';
      if (S.queue.todo.length || S.queue.inflight) why = 'waiting for seff';
      else if (kind === 'gpu' || kind === 'gpu_mem') why = 'no GPU jobs among these';
      return tile(kindInfo.title, '–', why);
    }
    const t = kindInfo.judged ? tone(mid) : 'neutral';
    const meter = el('div', { class: 'meter-track', 'aria-hidden': 'true' },
      el('span', { class: `meter-fill${t === 'neutral' ? '' : ` tone-${t}`}`, style: `width:${Math.min(100, Math.max(0, mid))}%` }));
    const sub = `median of ${fmtInt(values.length)} job${values.length === 1 ? '' : 's'}${note ? ` · ${note}` : ''}`;
    return tile(kindInfo.title, fmtPct(mid), sub, meter);
  }

  // The share of all the core-time the jobs reserved that they used, from the
  // "X of Y core-walltime" in seff's CPU line.
  function cpuOverall(list) {
    let used = 0;
    let total = 0;
    for (const job of list) {
      const m = job.m.cpu;
      if (!m) continue;
      const u = durationSeconds(m.used);
      const t = durationSeconds(m.total);
      if (u === null || t === null) continue;
      used += u;
      total += t;
    }
    return total > 0 ? `${fmtPct((100 * used) / total)} of all reserved core time` : '';
  }

  function renderProgress() {
    if (!shell) return;
    renderRangeButtons();
    const lines = [listingLine(), seffLine()].filter(Boolean);
    const box = shell.progress;
    box.classList.toggle('is-error', lines.some((line) => line.classList.contains('is-error')));
    box.hidden = !lines.length;
    box.replaceChildren(...lines);
  }

  // How the listing of jobs with sacct is going, once the first jobs are shown.
  function listingLine() {
    // A failed step matters only if no other step has listed those jobs.
    const failures = S.listErrors.filter(({ days }) => !rangeListed(days));
    if (failures.length) {
      const failed = failures.map(({ days }) => (days ? `the last ${days} days` : `the last ${CONFIG.historyMonths || 3} months`));
      const err = failures[0].error;
      return el('div', { class: 'progress-line is-error' },
        el('span', { class: 'error-text' }, `Could not list your jobs from ${failed.join(' or ')}: ${err ? err.message : 'unknown error'}`),
        err && err.detail ? el('span', { class: 'muted' }, err.detail) : null,
        el('button', { class: 'btn btn-small', type: 'button', onclick: () => loadJobs() }, 'Try again'));
    }
    if (rangeListed(0) || !S.listing.size) return null;
    return el('div', { class: 'progress-line' },
      el('span', { class: 'spinner', 'aria-hidden': 'true' }),
      el('span', null, `Still listing your older jobs with sacct; the last ${Math.max(...S.listed)} days are shown so far…`));
  }

  function seffLine() {
    const q = S.queue;
    let eligible = 0;
    let done = 0;
    for (const job of S.jobs) {
      if (!seffEligible(job)) continue;
      eligible += 1;
      if (job.seff) done += 1;
    }
    if (q.error) {
      return el('div', { class: 'progress-line is-error' },
        el('span', { class: 'error-text' }, `seff could not be run: ${q.error.message}`),
        q.error.detail ? el('span', { class: 'muted' }, q.error.detail) : null,
        el('button', { class: 'btn btn-small', type: 'button', onclick: () => { q.error = null; pump(); } }, 'Try again'));
    }
    if (!q.todo.length && !q.inflight) return null;
    const percent = eligible ? (100 * done) / eligible : 0;
    const bar = el('div', { class: 'progress-bar', role: 'progressbar', 'aria-valuemin': '0',
      'aria-valuemax': String(eligible), 'aria-valuenow': String(done), 'aria-label': 'Jobs seff has reported on' },
    el('span', { style: `width:${percent}%` }));
    const label = q.paused
      ? `Paused: seff has reported on ${fmtInt(done)} of ${fmtInt(eligible)} finished jobs.`
      : `Running seff on your finished jobs, newest first: ${fmtInt(done)} of ${fmtInt(eligible)}…`;
    return el('div', { class: 'progress-line' },
      q.paused ? null : el('span', { class: 'spinner', 'aria-hidden': 'true' }),
      el('span', null, label),
      bar,
      el('button', { class: 'btn btn-small', type: 'button', onclick: () => { q.paused = !q.paused; pump(); } },
        q.paused ? 'Resume' : 'Pause'));
  }

  // ---- The job table ---------------------------------------------------------------

  function columns() {
    const cols = [
      { key: null, cls: 'expander', label: 'Details', hiddenLabel: true },
      { key: 'id', cls: 'job-id', label: 'Job ID' },
      { key: 'name', cls: 'col-name job-name', label: 'Name' },
      { key: 'state', label: 'State' },
      { key: 'when', cls: 'col-when dim', label: 'Finished' },
      { key: 'elapsed', cls: 'col-elapsed num dim', label: 'Elapsed' },
      { key: 'asked', cls: 'col-asked dim', label: 'Asked for' },
      { key: 'time', cls: 'col-time num', label: 'Time used', metric: 'time' },
      { key: 'cpu', cls: 'num', label: 'CPU', metric: 'cpu' },
      { key: 'mem', cls: 'num', label: 'Memory', metric: 'mem' }
    ];
    if (S.hasGpu) {
      cols.push({ key: 'gpu', cls: 'col-gpu num', label: 'GPU', metric: 'gpu' });
      cols.push({ key: 'gpu_mem', cls: 'col-gpu num', label: 'GPU memory', metric: 'gpu_mem' });
    }
    cols.push({ key: 'profile', cls: 'profile', label: 'Profile' });
    return cols;
  }

  function renderTable(list) {
    const focusedId = document.activeElement && document.activeElement.closest &&
      document.activeElement.closest('tr.job') ? document.activeElement.closest('tr.job').dataset.id : null;

    if (!S.jobs.length) {
      const months = CONFIG.historyMonths || 3;
      shell.table.replaceChildren(S.listing.size
        ? el('div', { class: 'empty' }, spinnerLine('No recent jobs; still listing your older jobs with sacct…'))
        : el('div', { class: 'empty' }, `You have no Slurm jobs in the last ${months} months. Jobs you run will show up here.`));
      return;
    }

    const cols = columns();
    const sorted = sortedJobs(list);
    const pages = Math.max(1, Math.ceil(sorted.length / S.pageSize));
    S.page = Math.min(Math.max(1, S.page), pages);
    const first = (S.page - 1) * S.pageSize;
    const shown = sorted.slice(first, first + S.pageSize);

    const headRow = el('tr', null, cols.map((col) => headerCell(col)));
    const body = el('tbody');
    for (const job of shown) {
      body.append(jobRow(job, cols));
      if (S.open.has(job.id)) body.append(panelRow(job, cols.length));
    }
    if (!shown.length) {
      body.append(el('tr', null, el('td', { colspan: String(cols.length), class: 'empty' },
        rangeListing(S.filters.days) ? 'No jobs listed here yet; still listing your jobs with sacct…' : 'No jobs match these filters.')));
    }

    const table = el('table', { class: S.hasGpu ? 'jobs has-gpu' : 'jobs' }, el('thead', null, headRow), body);
    shell.table.replaceChildren(el('div', { class: 'jobs-scroll' }, table), pager(sorted.length, pages, first, shown.length));
    fitTable();

    if (focusedId) {
      const button = shell.table.querySelector(`tr.job[data-id="${CSS.escape(focusedId)}"] .expander button`);
      if (button) button.focus({ preventScroll: true });
    }
  }

  // The header stays in view as the page scrolls (see .jobs-scroll in
  // app.css); a table too wide to fit scrolls in a box of its own instead.
  function fitTable() {
    const box = shell && shell.table.querySelector('.jobs-scroll');
    const table = box && box.querySelector('table.jobs');
    if (!table) return;
    box.classList.remove('is-wide');
    box.classList.toggle('is-wide', table.offsetWidth > box.clientWidth + 1);
  }

  let fitQueued = false;
  window.addEventListener('resize', () => {
    if (fitQueued) return;
    fitQueued = true;
    requestAnimationFrame(() => {
      fitQueued = false;
      fitTable();
    });
  });

  function headerCell(col) {
    if (!col.key) return el('th', { class: col.cls, scope: 'col' }, el('span', { class: 'visually-hidden' }, col.label));
    const active = S.sort.key === col.key;
    const attrs = { class: col.cls || null, scope: 'col' };
    if (active) attrs['aria-sort'] = S.sort.dir > 0 ? 'ascending' : 'descending';
    const button = el('button', { class: 'sort', type: 'button' },
      col.label, el('span', { class: 'sort-mark', 'aria-hidden': 'true' }, active ? (S.sort.dir > 0 ? '▲' : '▼') : ''));
    button.addEventListener('click', () => {
      if (S.sort.key === col.key) S.sort.dir = -S.sort.dir;
      else S.sort = { key: col.key, dir: ['name', 'state'].includes(col.key) ? 1 : -1 };
      renderData();
    });
    return el('th', attrs, button);
  }

  function panelId(job) {
    return `panel-${job.id}`;
  }

  function panelRow(job, span) {
    return el('tr', { class: 'panel-row', id: panelId(job) },
      el('td', { colspan: String(span) }, panelFor(job).root));
  }

  function jobRow(job, cols) {
    const open = S.open.has(job.id);
    const tr = el('tr', { class: `job${open ? ' is-open' : ''}`, dataset: { id: job.id, stamp: rowStamp(job) } });
    for (const col of cols) tr.append(cell(job, col, open));
    tr.addEventListener('click', (event) => {
      if (event.target.closest('a, button, input, select, label')) return;
      const selection = window.getSelection ? String(window.getSelection()) : '';
      if (selection.length) return;
      toggle(job.id);
    });
    return tr;
  }

  function cell(job, col, open) {
    if (col.metric) return metricCell(job, col.metric, col.cls);
    switch (col.key) {
      case null: {
        const button = el('button', { type: 'button', 'aria-expanded': String(open), 'aria-controls': open ? panelId(job) : null,
          'aria-label': `${open ? 'Hide' : 'Show'} details of job ${job.id}` }, icon('chevron'));
        button.addEventListener('click', () => toggle(job.id));
        return el('td', { class: 'expander' }, button);
      }
      case 'id':
        return el('td', { class: col.cls }, job.id);
      case 'name':
        return el('td', { class: col.cls, title: job.name }, job.name);
      case 'state': {
        const info = stateInfo(job.state);
        const title = [job.state_detail, job.exit_code ? `exit code ${job.exit_code}` : ''].filter(Boolean).join(', ');
        return el('td', null, el('span', { class: `state tone-${info.tone}`, title }, info.label));
      }
      case 'when': {
        let text = fmtWhen(job.end);
        if (job.state === 'RUNNING') text = 'Running';
        else if (job.state === 'PENDING') text = 'Not started';
        else if (ACTIVE.has(job.state)) text = 'Not finished';
        return el('td', { class: col.cls, title: job.end || '' }, text || '–');
      }
      case 'elapsed':
        return el('td', { class: col.cls }, job.elapsed || '–');
      case 'asked':
        return el('td', { class: col.cls }, askedFor(job));
      case 'profile': {
        const td = el('td', { class: col.cls });
        if (isProfiled(job)) {
          td.append(icon('chart', 'profile-mark', 'Ran with --profile task: open the job for its profile_plot'));
        }
        return td;
      }
      default:
        return el('td');
    }
  }

  function askedFor(job) {
    if (!job.cpus) return '–';
    const parts = [`${job.cpus} CPU${job.cpus === 1 ? '' : 's'}`];
    if (job.req_mem) parts.push(job.req_mem);
    for (const gpu of job.gpus || []) {
      parts.push(`${gpu.count}× ${gpu.type ? gpu.type.toUpperCase() : 'GPU'}`);
    }
    return parts.join(' · ');
  }

  function metricCell(job, kind, cls) {
    const td = el('td', { class: cls });
    const m = job.m[kind];
    if (m) {
      const t = KINDS[kind].judged ? tone(m.percent) : 'neutral';
      const fill = el('span', { class: `meter-fill${t === 'neutral' ? '' : ` tone-${t}`}`,
        style: `width:${Math.min(100, Math.max(0, m.percent))}%` });
      td.append(el('span', { class: 'meter', title: `${m.label}: ${m.percent}%${m.detail ? `   ${m.detail}` : ''}` },
        el('span', { class: 'meter-track', 'aria-hidden': 'true' }, fill),
        el('span', { class: `meter-value${m.percent > 100 ? ' over' : ''}` }, fmtPct(m.percent)),
        KINDS[kind].judged ? el('span', { class: 'visually-hidden' }, ` (${TONE_WORDS[t]})`) : null));
      return td;
    }
    td.append(placeholder(job, kind));
    return td;
  }

  function placeholder(job, kind) {
    if (ACTIVE.has(job.state)) return el('span', { class: 'placeholder', title: 'seff reports on a job once it has finished' }, '–');
    if (!(job.cpus > 0)) return el('span', { class: 'placeholder', title: 'The job never started' }, '–');
    if (!job.seff) return el('span', { class: 'waiting', title: 'Waiting for seff' }, '···');
    if (job.seff.error && kind === 'cpu') {
      return el('span', { class: 'flag-error', title: job.seff.error, role: 'img', 'aria-label': `seff error: ${job.seff.error}` }, '!');
    }
    return el('span', { class: 'placeholder', title: 'seff did not report this' }, '–');
  }

  function pager(total, pages, first, count) {
    const sizes = el('select', { 'aria-label': 'Jobs per page' },
      [25, 50, 100, 250].map((n) => el('option', { value: String(n), selected: n === S.pageSize }, `${n} per page`)));
    sizes.addEventListener('change', () => {
      S.pageSize = Number(sizes.value);
      S.page = 1;
      renderData();
    });
    const go = (page) => () => {
      S.page = page;
      renderData();
      shell.table.scrollIntoView({ block: 'start', behavior: 'smooth' });
    };
    return el('div', { class: 'pager' },
      el('span', null, total ? `Showing ${fmtInt(first + 1)}–${fmtInt(first + count)} of ${fmtInt(total)}` : ''),
      el('div', { class: 'pages' },
        sizes,
        el('button', { class: 'btn btn-small', type: 'button', disabled: S.page <= 1, onclick: go(S.page - 1) }, 'Previous'),
        el('span', null, `Page ${fmtInt(S.page)} of ${fmtInt(pages)}`),
        el('button', { class: 'btn btn-small', type: 'button', disabled: S.page >= pages, onclick: go(S.page + 1) }, 'Next')));
  }

  // Opens or closes a job in place, without redrawing the rest of the table.
  function toggle(id) {
    const job = S.byId.get(id);
    const tr = job && shell.table.querySelector(`tr.job[data-id="${CSS.escape(id)}"]`);
    if (!tr) return;
    const hadFocus = tr.contains(document.activeElement);
    if (S.open.has(id)) {
      S.open.delete(id);
      const row = document.getElementById(panelId(job));
      if (row) row.remove();
    } else {
      S.open.add(id);
      tr.after(panelRow(job, columns().length));
    }
    const fresh = jobRow(job, columns());
    tr.replaceWith(fresh);
    if (hadFocus) fresh.querySelector('.expander button').focus({ preventScroll: true });
  }

  // ---- An opened job ------------------------------------------------------------

  function panelFor(job) {
    let panel = S.panels.get(job.id);
    if (!panel) {
      panel = makePanel(job);
      S.panels.set(job.id, panel);
      loadPanel(job, panel, false);
    }
    return panel;
  }

  function sectionHead(title, command, ...extra) {
    return el('div', { class: 'panel-head' }, el('h3', null, title), extra, command ? el('code', { class: 'cmd', title: command }, `$ ${command}`) : null);
  }

  function makePanel(job) {
    const p = {};
    p.seffBody = el('div');
    p.advice = el('ul', { class: 'advice' });
    p.facts = el('dl', { class: 'facts' });
    p.steps = el('div', { class: 'table-scroll' }, spinnerLine('Running sacct…'));
    p.stepsCmd = el('code', { class: 'cmd' }, `$ ${CMD.sacct} -j ${job.id}`);
    p.profile = el('div');
    p.script = el('div', null, spinnerLine('Running sacct --batch-script…'));
    p.rerun = el('button', { class: 'btn btn-small', type: 'button', onclick: () => loadPanel(job, p, true) }, 'Run seff again');

    p.root = el('div', { class: 'panel' },
      el('div', { class: 'panel-grid' },
        el('section', { 'aria-label': `seff report for job ${job.id}` },
          sectionHead('Efficiency (seff)', `${CMD.seff} ${job.id}`, p.rerun), p.seffBody, p.advice),
        el('section', { 'aria-label': `Details of job ${job.id}` },
          sectionHead('Job', null), p.facts)),
      el('section', { 'aria-label': `Steps of job ${job.id}` },
        el('div', { class: 'panel-head' }, el('h3', null, 'Job steps (sacct)'), p.stepsCmd), p.steps),
      el('section', { 'aria-label': `Profile of job ${job.id}` },
        sectionHead('Usage over time (profile_plot)', `${CMD.profilePlot} ${job.id}`), p.profile),
      el('details', { class: 'script' }, el('summary', null, 'Batch script'), p.script));

    showFacts(p, listingFacts(job));
    showSeff(job, p, job.seff, true);
    if (!(job.cpus > 0)) {
      p.profile.replaceChildren(el('p', { class: 'message' }, ACTIVE.has(job.state)
        ? 'The job has not started yet, so there is nothing to plot.'
        : 'The job never started, so there is nothing to plot.'));
      p.profileDone = true;
    } else if (isProfiled(job)) {
      startProfile(job, p);
    } else {
      p.profile.replaceChildren(spinnerLine('Checking whether the job ran with --profile task…'));
    }
    return p;
  }

  async function loadPanel(job, p, fresh) {
    p.rerun.disabled = true;
    if (fresh) p.seffBody.prepend(spinnerLine('Running seff again…'));
    else if (!job.seff) showSeff(job, p, null, false);
    try {
      const data = await loadDetails(job, fresh);
      if (data.seff) {
        data.seff.fresh = true;
        setSeff(job, data.seff);
      }
      if (data.profile) job.detailProfile = data.profile;
      showSeff(job, p, job.seff, false);
      showFacts(p, data.job && Object.keys(data.job).length ? sacctFacts(data.job) : listingFacts(job));
      showSteps(job, p, data.steps);
      showScript(p, data.script);
      if (!p.profileStarted && !p.profileDone) {
        if (isProfiled(job)) startProfile(job, p);
        else showProfileHint(job, p);
      }
      scheduleRender();
    } catch (err) {
      const problem = el('div', { class: 'message' },
        el('p', { class: 'error-text' }, err.message), err.detail ? el('pre', { class: 'output' }, err.detail) : null);
      if (job.seff) {
        // Keep the report from earlier, and say that it could not be checked.
        if (job.seff.fresh) showSeff(job, p, job.seff, false);
        else showSeff(job, p, Object.assign({}, job.seff, { fresh: true }), false);
        p.seffBody.prepend(problem);
      } else {
        p.seffBody.replaceChildren(problem);
      }
      p.steps.replaceChildren(el('p', { class: 'muted small' }, 'Not available.'));
      p.script.replaceChildren(el('p', { class: 'muted small' }, 'Not available.'));
      if (!p.profileStarted && !p.profileDone) showProfileHint(job, p);
    } finally {
      p.rerun.disabled = false;
    }
  }

  function loadDetails(job, fresh) {
    if (!fresh && S.details.has(job.id)) return S.details.get(job.id);
    const promise = api(`api/job?id=${encodeURIComponent(job.id)}&raw=${encodeURIComponent(job.raw)}`);
    S.details.set(job.id, promise);
    promise.catch(() => S.details.delete(job.id));
    return promise;
  }

  // earlier: the report came from the background run, and is being re-run now.
  function showSeff(job, p, seff, earlier) {
    if (!seff) {
      if (ACTIVE.has(job.state) || !(job.cpus > 0)) {
        p.seffBody.replaceChildren(spinnerLine('Running seff…'));
      } else {
        p.seffBody.replaceChildren(spinnerLine(job.seffPending ? 'Waiting for seff…' : 'Running seff…'));
      }
      p.advice.replaceChildren();
      return;
    }
    const parts = [];
    if (seff.error) {
      parts.push(el('p', { class: 'error-text small' }, seff.error));
    }
    if (seff.text) parts.push(el('pre', { class: 'output' }, seff.text));
    else if (!seff.error) parts.push(el('p', { class: 'muted small' }, 'seff printed nothing for this job.'));
    if (seff.stderr) {
      parts.push(el('details', { class: 'small' }, el('summary', null, 'What seff printed on stderr'),
        el('pre', { class: 'output' }, seff.stderr)));
    }
    if (seff.fetched_at && earlier && !seff.fresh) {
      parts.push(el('p', { class: 'muted small' },
        `seff’s report from ${new Date(seff.fetched_at * 1000).toLocaleString('en-NZ')}; running seff again now…`));
    }
    p.seffBody.replaceChildren(...parts);
    // No pointers from a report seff could not finish.
    p.advice.replaceChildren(...(seff.error ? [] : advice(job, seff)));
  }

  // Short pointers drawn from seff's own numbers, following NeSI's guidance
  // on Finding Job Efficiency.
  function advice(job, seff) {
    const items = [];
    const m = {};
    for (const metric of seff.metrics || []) if (!m[metric.kind]) m[metric.kind] = metric;
    const item = (t, title, ...text) => items.push(el('li', { class: `tone-${t}` }, el('strong', null, `${title}: `), text));

    if (job.state === 'OUT_OF_MEMORY') {
      item('critical', 'Memory', 'the job ran out of memory and was stopped. Ask for more next time with ',
        code('--mem'), ' (or ', code('--mem-per-cpu'), ').');
    }
    if (job.state === 'TIMEOUT') {
      item('serious', 'Time', 'the job reached its time limit and was stopped. If it needed longer, ask for more with ',
        code('--time'), '; if it should have finished sooner, check its output for where it got stuck.');
    }
    if (m.mem && job.state !== 'OUT_OF_MEMORY' && m.mem.percent < T.warning) {
      const used = sizeBytes(m.mem.used);
      const parts = [`its peak memory use was ${m.mem.used || fmtPct(m.mem.percent)} of the ${m.mem.total || 'memory'} it asked for.`];
      if (used && (job.nodes || 1) === 1) {
        const suggestion = suggestMemory(used);
        parts.push(` For similar runs, about ${suggestion} (the peak plus a quarter) should be enough: `,
          code(`#SBATCH --mem=${suggestion}`), '.');
      }
      item(tone(m.mem.percent), 'Memory', ...parts);
    }
    const cores = parseInt((seff.info || {}).Cores, 10) || job.cpus || 0;
    if (m.cpu && m.cpu.percent < T.warning && cores > 1) {
      item(tone(m.cpu.percent), 'CPU', `its ${cores} cores were busy ${fmtPct(m.cpu.percent)} of the time. `,
        'If your program cannot keep them all busy, ask for fewer with ', code('--cpus-per-task'),
        ', or check that it really runs in parallel. ', link(DOCS.scaling, 'Job scaling'), ' explains how to choose.');
    }
    if (m.gpu && m.gpu.percent < T.warning) {
      item(tone(m.gpu.percent), 'GPU', `the GPU was busy ${fmtPct(m.gpu.percent)} of the time on average. `,
        'A GPU needs enough CPU cores to keep it fed: try more ', code('--cpus-per-task'), '. See ',
        link(DOCS.gpus, 'Using GPUs'), '.');
    }
    if (m.gpu_mem && m.gpu_mem.percent < T.warning) {
      item(tone(m.gpu_mem.percent), 'GPU memory',
        `its peak GPU memory use was ${m.gpu_mem.used || fmtPct(m.gpu_mem.percent)} of the ${m.gpu_mem.total || 'memory'} the GPU has. `,
        'A GPU with less memory may do the job as well. See ', link(DOCS.gpus, 'Using GPUs'), '.');
    }
    if (m.time && job.state === 'COMPLETED' && m.time.percent < 25 && (job.elapsed_s || 0) >= 60) {
      item('neutral', 'Time', `it finished in ${m.time.used || job.elapsed} of its ${m.time.total || job.timelimit} time limit. `,
        'A ', code('--time'), ' closer to what it needs, with some to spare, can help it start sooner.');
    }
    if (items.length) {
      items.push(el('li', { class: 'tone-neutral' }, 'More on reading these numbers: ',
        link(DOCS.efficiency, 'Finding Job Efficiency'), '.'));
    }
    return items;
  }

  // The peak plus a quarter, rounded up: to 100 MB below 1 GB, else to whole GB.
  function suggestMemory(bytes) {
    const want = bytes * 1.25;
    const MiB = 1024 * 1024;
    const GiB = 1024 * MiB;
    if (want < GiB) return `${Math.max(100, Math.ceil(want / MiB / 100) * 100)}M`;
    return `${Math.ceil(want / GiB)}G`;
  }

  const FACTS = [
    ['JobName', 'Name'], ['User', 'User'], ['Account', 'Project'], ['Partition', 'Partition'], ['QOS', 'QoS'],
    ['State', 'State'], ['Reason', 'Reason'], ['ExitCode', 'Exit code'], ['Submit', 'Submitted'],
    ['Start', 'Started'], ['End', 'Ended'], ['Elapsed', 'Elapsed'], ['Timelimit', 'Time limit'],
    ['AllocCPUS', 'CPUs'], ['ReqMem', 'Memory asked for'], ['NNodes', 'Nodes'], ['NodeList', 'Node list'],
    ['AllocTRES', 'Allocated'], ['WorkDir', 'Working directory'], ['SubmitLine', 'Submitted with']
  ];

  function sacctFacts(row) {
    const facts = [];
    for (const [key, label] of FACTS) {
      let value = row[key];
      if (value === undefined || value === null) continue;
      value = String(value).trim();
      if (!value || ['None', 'Unknown', 'None assigned'].includes(value)) continue;
      if (['Submit', 'Start', 'End'].includes(key) && parseTime(value)) value = `${fmtDay(value)} ${value.slice(11)}`;
      facts.push([label, value, ['WorkDir', 'SubmitLine', 'AllocTRES', 'NodeList'].includes(key)]);
    }
    return facts;
  }

  function listingFacts(job) {
    return sacctFacts({
      JobName: job.name, Account: job.account, Partition: job.partition, QOS: job.qos, State: job.state_detail,
      ExitCode: job.exit_code, Submit: job.submit, Start: job.start, End: job.end, Elapsed: job.elapsed,
      Timelimit: job.timelimit, AllocCPUS: job.cpus, ReqMem: job.req_mem, NNodes: job.nodes
    });
  }

  function showFacts(p, facts) {
    p.facts.replaceChildren(...facts.flatMap(([label, value, mono]) =>
      [el('dt', null, label), el('dd', null, mono ? code(value) : value)]));
  }

  function showSteps(job, p, steps) {
    if (!steps || !steps.columns || !steps.columns.length) {
      const why = steps && steps.error ? `sacct could not list the steps: ${steps.error}` : 'sacct has no steps for this job.';
      p.steps.replaceChildren(el('p', { class: 'muted small' }, why));
      return;
    }
    p.stepsCmd.textContent = `$ ${CMD.sacct} -j ${job.id} --format=${steps.columns.join(',')}`;
    p.stepsCmd.title = p.stepsCmd.textContent.slice(2);
    const table = el('table', { class: 'steps' },
      el('thead', null, el('tr', null, steps.columns.map((c) => el('th', { scope: 'col' }, c)))),
      el('tbody', null, steps.rows.map((row) => el('tr', null, steps.columns.map((c, i) =>
        el('td', { class: i === 0 && !String(row[c] || '').includes('.') ? 'job-line' : null }, row[c] || ''))))));
    p.steps.replaceChildren(table);
  }

  function showScript(p, script) {
    if (!script || !script.available) {
      p.script.replaceChildren(el('p', { class: 'muted small' },
        'No batch script is stored for this job (for example, it was started with srun or salloc).'));
      return;
    }
    p.script.replaceChildren(
      el('pre', { class: 'output is-script' }, script.text),
      script.truncated ? el('p', { class: 'muted small' }, 'Only the start of the script is shown.') : null);
  }

  // ---- profile_plot -------------------------------------------------------------------

  // The app sends the saved plot if there is one; fresh asks it to run
  // profile_plot again (and save the new plot).
  function loadProfile(job, fresh) {
    if (!fresh && S.profiles.has(job.raw)) return S.profiles.get(job.raw);
    const query = new URLSearchParams({ raw: job.raw, id: job.id, end: job.end || '' });
    if (fresh) query.set('fresh', '1');
    const promise = fetch(`${BASE}/api/profile?${query}`, { credentials: 'same-origin' })
      .then(async (response) => {
        const type = response.headers.get('content-type') || '';
        if (response.ok && !type.includes('application/json') && !type.includes('text/html')) {
          const blob = await response.blob();
          const saved = parseInt(response.headers.get('x-profile-plot-saved') || '', 10);
          return { url: URL.createObjectURL(blob), type, messages: response.headers.get('x-profile-plot-messages') || '',
            savedAt: Number.isFinite(saved) ? saved : null };
        }
        let data = null;
        try {
          data = type.includes('application/json') ? await response.json() : null;
        } catch (err) {
          data = null;
        }
        if (!data) return { error: 'The app did not answer. Your OnDemand session may have ended: reload the page.', retry: true };
        return { error: data.error || `profile_plot failed (HTTP ${response.status})`, detail: data.detail || '', retry: response.status !== 404 };
      })
      .catch((err) => ({ error: `Could not reach the app: ${err.message}`, retry: true }));
    S.profiles.set(job.raw, promise);
    promise.then((result) => { if (result.retry) S.profiles.delete(job.raw); });
    return promise;
  }

  function startProfile(job, p, fresh) {
    p.profileStarted = true;
    p.profile.replaceChildren(spinnerLine(`Running ${CMD.profilePlot}… this can take a little while.`));
    loadProfile(job, fresh).then((result) => {
      if (result.url) {
        const isImage = result.type.startsWith('image/');
        const ext = { 'image/png': 'png', 'image/svg+xml': 'svg', 'application/pdf': 'pdf' }[result.type.split(';')[0]] || 'png';
        // profile_plot's own notes, such as that it drew the chart remotely
        // (one per line of its stderr), without its "Writing <file>" line.
        const messages = result.messages.split(' | ')
          .map((m) => m.trim()).filter((m) => m && !/^Writing\s/.test(m));
        p.profile.replaceChildren(
          isImage
            ? el('div', { class: 'plot' }, el('img', { src: result.url, alt: `profile_plot chart for job ${job.id}: CPU, memory and I/O use over the job's run` }))
            : el('p', { class: 'message' }, `${CMD.profilePlot} made a ${ext.toUpperCase()} file.`),
          el('div', { class: 'plot-actions' },
            el('a', { class: 'btn btn-small', href: result.url, download: `${job.id}_profile.${ext}` }, `Download ${ext.toUpperCase()}`),
            el('a', { class: 'btn btn-small', href: result.url, target: '_blank', rel: 'noopener' }, 'Open full size'),
            el('button', { class: 'btn btn-small', type: 'button', onclick: () => startProfile(job, p, true) },
              `Run ${CMD.profilePlot} again`),
            result.savedAt
              ? el('span', { class: 'muted small' },
                `Saved plot, drawn by ${CMD.profilePlot} on ${new Date(result.savedAt * 1000).toLocaleString('en-NZ')}.`)
              : null,
            messages.length ? el('span', { class: 'muted small' }, messages.join(' ')) : null));
        return;
      }
      const profiled = isProfiled(job);
      p.profile.replaceChildren(el('div', { class: 'message' },
        el('p', null, profiled
          ? `${CMD.profilePlot} could not draw a plot for this job.`
          : `${CMD.profilePlot} found no profile for this job.`),
        result.detail ? el('pre', { class: 'output' }, result.detail) : el('p', { class: 'small' }, result.error),
        profiled
          ? el('p', { class: 'small' }, 'Profiles are kept for at least 30 days; older ones may be deleted or incomplete. See ',
            link(DOCS.profiling, 'Slurm Native Profiling'), '.')
          : profileHowTo(),
        el('p', null, el('button', { class: 'btn btn-small', type: 'button', onclick: () => startProfile(job, p, true) }, 'Try again'))));
    });
  }

  function profileHowTo() {
    return el('p', { class: 'small' }, 'To record how a job’s CPU, memory and I/O use change while it runs, add ',
      code('#SBATCH --profile task'), ' to its script (for jobs under an hour, also ', code('#SBATCH --acctg-freq=1'),
      '), then open the job here, or run ', code(`${CMD.profilePlot} <jobid>`), '. See ',
      link(DOCS.profiling, 'Slurm Native Profiling'), '.');
  }

  function showProfileHint(job, p) {
    p.profileDone = true;
    p.profile.replaceChildren(el('div', { class: 'message' },
      el('p', null, 'This job did not ask Slurm to profile it, so there is no profile_plot to show.'),
      profileHowTo(),
      el('p', null, el('button', { class: 'btn btn-small', type: 'button', onclick: () => startProfile(job, p, false) },
        `Run ${CMD.profilePlot} anyway`))));
  }

  // ---- Errors and the about section ----------------------------------------------------

  function errorCard(err) {
    const host = CONFIG.loginNode || '';
    return el('div', { class: 'error-card', role: 'alert' },
      el('h2', null, 'Could not load your jobs'),
      el('p', null, err ? err.message : 'Something went wrong.'),
      err && err.detail ? el('pre', { class: 'output' }, err.detail) : null,
      el('p', null, host
        ? `The app runs sacct and seff on ${host} as you, over SSH. If this keeps happening, check that you can open a shell on the cluster from OnDemand, then try again.`
        : 'If this keeps happening, contact support with the message above.'),
      el('button', { class: 'btn', type: 'button', onclick: () => loadJobs() }, 'Try again'));
  }

  function renderAbout() {
    if (shell.about.dataset.built) return;
    shell.about.dataset.built = '1';
    const a = S.about || {};
    const SSH_KEY = {
      exists: 'found', created: 'made by this app', authorized: 'authorised by this app',
      failed: 'could not be set up', disabled: ''
    };
    const facts = [
      ['Your user name', a.user],
      ['Commands run on', a.host ? `${a.host}${a.login_node ? ` (via ${a.login_node})` : ''}` : a.login_node],
      ['SSH key', SSH_KEY[a.ssh_key] === undefined ? a.ssh_key : SSH_KEY[a.ssh_key]],
      ['sacct', a.sacct], ['seff', a.seff], ['profile_plot', a.profile_plot], ['Slurm', a.slurm],
      ['Jobs listed in', a.seconds ? `${a.seconds} s` : ''],
      ['Saved reports and plots', a.saved_reports || 'not saved (the sqlite3 gem is not installed)']
    ].filter(([, value]) => value);
    const missing = ['seff', 'profile_plot'].filter((tool) => a.user && !a[tool]);

    const forget = el('button', { class: 'btn btn-small', type: 'button', disabled: !a.saved_reports },
      'Forget saved seff reports and plots');
    forget.addEventListener('click', async () => {
      forget.disabled = true;
      try {
        await api('api/reports', { method: 'DELETE' });
        forget.textContent = 'Forgotten: refresh to run seff on every job again';
      } catch (err) {
        forget.textContent = `Could not forget them: ${err.message}`;
      }
    });

    append(shell.about, [
      el('summary', null, 'About these numbers'),
      el('div', { class: 'about-body' },
        el('p', null, 'Each job’s efficiency is exactly what ', code(CMD.seff), ' reports for it, run as you on the cluster. ',
          'Opening a job runs seff again and shows its report as printed, along with sacct’s view of the job and its steps, ',
          'its batch script and, for jobs run with ', code('--profile task'), ', the chart from ', code(CMD.profilePlot), '.'),
        el('p', null, 'seff’s reports and profile_plot’s plots for finished jobs are saved, so next time seff only ',
          'runs on jobs it has not reported on yet, and a plot opens without running profile_plot again. ',
          'They are dropped automatically whenever seff or profile_plot itself changes.'),
        el('p', null, 'Read more: ', link(DOCS.efficiency, 'Finding Job Efficiency'), ' · ',
          link(DOCS.profiling, 'Slurm Native Profiling'), ' · ', link(DOCS.scaling, 'Job Scaling')),
        missing.length ? el('p', { class: 'error-text' }, `Not found on the cluster: ${missing.join(', ')}.`) : null,
        facts.length ? el('dl', { class: 'facts' }, facts.flatMap(([k, v]) => [el('dt', null, k), el('dd', null, code(String(v)))])) : null,
        Array.isArray(a.warnings) && a.warnings.length ? el('pre', { class: 'output' }, a.warnings.join('\n')) : null,
        el('p', null, forget))
    ]);
  }

  // ---- Start ---------------------------------------------------------------------------

  window.addEventListener('beforeunload', () => {
    for (const promise of S.profiles.values()) promise.then((p) => { if (p && p.url) URL.revokeObjectURL(p.url); });
  });

  loadJobs();
}());
