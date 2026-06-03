/**
 * CGRC Trainer PWA — app.js
 *
 * Mirrors CGRCTrainerApp.swift (Store, Leitner SR) and Views.swift
 * (quiz engine, adaptive pool, flashcards, concept review, progress).
 *
 * No external dependencies. All state in localStorage (key: cgrc_trainer_v1).
 * Requires questions.json served over HTTP (not file://).
 */

'use strict';

// ============================================================
//  Constants  (mirror CGRCTrainerApp.swift)
// ============================================================

const DOMAINS = {
  1: 'Governance, Risk & Compliance',
  2: 'Scope of the System',
  3: 'Control Selection & Approval',
  4: 'Control Implementation',
  5: 'Control Assessment / Audit',
  6: 'System Compliance',
  7: 'Compliance Maintenance'
};

const WEIGHTS = { 1:16, 2:10, 3:14, 4:17, 5:16, 6:14, 7:13 };

// Largest-remainder allocation of 125 exam items across domains
const EXAM_ALLOC = { 1:20, 2:13, 3:18, 4:21, 5:20, 6:17, 7:16 };

const BOX_INTERVALS_DAYS = [0, 1, 3, 7, 14, 30]; // Leitner schedule
const MASTERY_BOX   = 5;
const EXAM_ITEMS    = 125;
const EXAM_SECS     = 3 * 60 * 60; // 3 hours
const STORAGE_KEY   = 'cgrc_trainer_v1';

// Domain accent colours
const DOM_COLOR = {
  1:'#4a90d9', 2:'#7b68ee', 3:'#5cb85c',
  4:'#f0ad4e', 5:'#d9534f', 6:'#5bc0de', 7:'#9b59b6'
};

// ============================================================
//  Store  (mirrors Store class in CGRCTrainerApp.swift)
// ============================================================

class Store {
  constructor() {
    this.answered = 0;
    this.correct  = 0;
    this.quizzes  = 0;
    this.domA = {}; // {domain: attempts}
    this.domC = {}; // {domain: correct}
    this.wrongIDs = new Set();
    // items: {id: {box, seen, correct, due(ms epoch), last(ms|null)}}
    this.items = {};
    this._load();
  }

  // ── Derived ──────────────────────────────────────────────

  get seenCount()     { return Object.keys(this.items).length; }
  get masteredCount() { return Object.values(this.items).filter(s => s.box >= MASTERY_BOX).length; }

  get dueIDs() {
    const now = Date.now();
    return new Set(
      Object.entries(this.items)
        .filter(([, s]) => s.seen > 0 && s.box < MASTERY_BOX && s.due <= now)
        .map(([id]) => +id)
    );
  }

  boxCounts() {
    const b = Array(MASTERY_BOX + 1).fill(0);
    for (const s of Object.values(this.items))
      b[Math.min(MASTERY_BOX, Math.max(0, s.box))]++;
    return b;
  }

  // ── Mutations ─────────────────────────────────────────────

  _bump(id, isCorrect) {
    const st = this.items[id] ?? { box:0, seen:0, correct:0, due:0, last:null };
    st.seen++;
    st.last = Date.now();
    if (isCorrect) {
      st.correct++;
      st.box = Math.min(MASTERY_BOX, st.box + 1);
      this.wrongIDs.delete(id);
    } else {
      st.box = 0;
      this.wrongIDs.add(id);
    }
    const days = BOX_INTERVALS_DAYS[Math.min(st.box, BOX_INTERVALS_DAYS.length - 1)];
    st.due = Date.now() + days * 86_400_000;
    this.items[id] = st;
  }

  /** Graded quiz answer — updates both accuracy stats and mastery schedule. */
  record(domain, id, isCorrect) {
    this.answered++;
    this.domA[domain] = (this.domA[domain] ?? 0) + 1;
    if (isCorrect) {
      this.correct++;
      this.domC[domain] = (this.domC[domain] ?? 0) + 1;
    }
    this._bump(id, isCorrect);
    this._save();
  }

  /** Flashcard self-rating — mastery schedule only, no accuracy stats. */
  reviewCard(id, isCorrect) { this._bump(id, isCorrect); this._save(); }

  finishQuiz() { this.quizzes++; this._save(); }

  reset() {
    this.answered = 0; this.correct = 0; this.quizzes = 0;
    this.domA = {}; this.domC = {}; this.wrongIDs = new Set(); this.items = {};
    this._save();
  }

  // ── Persistence ───────────────────────────────────────────

  _save() {
    const itemObj = {};
    for (const [id, s] of Object.entries(this.items))
      itemObj[id] = [s.box, s.seen, s.correct, s.due/1000, s.last ? s.last/1000 : -1];
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        answered: this.answered, correct: this.correct, quizzes: this.quizzes,
        domA: this.domA, domC: this.domC,
        wrong: [...this.wrongIDs],
        items: itemObj
      }));
    } catch(e) { console.warn('Save failed', e); }
  }

  _load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const d = JSON.parse(raw);
      this.answered = d.answered ?? 0;
      this.correct  = d.correct  ?? 0;
      this.quizzes  = d.quizzes  ?? 0;
      this.domA     = d.domA     ?? {};
      this.domC     = d.domC     ?? {};
      this.wrongIDs = new Set(d.wrong ?? []);
      for (const [k, v] of Object.entries(d.items ?? {})) {
        if (v.length >= 4)
          this.items[+k] = {
            box: v[0], seen: v[1], correct: v[2],
            due:  v[3] * 1000,
            last: v.length >= 5 && v[4] >= 0 ? v[4] * 1000 : null
          };
      }
    } catch(e) { console.error('Load error', e); }
  }
}

// ============================================================
//  Pool helpers
// ============================================================

function shuffle(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function pct(n, d) { return d > 0 ? Math.round(100 * n / d) : 0; }

/**
 * Adaptive pool: over-samples weak domains.
 * domain weight = 1.0 (100% acc) … 3.0 (0% acc); < 5 answered → neutral 2.0.
 * Mirrors domainWeights() + adaptivePool() from Views.swift.
 */
function adaptivePool(questions, store, count) {
  const domW = {};
  for (let d = 1; d <= 7; d++) {
    const a = store.domA[d] ?? 0;
    const c = store.domC[d] ?? 0;
    domW[d] = a < 5 ? 2.0 : Math.max(1.0, 3.0 - 2.0 * c / a);
  }

  // Build weighted pool (repeat each question proportional to domain weight)
  const pool = [];
  for (const q of questions) {
    const reps = Math.max(1, Math.round((domW[q.domain] ?? 2.0) * 8));
    for (let i = 0; i < reps; i++) pool.push(q);
  }

  // Shuffle, then deduplicate
  const shuffled = shuffle(pool);
  const seen = new Set(), result = [];
  for (const q of shuffled) {
    if (!seen.has(q.id)) { seen.add(q.id); result.push(q); }
    if (result.length >= count) break;
  }

  // Fallback: top up from remaining questions if needed
  if (result.length < count) {
    for (const q of shuffle(questions)) {
      if (!seen.has(q.id)) { seen.add(q.id); result.push(q); }
      if (result.length >= count) break;
    }
  }
  return result;
}

/**
 * Exact 125-item exam pool — largest-remainder allocation by domain.
 * Mirrors examPool() in Views.swift. Allocation: D1:20 D2:13 D3:18 D4:21 D5:20 D6:17 D7:16
 */
function examPool(questions) {
  const result = [];
  for (let d = 1; d <= 7; d++) {
    const pool = shuffle(questions.filter(q => q.domain === d));
    result.push(...pool.slice(0, EXAM_ALLOC[d]));
  }
  return shuffle(result);
}

// ============================================================
//  DOM helpers
// ============================================================

/**
 * Minimal createElement helper. Attrs: class, style (string), value, checked,
 * selected, disabled, onXxx (event handlers). Children: strings or Elements.
 */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined) continue;
    switch (k) {
      case 'class':    el.className = v; break;
      case 'style':    el.style.cssText = v; break;
      case 'value':    el.value = v; break;
      case 'checked':  el.checked  = Boolean(v); break;
      case 'selected': el.selected = Boolean(v); break;
      case 'disabled': el.disabled = Boolean(v); break;
      default:
        if (k.startsWith('on'))
          el.addEventListener(k.slice(2).toLowerCase(), v);
        else
          el.setAttribute(k, String(v));
    }
  }
  for (const child of children) {
    if (child == null) continue;
    if (typeof child === 'string') el.appendChild(document.createTextNode(child));
    else if (child instanceof Node) el.appendChild(child);
    else if (Array.isArray(child)) child.forEach(c => c instanceof Node && el.appendChild(c));
  }
  return el;
}

function masteryTag(id, store) {
  const s = store.items[id];
  if (!s || s.seen === 0) return { text: 'New',      cls: 'tag-new' };
  if (s.box >= MASTERY_BOX) return { text: 'Mastered', cls: 'tag-mastered' };
  return { text: `Box ${s.box}`, cls: 'tag-box' };
}

function domTag(domain) {
  const color = DOM_COLOR[domain] ?? '#888';
  return h('span', {
    class: 'dom-tag',
    style: `background:${color}22;color:${color}`
  }, `D${domain} · ${DOMAINS[domain]}`);
}

function formatTime(secs) {
  const hh = Math.floor(secs / 3600);
  const mm = Math.floor((secs % 3600) / 60);
  const ss = secs % 60;
  return `${hh}:${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
}

// ============================================================
//  App
// ============================================================

class App {
  constructor(questions, store) {
    this.questions = questions;
    this.store     = store;
    this.tab       = 'quiz';
    this.state     = {};      // tab-local state
    this._timerID  = null;
    this._prevTab  = null;
    this._prevScr  = null;
    this.render();
  }

  // ── Navigation ────────────────────────────────────────────

  setTab(t) {
    this._clearTimer();
    this.tab = t;
    this.state = {};
    this.render();
  }

  go(newState) {
    this.state = newState;
    this.render();
  }

  // ── Render ────────────────────────────────────────────────

  render() {
    // Update tab bar highlights
    document.querySelectorAll('.tab-btn').forEach(btn =>
      btn.classList.toggle('active', btn.dataset.tab === this.tab)
    );

    const viewEl = document.getElementById('view');
    const sameView = this._prevTab === this.tab && this._prevScr === (this.state.screen ?? '');
    const scrollTop = sameView ? viewEl.scrollTop : 0;

    viewEl.innerHTML = '';
    switch (this.tab) {
      case 'quiz':       viewEl.append(this._renderQuiz());       break;
      case 'flashcards': viewEl.append(this._renderFlash());      break;
      case 'concepts':   viewEl.append(this._renderConcepts());   break;
      case 'progress':   viewEl.append(this._renderProgress());   break;
    }

    this._prevTab = this.tab;
    this._prevScr = this.state.screen ?? '';
    viewEl.scrollTop = scrollTop;
  }

  // ============================================================
  //  Quiz tab
  // ============================================================

  _renderQuiz() {
    const s = this.state;
    if (!s.screen)              return this._quizSetup();
    if (s.screen === 'running') return this._quizRunning();
    if (s.screen === 'results') return this._quizResults();
    return this._quizSetup();
  }

  // ── Setup screen ──────────────────────────────────────────

  _quizSetup() {
    const { store, questions: qs } = this;
    const dueCount  = store.dueIDs.size;
    const weakCount = store.wrongIDs.size;

    const wrap = h('div', {class: 'screen'});

    // Header
    wrap.append(
      h('div', {class: 'screen-hdr'},
        h('h1', {}, 'CGRC Trainer'),
        h('p',  {class: 'screen-sub'}, `${qs.length} questions · 7 domains`)
      )
    );

    // ── Quick modes card ──
    const quickCard = h('div', {class: 'card'});
    quickCard.append(h('div', {class: 'sec-title'}, 'Quick Start'));

    quickCard.append(h('button', {
      class: 'btn btn-primary btn-block',
      onClick: () => this._startExam()
    }, '🎓  Full Mock Exam — 125 questions · 3 hours'));

    const dueBtn = h('button', {
      class: `btn btn-block ${dueCount > 0 ? 'btn-accent' : ''}`,
      disabled: dueCount === 0,
      onClick: () => this._startQuiz({ source: 'due' })
    }, `⏱  Spaced Review · ${dueCount} due`);
    quickCard.append(dueBtn);

    const weakBtn = h('button', {
      class: `btn btn-block ${weakCount > 0 ? 'btn-warn' : ''}`,
      disabled: weakCount === 0,
      onClick: () => this._startQuiz({ source: 'weak' })
    }, `⚡  Drill Weak · ${weakCount} questions`);
    quickCard.append(weakBtn);

    wrap.append(quickCard);

    // ── Custom quiz card ──
    const customCard = h('div', {class: 'card'});
    customCard.append(h('div', {class: 'sec-title'}, 'Custom Quiz'));

    let selDomain = 0, selCount = 20, selInstant = true;

    // Domain picker
    const domSel = h('select', {class: 'sel',
      onChange: e => { selDomain = +e.target.value; }
    });
    domSel.append(h('option', {value: '0'}, 'All Domains (adaptive)'));
    for (let d = 1; d <= 7; d++) {
      const n = qs.filter(q => q.domain === d).length;
      domSel.append(h('option', {value: String(d)}, `D${d}: ${DOMAINS[d]} (${n})`));
    }
    customCard.append(h('label', {class: 'field-lbl'}, 'Domain'), domSel);

    // Length chips
    const counts = [10, 20, 30, 50, 75];
    const chipRow = h('div', {class: 'chip-row'});
    for (const c of counts) {
      const chip = h('button', {
        class: `chip ${c === selCount ? 'active' : ''}`,
        onClick: e => {
          selCount = c;
          chipRow.querySelectorAll('.chip').forEach(x => x.classList.remove('active'));
          e.currentTarget.classList.add('active');
        }
      }, String(c));
      chipRow.append(chip);
    }
    customCard.append(h('label', {class: 'field-lbl'}, 'Length'), chipRow);

    // Mode chips
    const modeRow = h('div', {class: 'chip-row'});
    for (const [label, val] of [['Instant feedback', true], ['Exam style', false]]) {
      const chip = h('button', {
        class: `chip ${val === selInstant ? 'active' : ''}`,
        onClick: e => {
          selInstant = val;
          modeRow.querySelectorAll('.chip').forEach(x => x.classList.remove('active'));
          e.currentTarget.classList.add('active');
        }
      }, label);
      modeRow.append(chip);
    }
    customCard.append(h('label', {class: 'field-lbl'}, 'Mode'), modeRow);

    customCard.append(h('button', {
      class: 'btn btn-primary btn-block mt-md',
      onClick: () => this._startQuiz({ domain: selDomain, count: selCount, instant: selInstant })
    }, 'Start Quiz →'));

    wrap.append(customCard);

    // ── Mastery footer ──
    const { masteredCount: mastered, seenCount: seen } = store;
    const total = qs.length;
    wrap.append(h('div', {class: 'card mastery-footer'},
      h('div', {class: 'mast-stat'},
        h('span', {class: 'mn'}, `${mastered}`),
        h('span', {class: 'ml'}, `of ${total} mastered`)
      ),
      h('div', {class: 'mast-stat'},
        h('span', {class: 'mn'}, String(seen)),
        h('span', {class: 'ml'}, 'seen')
      ),
      h('div', {class: 'mast-stat'},
        h('span', {class: `mn ${dueCount > 0 ? 'accent' : ''}`}, String(dueCount)),
        h('span', {class: 'ml'}, 'due today')
      )
    ));

    return wrap;
  }

  // ── Start quiz ────────────────────────────────────────────

  _startQuiz({ domain=0, count=20, instant=true, source='normal', timeLimit=null } = {}) {
    this._clearTimer();
    const { questions: qs, store } = this;
    let pool;

    switch (source) {
      case 'due':
        { const ids = store.dueIDs; pool = shuffle(qs.filter(q => ids.has(q.id))); break; }
      case 'weak':
        pool = shuffle(qs.filter(q => store.wrongIDs.has(q.id)));
        break;
      case 'exam':
        pool = examPool(qs);
        break;
      default:
        pool = domain > 0
          ? shuffle(qs.filter(q => q.domain === domain)).slice(0, count)
          : adaptivePool(qs, store, count);
    }

    if (!pool.length) return; // nothing to quiz

    this.go({
      screen: 'running', items: pool, idx: 0,
      answers: {}, instant, timeLimit,
      remaining: timeLimit, source
    });

    if (timeLimit) this._startTimer();
  }

  _startExam() {
    this._startQuiz({ source: 'exam', instant: false, timeLimit: EXAM_SECS });
  }

  // ── Timer ─────────────────────────────────────────────────

  _startTimer() {
    this._clearTimer();
    this._timerID = setInterval(() => {
      const s = this.state;
      if (s.screen !== 'running') { this._clearTimer(); return; }
      s.remaining = (s.remaining ?? 1) - 1;
      if (s.remaining <= 0) { this._clearTimer(); this._finishQuiz(); return; }
      const el = document.querySelector('.timer');
      if (el) el.textContent = formatTime(s.remaining);
    }, 1000);
  }

  _clearTimer() {
    if (this._timerID) { clearInterval(this._timerID); this._timerID = null; }
  }

  // ── Running screen ────────────────────────────────────────

  _quizRunning() {
    const s = this.state;
    const { items, idx, answers, instant, timeLimit } = s;
    const q        = items[idx];
    const selected = answers[idx];
    const answered = selected !== undefined;
    const total    = items.length;

    const wrap = h('div', {class: 'screen'});

    // Progress header
    const hdr = h('div', {class: 'quiz-hdr'},
      h('span', {class: 'quiz-counter'}, `${idx + 1} / ${total}`),
      h('div',  {class: 'prog-bar'}, h('div', {class: 'prog-fill', style: `width:${pct(idx, total)}%`}))
    );
    if (timeLimit != null) hdr.append(h('span', {class: 'timer'}, formatTime(s.remaining ?? 0)));
    wrap.append(hdr);

    // Domain + question
    wrap.append(domTag(q.domain));
    wrap.append(h('p', {class: 'q-text'}, q.text));

    // Options
    const opts = h('div', {class: 'opts'});
    q.options.forEach((opt, i) => {
      let cls = 'opt';
      if (answered && instant) {
        if (i === q.answer)                  cls += ' cor-opt';
        else if (i === selected)             cls += ' wrg-opt';
      } else if (i === selected)             cls += ' sel-opt';

      opts.append(h('button', {class: cls, onClick: () => {
        if (answered) return;
        s.answers[idx] = i;
        if (instant) this.store.record(q.domain, q.id, i === q.answer);
        this.render();
      }},
        h('span', {class: 'opt-letter'}, String.fromCharCode(65 + i)),
        h('span', {class: 'opt-text'},   opt)
      ));
    });
    wrap.append(opts);

    // Explanation (instant mode, after answer)
    if (answered && instant) {
      const correct = selected === q.answer;
      wrap.append(h('div', {class: 'explain'},
        h('div', {class: `explain-verdict ${correct ? 'correct' : ''}`},
          correct ? '✓ Correct' : '✗ Incorrect'),
        h('p', {}, q.explain)
      ));
    }

    // Navigation
    const nav = h('div', {class: 'nav-row mt-sm'});
    if (idx > 0)
      nav.append(h('button', {class: 'btn btn-outline', onClick: () => { s.idx--; this.render(); }}, '← Back'));

    const canNext = answered || !instant;
    if (idx < total - 1) {
      nav.append(h('button', {
        class: 'btn btn-primary', disabled: !canNext,
        onClick: () => { s.idx++; this.render(); }
      }, 'Next →'));
    } else {
      nav.append(h('button', {
        class: 'btn btn-primary', disabled: !canNext && instant,
        onClick: () => this._finishQuiz()
      }, 'Finish →'));
    }
    wrap.append(nav);

    // Skip link in exam mode
    if (!instant) {
      wrap.append(h('div', {class: 'nav-row'},
        h('button', {class: 'btn btn-ghost btn-block', onClick: () => {
          if (idx < total - 1) { s.idx++; this.render(); }
          else this._finishQuiz();
        }}, 'Skip')
      ));
    }

    return wrap;
  }

  // ── Finish & tally ────────────────────────────────────────

  _finishQuiz() {
    this._clearTimer();
    const { items, answers, instant } = this.state;
    let correct = 0;

    items.forEach((q, i) => {
      const sel = answers[i];
      const ok  = sel === q.answer;
      if (!instant) {
        // Exam style: record here (instant records per-answer)
        this.store.record(q.domain, q.id, sel !== undefined ? ok : false);
      }
      if (ok) correct++;
    });

    this.store.finishQuiz();
    this.go({ screen: 'results', items, answers, correct, instant: this.state.instant, source: this.state.source });
  }

  // ── Results screen ────────────────────────────────────────

  _quizResults() {
    const { items, answers, correct, source } = this.state;
    const total  = items.length;
    const score  = pct(correct, total);
    const passed = score >= 70;

    const wrap = h('div', {class: 'screen'});

    // Score ring
    wrap.append(h('div', {class: 'score-wrap'},
      h('div', {class: `score-ring ${passed ? 'ring-pass' : 'ring-fail'}`},
        h('div', {class: 'score-num'}, `${score}%`),
        h('div', {class: 'score-frac'}, `${correct} / ${total}`)
      ),
      h('div', {class: 'score-label'},
        source === 'exam'
          ? (passed ? '✅ Passing score' : '📚 Keep studying — aim for 70%+')
          : `${correct} correct`
      )
    ));

    // Domain breakdown
    const byDom = {};
    items.forEach((q, i) => {
      if (!byDom[q.domain]) byDom[q.domain] = { c:0, t:0 };
      byDom[q.domain].t++;
      if (answers[i] === q.answer) byDom[q.domain].c++;
    });

    const domCard = h('div', {class: 'card'});
    domCard.append(h('div', {class: 'sec-title'}, 'By Domain'));
    for (const [d, {c, t}] of Object.entries(byDom).sort(([a],[b]) => +a - +b)) {
      const p = pct(c, t);
      const color = DOM_COLOR[+d] ?? '#888';
      domCard.append(h('div', {class: 'dom-row'},
        h('span', {class: 'dom-label', style: `color:${color}`}, `D${d}`),
        h('div',  {class: 'mini-bar-wrap'},
          h('div', {class: 'mini-bar', style: `width:${p}%;background:${color}`})
        ),
        h('span', {class: 'dom-pct'}, `${p}% (${c}/${t})`)
      ));
    }
    wrap.append(domCard);

    // Wrong answers review
    const wrong = items.map((q, i) => ({q, i, sel: answers[i]})).filter(x => x.sel !== x.q.answer);
    if (wrong.length) {
      const rCard = h('div', {class: 'card'});
      rCard.append(h('div', {class: 'sec-title'}, `Review — ${wrong.length} missed`));
      for (const {q, sel} of wrong) {
        const item = h('div', {class: 'review-item'});
        item.append(h('p', {class: 'review-q'}, q.text));
        item.append(sel !== undefined
          ? h('p', {class: 'review-wrg'}, `✗ You: ${q.options[sel]}`)
          : h('p', {class: 'review-wrg'}, '✗ Not answered'));
        item.append(h('p', {class: 'review-cor'}, `✓ ${q.options[q.answer]}`));
        item.append(h('p', {class: 'review-expl'}, q.explain));
        rCard.append(item);
      }
      wrap.append(rCard);
    }

    // Actions
    wrap.append(h('div', {class: 'card'},
      h('button', {class: 'btn btn-primary btn-block', onClick: () => this.go({})}, '← New Quiz'),
      h('button', {class: 'btn btn-outline btn-block', onClick: () => this.setTab('progress')}, 'View Progress')
    ));

    return wrap;
  }

  // ============================================================
  //  Flashcards tab
  // ============================================================

  _renderFlash() {
    const s = this.state;
    if (!s.screen)              return this._flashSetup();
    if (s.screen === 'running') return this._flashRunning();
    if (s.screen === 'done')    return this._flashDone();
    return this._flashSetup();
  }

  _flashSetup() {
    const wrap = h('div', {class: 'screen'});
    wrap.append(h('div', {class: 'screen-hdr'}, h('h1', {}, 'Flashcards')));

    const card = h('div', {class: 'card'});
    let selDomain = 0;
    const sel = h('select', {class: 'sel', onChange: e => { selDomain = +e.target.value; }});
    sel.append(h('option', {value: '0'}, 'All Domains'));
    for (let d = 1; d <= 7; d++)
      sel.append(h('option', {value: String(d)}, `D${d}: ${DOMAINS[d]}`));
    card.append(h('label', {class: 'field-lbl'}, 'Domain'), sel);

    card.append(h('button', {class: 'btn btn-primary btn-block mt-md', onClick: () => {
      const pool = selDomain > 0
        ? this.questions.filter(q => q.domain === selDomain)
        : this.questions;
      this.go({ screen: 'running', items: shuffle(pool), idx: 0, flipped: false });
    }}, 'Start Flashcards →'));

    wrap.append(card);
    return wrap;
  }

  _flashRunning() {
    const s = this.state;
    const { items, idx, flipped } = s;
    const q     = items[idx];
    const total = items.length;
    const ml    = masteryTag(q.id, this.store);

    const wrap = h('div', {class: 'screen'});

    // Progress
    wrap.append(h('div', {class: 'quiz-hdr'},
      h('span', {class: 'quiz-counter'}, `${idx + 1} / ${total}`),
      h('div', {class: 'prog-bar'},
        h('div', {class: 'prog-fill', style: `width:${pct(idx, total)}%`}))
    ));

    // Card — tap to flip
    const card = h('div', {
      class: `flash-card ${flipped ? 'flipped' : ''}`,
      onClick: () => { s.flipped = !s.flipped; this.render(); }
    });

    if (!flipped) {
      card.append(
        h('p', {class: 'flash-hint'}, 'Tap to reveal answer'),
        domTag(q.domain),
        h('p', {class: 'flash-q'}, q.text)
      );
    } else {
      card.append(
        h('p', {class: 'flash-ans'}, q.options[q.answer]),
        h('p', {class: 'flash-expl'}, q.explain)
      );
    }
    wrap.append(card);

    // Rating buttons (visible only when flipped)
    if (flipped) {
      wrap.append(h('div', {class: 'flash-btns'},
        h('button', {class: 'btn btn-wrong', onClick: () => {
          this.store.reviewCard(q.id, false);
          this._nextCard(s);
        }}, '✗ Review Again'),
        h('button', {class: 'btn btn-correct', onClick: () => {
          this.store.reviewCard(q.id, true);
          this._nextCard(s);
        }}, '✓ Got It')
      ));
    }

    // Mastery tag
    wrap.append(h('div', {style: 'text-align:center;margin-top:8px'},
      h('span', {class: `tag ${ml.cls}`}, ml.text)
    ));

    return wrap;
  }

  _nextCard(s) {
    if (s.idx < s.items.length - 1) this.go({...s, idx: s.idx + 1, flipped: false});
    else this.go({ screen: 'done', total: s.items.length });
  }

  _flashDone() {
    const wrap = h('div', {class: 'screen'});
    wrap.append(h('div', {class: 'score-wrap'},
      h('div', {class: 'score-ring ring-pass'},
        h('div', {class: 'score-num'}, '✓'),
        h('div', {class: 'score-frac'}, `${this.state.total} cards`)
      ),
      h('div', {class: 'score-label'}, 'Session complete!')
    ));
    wrap.append(h('div', {class: 'card'},
      h('button', {class: 'btn btn-primary btn-block', onClick: () => this.go({})}, 'New Session'),
      h('button', {class: 'btn btn-outline btn-block', onClick: () => this.setTab('progress')}, 'View Progress')
    ));
    return wrap;
  }

  // ============================================================
  //  Concepts tab
  // ============================================================

  _renderConcepts() {
    const s          = this.state;
    const domain     = s.domain     ?? 0;
    const needsRev   = s.needsRev   ?? false;
    const search     = s.search     ?? '';
    const recallMode = s.recallMode ?? false;
    const revealed   = s.revealed   ?? new Set();
    const { store, questions: qs } = this;

    const wrap = h('div', {class: 'screen'});
    wrap.append(h('div', {class: 'screen-hdr'}, h('h1', {}, 'Concepts')));

    // ── Filter card ──
    const filters = h('div', {class: 'card'});

    // Domain selector
    const domSel = h('select', {class: 'sel', onChange: e => { s.domain = +e.target.value; this.render(); }});
    const allOpt = h('option', {value: '0'}, 'All Domains');
    if (domain === 0) allOpt.selected = true;
    domSel.append(allOpt);
    for (let d = 1; d <= 7; d++) {
      const opt = h('option', {value: String(d)}, `D${d}: ${DOMAINS[d]}`);
      if (domain === d) opt.selected = true;
      domSel.append(opt);
    }
    filters.append(h('label', {class: 'field-lbl'}, 'Domain'), domSel);

    // Toggles
    const tRow = h('div', {class: 'toggle-row'});

    const mkToggle = (label, checked, onChange) =>
      h('label', {class: 'toggle'},
        h('input', {type: 'checkbox', checked, onChange}),
        h('span', {class: 'toggle-track'}),
        label
      );

    tRow.append(mkToggle('Needs review only', needsRev, e => {
      s.needsRev = e.target.checked; this.render();
    }));
    tRow.append(mkToggle('Recall mode', recallMode, e => {
      s.recallMode = e.target.checked;
      s.revealed   = new Set(); // reset reveals when toggling
      this.render();
    }));
    filters.append(tRow);

    // Search
    const searchEl = h('input', {
      type: 'search', class: 'search-inp',
      placeholder: 'Search stem, answer, NIST reference…'
    });
    searchEl.value = search;
    searchEl.addEventListener('input', e => { s.search = e.target.value; this.render(); });
    filters.append(searchEl);

    wrap.append(filters);

    // ── Filter questions ──
    let list = qs;
    if (domain > 0) list = list.filter(q => q.domain === domain);
    if (needsRev) {
      list = list.filter(q => {
        const st = store.items[q.id];
        return store.wrongIDs.has(q.id) || (st && st.seen > 0 && st.box < MASTERY_BOX);
      });
    }
    if (search.trim()) {
      const srch = search.toLowerCase();
      list = list.filter(q =>
        q.text.toLowerCase().includes(srch) ||
        q.options[q.answer].toLowerCase().includes(srch) ||
        q.explain.toLowerCase().includes(srch)
      );
    }

    wrap.append(h('p', {class: 'concept-count'}, `${list.length} concepts`));

    if (!list.length) {
      wrap.append(h('p', {class: 'no-results'}, 'No concepts match your filters.'));
      return wrap;
    }

    // ── Concept cards ──
    for (const q of list) {
      const ml       = masteryTag(q.id, store);
      const isReveal = revealed.has(q.id);
      const color    = DOM_COLOR[q.domain] ?? '#888';

      const card = h('div', {class: 'concept-card'});

      card.append(h('div', {class: 'concept-hdr'},
        h('span', {class: 'dom-tag-sm', style: `color:${color}`}, `D${q.domain}`),
        h('span', {class: `tag ${ml.cls}`}, ml.text)
      ));

      card.append(h('p', {class: 'concept-stem'}, q.text));

      if (recallMode && !isReveal) {
        card.append(h('button', {class: 'reveal-btn', onClick: () => {
          const nr = new Set(revealed); nr.add(q.id);
          s.revealed = nr; this.render();
        }}, 'Tap to reveal answer'));
      } else {
        card.append(
          h('p', {class: 'concept-ans'},  q.options[q.answer]),
          h('p', {class: 'concept-expl'}, q.explain)
        );
      }

      wrap.append(card);
    }

    return wrap;
  }

  // ============================================================
  //  Progress tab
  // ============================================================

  _renderProgress() {
    const { store, questions: qs } = this;
    const total = qs.length;

    const wrap = h('div', {class: 'screen'});
    wrap.append(h('div', {class: 'screen-hdr'}, h('h1', {}, 'Progress')));

    // ── Overall accuracy ──
    const acc = pct(store.correct, store.answered);
    wrap.append(h('div', {class: 'card'},
      h('div', {class: 'sec-title'}, 'Overall'),
      h('div', {class: 'stat-row'},
        h('div', {class: 'big-stat'},
          h('div', {class: 'big-num'}, store.answered > 0 ? `${acc}%` : '—'),
          h('div', {class: 'big-lbl'}, 'Accuracy')
        ),
        h('div', {class: 'big-stat'},
          h('div', {class: 'big-num'}, String(store.answered)),
          h('div', {class: 'big-lbl'}, 'Answered')
        ),
        h('div', {class: 'big-stat'},
          h('div', {class: 'big-num'}, String(store.quizzes)),
          h('div', {class: 'big-lbl'}, 'Quizzes')
        )
      )
    ));

    // ── Domain accuracy ──
    const domCard = h('div', {class: 'card'});
    domCard.append(h('div', {class: 'sec-title'}, 'By Domain'));
    for (let d = 1; d <= 7; d++) {
      const a = store.domA[d] ?? 0;
      const c = store.domC[d] ?? 0;
      const p = pct(c, a);
      const color = DOM_COLOR[d];
      const weight = WEIGHTS[d];
      domCard.append(h('div', {class: 'dom-row'},
        h('span', {class: 'dom-label', style: `color:${color}`}, `D${d}`),
        h('div',  {class: 'mini-bar-wrap'},
          h('div', {class: 'mini-bar', style: `width:${p}%;background:${color}`})
        ),
        h('span', {class: 'dom-pct'}, a > 0 ? `${p}% (${c}/${a})` : `— · ${weight}% of exam`)
      ));
    }
    wrap.append(domCard);

    // ── Mastery ──
    const due = store.dueIDs.size;
    const mastCard = h('div', {class: 'card'});
    mastCard.append(h('div', {class: 'sec-title'}, 'Mastery (Leitner)'));
    mastCard.append(h('div', {class: 'stat-row'},
      h('div', {class: 'big-stat'},
        h('div', {class: 'big-num'}, String(store.masteredCount)),
        h('div', {class: 'big-lbl'}, `Mastered / ${total}`)
      ),
      h('div', {class: 'big-stat'},
        h('div', {class: 'big-num'}, String(store.seenCount)),
        h('div', {class: 'big-lbl'}, 'Seen')
      ),
      h('div', {class: 'big-stat'},
        h('div', {class: `big-num ${due > 0 ? 'accent' : ''}`}, String(due)),
        h('div', {class: 'big-lbl'}, 'Due today')
      )
    ));

    // Box pyramid
    const boxes = store.boxCounts();
    const boxLabels = ['New', '1 day', '3 days', '7 days', '14 days', 'Mastered'];
    const pyramid = h('div', {class: 'box-pyramid'});
    boxes.forEach((count, i) => {
      const p = pct(count, total);
      pyramid.append(h('div', {class: 'box-row'},
        h('span', {class: 'box-lbl'}, boxLabels[i]),
        h('div',  {class: 'box-bar-wrap'},
          h('div', {class: `box-bar ${i === MASTERY_BOX ? 'done' : ''}`,
            style: `width:${p}%;min-width:${count > 0 ? 4 : 0}px`})
        ),
        h('span', {class: 'box-count'}, String(count))
      ));
    });
    mastCard.append(pyramid);
    wrap.append(mastCard);

    // ── Reset ──
    wrap.append(h('div', {class: 'card'},
      h('button', {class: 'btn btn-danger btn-block', onClick: () => {
        if (confirm('Reset all progress? This cannot be undone.')) {
          store.reset(); this.render();
        }
      }}, '⚠ Reset All Progress')
    ));

    return wrap;
  }
}

// ============================================================
//  Bootstrap
// ============================================================

async function init() {
  // Show splash for 1.8 s
  const splash = document.getElementById('splash');
  setTimeout(() => splash.classList.add('hidden'), 1800);

  const view = document.getElementById('view');

  try {
    const res = await fetch('questions.json');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const questions = await res.json();

    const store = new Store();
    const app   = new App(questions, store);

    // Wire tab bar
    document.querySelectorAll('.tab-btn').forEach(btn =>
      btn.addEventListener('click', () => app.setTab(btn.dataset.tab))
    );

    // Register service worker (offline support)
    if ('serviceWorker' in navigator)
      navigator.serviceWorker.register('sw.js').catch(console.warn);

    console.log(`CGRC Trainer: ${questions.length} questions loaded`);
  } catch (e) {
    view.innerHTML = `
      <div class="error">
        <strong>Failed to load questions</strong><br><br>
        ${e.message}<br><br>
        <small>This app must be opened via a web server (http://), not directly from a file (file://).
        Try: <code>python3 -m http.server 8000</code> in the pwa/ folder, then open
        <a href="http://localhost:8000" style="color:inherit">http://localhost:8000</a>.</small>
      </div>`;
    splash.classList.add('hidden');
  }
}

document.addEventListener('DOMContentLoaded', init);
