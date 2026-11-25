/* Silvics 导航互动原型
 *
 * 回答两个问题：
 *   1. 三个模块各有一个入口，还是共用一个侧栏？（观感）
 *   2. 切走再切回，要不要回到原处？（状态）
 *
 * 数据全在内存，刷新即还原。变体用 ?variant=a|b|c|d 直链。
 */

const TODAY = '2026-11-24';

// ---------- 假数据 ----------

const NOTES = [
  {
    id: 'n1', title: '双向链接的边界', status: '成熟', updated: '11-22',
    tags: ['方法'], snippet: '链接不是目的，指向才是。',
    body: [
      '[[卡片盒笔记法]] 讲的是让笔记互相指向，但指向本身不产生价值。',
      '真正的问题是：这条链解决了我什么问题。',
      '我的做法是只在三种情况下加链接：术语要先解释、结论要先成立、反例需要对照。',
    ],
    backlinks: ['卡片盒笔记法', '写作即思考', '渐进式总结'],
    outgoing: ['卡片盒笔记法', '写作即思考'],
    mentions: ['标签与目录之争'],
  },
  {
    id: 'n2', title: '卡片盒笔记法', status: '成熟', updated: '11-20',
    tags: ['方法'], snippet: '卡片是单位，盒子是索引。',
    body: [
      '卡片盒的核心不是卡片，是索引：给每张卡片一个固定地址。',
      '地址让引用成为可能。没有地址，卡片只能靠记忆找。',
    ],
    backlinks: ['双向链接的边界', '渐进式总结'],
    outgoing: ['双向链接的边界'],
    mentions: [],
  },
  {
    id: 'n3', title: '写作即思考', status: '常青', updated: '11-18',
    tags: ['写作'], snippet: '写不出来，通常是没想清楚。',
    body: [
      '写作不是记录思考，是完成思考。',
      '句子写不通的地方，就是理解断掉的地方。',
    ],
    backlinks: ['双向链接的边界'],
    outgoing: ['小步重构'],
    mentions: ['读写分离'],
  },
  {
    id: 'n4', title: '渐进式总结', status: '生长', updated: '11-15',
    tags: ['方法'], snippet: '第一遍只划重点，第二遍只留结论。',
    body: [
      '一口气总结到位是幻觉。第一遍标粗，第二遍摘句，第三遍写自己的话。',
    ],
    backlinks: ['卡片盒笔记法'],
    outgoing: ['双向链接的边界', '信息的半衰期'],
    mentions: [],
  },
  {
    id: 'n5', title: '标签与目录之争', status: '生长', updated: '11-12',
    tags: ['设计'], snippet: '目录是给作者看的，标签是给检索用的。',
    body: [
      '目录只有一条归属路径，标签可以多条。两者不冲突，选一个当主结构就行。',
    ],
    backlinks: [],
    outgoing: ['双向链接的边界'],
    mentions: ['检索比分类重要'],
  },
  {
    id: 'n6', title: '小步重构', status: '常青', updated: '11-09',
    tags: ['设计'], snippet: '每次只改一处，改完立刻验证。',
    body: [
      '大重构的风险不在技术，在验证：改完十处，出问题不知道是哪一处。',
    ],
    backlinks: ['写作即思考'],
    outgoing: [],
    mentions: [],
  },
  {
    id: 'n7', title: '读写分离', status: '生长', updated: '11-05',
    tags: ['写作'], snippet: '读的时候只收集，写的时候只输出。',
    body: [
      '同时读和写，两边都做不好。分开时段，效率反而高。',
    ],
    backlinks: [],
    outgoing: ['写作即思考'],
    mentions: [],
  },
  {
    id: 'n8', title: '概念的粒度', status: '幼苗', updated: '10-30',
    tags: ['设计'], snippet: '一条笔记只讲一件事。',
    body: [
      '粒度太粗，链接指不到具体结论；太细，链接又碎成一地。',
    ],
    backlinks: [],
    outgoing: [],
    mentions: [],
  },
  {
    id: 'n9', title: '笔记的复用', status: '幼苗', updated: '10-28',
    tags: ['方法'], snippet: '能复用一次，就值回记录成本。',
    body: [
      '判断一条笔记值不值，看它有没有被第二次引用。',
    ],
    backlinks: [],
    outgoing: [],
    mentions: [],
  },
];

const JOURNALS = [
  {
    id: 'j1', date: '2026-11-24', weekday: '周一', carriedFrom: '2026-11-23',
    sections: [
      { title: '今天做了什么', items: [
        { text: '写剪藏需求文档', done: false },
        { text: '修补全面板徽标', done: true },
      ] },
      { title: '想到的事', items: [
        { text: '导航按模块拆，还是留一个总入口', done: false },
      ] },
    ],
    backlinks: ['双向链接的边界'],
  },
  {
    id: 'j2', date: '2026-11-23', weekday: '周日', carriedFrom: '2026-11-22',
    sections: [
      { title: '今天做了什么', items: [
        { text: '整理标签体系', done: true },
        { text: '重看日记混合模式的边界用例', done: false },
      ] },
    ],
    backlinks: [],
  },
  {
    id: 'j3', date: '2026-11-22', weekday: '周六', carriedFrom: '',
    sections: [
      { title: '今天做了什么', items: [
        { text: '散步四十分钟', done: true },
      ] },
      { title: '想到的事', items: [
        { text: '把设置也做成主窗口的标签页？', done: false },
        { text: '窄窗口下分段控件要退成下拉', done: false },
      ] },
    ],
    backlinks: ['写作即思考', '读写分离'],
  },
  {
    id: 'j4', date: '2026-11-21', weekday: '周五', carriedFrom: '2026-11-20',
    sections: [
      { title: '今天做了什么', items: [
        { text: '发 0.3.2', done: true },
      ] },
    ],
    backlinks: [],
  },
  {
    id: 'j5', date: '2026-11-20', weekday: '周四', carriedFrom: '',
    sections: [
      { title: '今天做了什么', items: [
        { text: '剪藏抓取失败的文案改成网页层原因', done: true },
      ] },
    ],
    backlinks: [],
  },
  {
    id: 'j6', date: '2026-10-31', weekday: '周六', carriedFrom: '',
    sections: [
      { title: '今天做了什么', items: [
        { text: '给日记加上承接', done: true },
        { text: '补三份同步冲突的测试', done: false },
      ] },
    ],
    backlinks: [],
  },
];

const CLIPS = [
  {
    id: 'c1', title: '间隔重复的三种做法', site: '少数派', date: '11-20',
    url: 'https://sspai.com/post/88001', status: 'unread', ai: 'done',
    tags: ['阅读', '方法'],
    summary: '文章对比三种复习节奏：固定间隔、按遗忘曲线、按需复述。',
    body: [
      '第一种是固定间隔：第 1、3、7、15 天各复习一次，好处是不用决定，坏处是浪费时间。',
      '第二种按遗忘曲线：每次复习前先自测，答不上来就缩短间隔。',
      '第三种按需复述：只在要用的时候回看，适合工具类知识，不适合需要背下来的材料。',
    ],
    backlinks: ['双向链接的边界'],
  },
  {
    id: 'c2', title: '为什么写作要先写结论', site: '阮一峰的网络日志', date: '11-19',
    url: 'https://www.ruanyifeng.com/blog/2026/11.html', status: 'unread', ai: 'done',
    tags: ['写作'],
    summary: '先给结论，读者才知道要不要往下读。',
    body: [
      '结论前置不是文风问题，是成本问题：读者花三秒判断值不值得读。',
    ],
    backlinks: [],
  },
  {
    id: 'c3', title: '笔记工具的取舍', site: '少数派', date: '11-18',
    url: 'https://sspai.com/post/88022', status: 'unread', ai: 'done',
    tags: ['设计', '阅读'],
    summary: '本地优先、双链、导出自由度，三者往往只能取其二。',
    body: [
      '本地优先意味着同步要自己解决。双链意味着数据结构要能反查。',
      '导出自由度意味着不能把内容锁在私有格式里。',
    ],
    backlinks: ['小步重构'],
  },
  {
    id: 'c4', title: '信息的半衰期', site: '得到', date: '11-16',
    url: 'https://dedao.cn/note/1', status: 'unread', ai: 'pending',
    tags: ['阅读'],
    summary: '',
    body: ['（还没整理）'],
    backlinks: [],
  },
  {
    id: 'c5', title: '慢读的价值', site: '读库', date: '11-14',
    url: 'https://duku.cn/a/2', status: 'read', ai: 'done',
    tags: ['阅读'],
    summary: '慢读不是读得慢，是读完停一下再往下。',
    body: ['停顿那一下，是把内容接到已有知识上的时间。'],
    backlinks: [],
  },
  {
    id: 'c6', title: '从收集到输出', site: '少数派', date: '11-10',
    url: 'https://sspai.com/post/88077', status: 'read', ai: 'done',
    tags: ['方法', '写作'],
    summary: '收集只是入口，输出才算消化。',
    body: ['收藏夹吃灰的原因，是收集和输出之间没有桥。'],
    backlinks: ['渐进式总结'],
  },
  {
    id: 'c7', title: '检索比分类重要', site: 'V2EX', date: '10-29',
    url: 'https://v2ex.com/t/1', status: 'archived', ai: 'done',
    tags: ['设计'],
    summary: '分类是给别人看的，检索是给自己用的。',
    body: ['整理一次不如搜一次快。'],
    backlinks: [],
  },
  {
    id: 'c8', title: 'AI 摘要好用吗', site: '少数派', date: '10-25',
    url: 'https://sspai.com/post/88100', status: 'unread', ai: 'failed',
    tags: ['阅读'],
    summary: '',
    body: ['（整理失败，可重试）'],
    backlinks: [],
  },
  {
    id: 'c9', title: '工具的第二年', site: '少数派', date: '10-20',
    url: 'https://sspai.com/post/88123', status: 'read', ai: 'pending',
    tags: ['设计'],
    summary: '',
    body: ['（还没整理）'],
    backlinks: [],
  },
];

const TEMPLATES = [
  { name: '工作', sections: ['今天做了什么', '推进到哪', '卡在哪'] },
  { name: '生活', sections: ['今天做了什么', '想到的事'] },
  { name: '锻炼', sections: ['训练', '身体感受'] },
];

const MODULES = [
  { id: 'notes', title: '笔记' },
  { id: 'journal', title: '日记' },
  { id: 'clips', title: '剪藏' },
];

const VARIANTS = {
  a: { name: 'A 工具栏分段', note: '切换在工具栏中央；侧栏只显示当前模块的范围与列表。' },
  b: { name: 'B 侧栏四行', note: '模块是侧栏顶部四行，工具栏不放分段；二级导航与列表都在同一列。' },
  c: { name: 'C 侧栏内分段', note: '分段控件在侧栏里，工具栏留白；视觉层级比 A 低一档。' },
  d: { name: 'D 四栏', note: '导航、列表、内容分开；侧栏不再兼列表，横向空间吃紧。' },
};

const DEFAULT_SCOPE = { notes: 'all', journal: 'today', clips: 'unread' };

// ---------- 工具 ----------

const $ = (sel) => document.querySelector(sel);

function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function inlineHTML(text) {
  // 只处理 [[链接]]，其余按纯文本
  return esc(text).replace(/\[\[([^\]\n]+)\]\]/g, (_, t) => `<span class="wikilink">${t}</span>`);
}

// ---------- 查询 ----------

const noteById = (id) => NOTES.find((n) => n.id === id);
const journalById = (id) => JOURNALS.find((j) => j.id === id);
const clipById = (id) => CLIPS.find((c) => c.id === id);

function orphanNotes() {
  return NOTES.filter((n) => n.backlinks.length === 0 && n.outgoing.length === 0);
}

function noteTags() {
  const set = new Set();
  NOTES.forEach((n) => n.tags.forEach((t) => set.add(t)));
  return [...set].sort();
}

function clipTags() {
  const set = new Set();
  CLIPS.forEach((c) => c.tags.forEach((t) => set.add(t)));
  return [...set].sort();
}

function openTodos() {
  const out = [];
  JOURNALS.forEach((j) => {
    j.sections.forEach((s) => {
      s.items.forEach((it) => {
        if (!it.done) out.push({ date: j.date, weekday: j.weekday, section: s.title, text: it.text });
      });
    });
  });
  return out.sort((a, b) => (a.date < b.date ? 1 : -1));
}

function clipsWith(scope) {
  if (scope === 'all') return CLIPS;
  if (scope === 'archived') return CLIPS.filter((c) => c.status === 'archived');
  if (scope === 'pending') return CLIPS.filter((c) => c.ai !== 'done');
  if (scope === 'unread') return CLIPS.filter((c) => c.status === 'unread');
  if (scope.startsWith('tag:')) {
    const tag = scope.slice(4);
    return CLIPS.filter((c) => c.tags.includes(tag));
  }
  return CLIPS;
}

function scopesFor(module) {
  if (module === 'notes') {
    return [
      { id: 'all', label: '全部', count: NOTES.length },
      { id: 'orphans', label: '孤儿笔记', count: orphanNotes().length },
      ...noteTags().map((t) => ({
        id: 'tag:' + t, label: '# ' + t,
        count: NOTES.filter((n) => n.tags.includes(t)).length,
      })),
    ];
  }
  if (module === 'journal') {
    return [
      { id: 'today', label: '今天' },
      { id: 'all', label: '全部日记', count: JOURNALS.length },
      { id: 'todos', label: '待办总览', count: openTodos().length },
      { id: 'templates', label: '模板', count: TEMPLATES.length },
    ];
  }
  return [
    { id: 'unread', label: '未读', count: clipsWith('unread').length },
    { id: 'all', label: '全部', count: CLIPS.length },
    { id: 'archived', label: '已归档', count: clipsWith('archived').length },
    { id: 'pending', label: '待整理', count: clipsWith('pending').length },
    ...clipTags().map((t) => ({
      id: 'tag:' + t, label: '# ' + t,
      count: CLIPS.filter((c) => c.tags.includes(t)).length,
    })),
  ];
}

function itemsFor(module, scope) {
  const q = (state ? state.query[module] : '').trim();
  const base = baseItems(module, scope);
  if (!q) return base;
  return base.filter((it) => {
    const hay = [it.title, it.date, it.site, it.status, ...(it.tags || [])]
      .filter(Boolean).join(' ').toLowerCase();
    return hay.includes(q.toLowerCase());
  });
}

function baseItems(module, scope) {
  if (module === 'notes') {
    if (scope === 'orphans') return orphanNotes();
    if (scope.startsWith('tag:')) {
      const tag = scope.slice(4);
      return NOTES.filter((n) => n.tags.includes(tag));
    }
    return NOTES;
  }
  if (module === 'journal') {
    if (scope === 'today') return [JOURNALS[0]];
    if (scope === 'all') return JOURNALS;
    return [];
  }
  return clipsWith(scope);
}

// ---------- 状态 ----------

function firstItemOf(module, scope) {
  const items = itemsFor(module, scope);
  return items.length ? items[0].id : null;
}

function initialState(variant) {
  return {
    variant,
    module: 'notes',
    remember: true,
    narrow: false,
    query: { notes: '', journal: '', clips: '' },
    scope: { ...DEFAULT_SCOPE },
    selection: {
      notes: firstItemOf('notes', 'all'),
      journal: firstItemOf('journal', 'today'),
      clips: firstItemOf('clips', 'unread'),
    },
  };
}

let state = null;
state = initialState(readVariantFromURL());

function readVariantFromURL() {
  const v = new URLSearchParams(location.search).get('variant');
  return VARIANTS[v] ? v : 'a';
}

function setVariant(v) {
  state.variant = v;
  const url = new URL(location.href);
  url.searchParams.set('variant', v);
  history.replaceState(null, '', url);
  render();
}

/** 切模块。关掉「记住状态」时，目标模块重置到默认范围与第一条。 */
function goModule(next) {
  if (next === state.module) return;
  if (!state.remember) {
    state.scope[next] = DEFAULT_SCOPE[next];
    state.query[next] = '';
    state.selection[next] = firstItemOf(next, DEFAULT_SCOPE[next]);
  }
  state.module = next;
  render();
}

function goScope(scope) {
  state.scope[state.module] = scope;
  const first = firstItemOf(state.module, scope);
  if (first) state.selection[state.module] = first;
  render();
}

function selectItem(id) {
  state.selection[state.module] = id;
  render();
}

function currentItems() {
  return itemsFor(state.module, state.scope[state.module]);
}

function currentSelection() {
  const items = currentItems();
  const id = state.selection[state.module];
  return items.find((it) => it.id === id) || items[0] || null;
}

// ---------- 渲染 ----------

function render() {
  const v = state.variant;
  const shell = document.createElement('div');
  shell.className = `shell v-${v}`;
  shell.innerHTML = [
    toolbarHTML(),
    `<div class="grid">${columnsHTML()}</div>`,
  ].join('');

  const app = $('#app');
  app.innerHTML = '';
  app.appendChild(shell);
  document.body.classList.toggle('narrow', state.narrow);

  renderVariantBar();
  renderStatePanel();

  // 列表滚动位置：选中项进入视野
  const on = app.querySelector('.item.on');
  if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest' });
}

function toolbarHTML() {
  const v = state.variant;
  const center = v === 'a' ? segmentedHTML('toolbar') : '<span></span>';
  return `
    <div class="toolbar">
      <span class="brand">Silvics</span>
      <div class="spacer"></div>
      ${center}
      <div class="spacer"></div>
      <div class="tools">
        <button>新建</button>
        <span>⌘N</span>
      </div>
    </div>`;
}

function segmentedHTML(where) {
  const cls = where === 'toolbar' ? 'seg-mod' : 'seg-mod seg-wide';
  const narrow = state.narrow && where === 'toolbar';
  if (narrow) {
    return `<select id="nav-select" aria-label="切换模块">${MODULES.map((m) =>
      `<option value="${m.id}"${m.id === state.module ? ' selected' : ''}>${m.title}</option>`).join('')}</select>`;
  }
  return `<div class="${cls}">${MODULES.map((m) =>
    `<button data-go-module="${m.id}" class="${m.id === state.module ? 'on' : ''}">${m.title}</button>`).join('')}</div>`;
}

function moduleRowsHTML() {
  const counts = { notes: NOTES.length, journal: JOURNALS.length, clips: CLIPS.length };
  return `<div class="group">${MODULES.map((m) => `
    <button class="mod-row ${m.id === state.module ? 'on' : ''}" data-go-module="${m.id}">
      <span class="caret">${m.id === state.module ? '▸' : ''}</span>
      <span>${m.title}</span>
      <span class="num">${counts[m.id]}</span>
    </button>`).join('')}
    <button class="mod-row" disabled title="设置是独立窗口，这里只演示入口">
      <span class="caret"></span><span>设置</span><span class="num">⌘,</span>
    </button>
  </div>`;
}

function scopeBlockHTML(module) {
  const scope = state.scope[module];
  return `<div class="group">
    <div class="group-title">${module === 'clips' ? '剪藏' : module === 'journal' ? '日记' : '范围'}</div>
    ${scopesFor(module).map((s) => `
      <button class="row ${s.id === scope ? 'on' : ''}" data-scope="${s.id}">
        <span class="label">${esc(s.label)}</span>
        ${s.count === undefined ? '' : `<span class="num">${s.count}</span>`}
      </button>`).join('')}
  </div>`;
}

function searchHTML(module) {
  return `<div class="search">
    <input id="q" type="text" placeholder="搜索本模块…" value="${esc(state.query[module])}">
  </div>`;
}

function columnsHTML() {
  const v = state.variant;
  const module = state.module;
  if (v === 'd') {
    return [
      `<aside class="col col-nav">${moduleRowsHTML()}<div class="hr"></div>${scopeBlockHTML(module)}</aside>`,
      `<aside class="col col-list">${searchHTML(module)}<div class="hr"></div><div id="list-panel">${listHTML(module)}</div></aside>`,
      `<main class="col col-mid">${contentHTML(module)}</main>`,
      `<aside class="col col-right">${contextHTML(module)}</aside>`,
    ].join('');
  }
  if (v === 'b') {
    return [
      `<aside class="col col-left">${moduleRowsHTML()}<div class="hr"></div>${scopeBlockHTML(module)}<div class="hr"></div><div id="list-panel">${listHTML(module)}</div></aside>`,
      `<main class="col col-mid">${contentHTML(module)}</main>`,
      `<aside class="col col-right">${contextHTML(module)}</aside>`,
    ].join('');
  }
  const segTop = v === 'c' ? `${segmentedHTML('sidebar')}<div class="hr"></div>` : '';
  return [
    `<aside class="col col-left">${segTop}${searchHTML(module)}${scopeBlockHTML(module)}<div class="hr"></div><div id="list-panel">${listHTML(module)}</div></aside>`,
    `<main class="col col-mid">${contentHTML(module)}</main>`,
    `<aside class="col col-right">${contextHTML(module)}</aside>`,
  ].join('');
}

function listHTML(module) {
  const items = currentItems();
  const sel = state.selection[module];

  if (!items.length) {
    const map = {
      todos: '待办总览在中栏显示，这里没有列表。',
      templates: '模板在中栏显示，这里没有列表。',
    };
    return `<div class="hint">${map[state.scope[module]] || '这个范围里没有条目。'}</div>`;
  }

  if (module === 'journal') {
    let out = '';
    let month = '';
    items.forEach((j) => {
      const m = j.date.slice(0, 7);
      if (m !== month) { month = m; out += `<div class="month">${m}</div>`; }
      const open = j.sections.reduce((n, s) => n + s.items.filter((i) => !i.done).length, 0);
      out += `<button class="item ${j.id === sel ? 'on' : ''}" data-select="${j.id}">
        <span class="title">${esc(j.date)}　${esc(j.weekday)}</span>
        <span class="sub">未完成 ${open} 条</span>
      </button>`;
    });
    return `<div class="list">${out}</div>`;
  }

  if (module === 'clips') {
    return `<div class="list">${items.map((c) => `
      <button class="item ${c.id === sel ? 'on' : ''}" data-select="${c.id}">
        <span class="title"><span class="dot ${c.status === 'unread' ? '' : 'read'}"></span>${esc(c.title)}</span>
        <span class="sub">${esc(c.site)} · ${esc(c.date)}${c.tags.length ? ' · ' + c.tags.map(esc).join(' ') : ''}</span>
      </button>`).join('')}</div>`;
  }

  return `<div class="list">${items.map((n) => `
    <button class="item ${n.id === sel ? 'on' : ''}" data-select="${n.id}">
      <span class="title">${esc(n.title)}</span>
      <span class="sub">${esc(n.status)} · ${n.backlinks.length} 条反向链接</span>
    </button>`).join('')}</div>`;
}

function contentHTML(module) {
  if (module === 'notes') return noteContent();
  if (module === 'journal') return journalContent();
  return clipContent();
}

function noteContent() {
  const note = currentSelection();
  if (!note) return `<div class="empty">这个范围里没有笔记。</div>`;
  return `
    <div class="note-head">
      <h1>${esc(note.title)}</h1>
      <div class="note-meta">
        <span class="chip on">${esc(note.status)}</span>
        <span>更新于 ${esc(note.updated)}</span>
        <span>·</span>
        <span>${note.body.join('').length} 字</span>
      </div>
    </div>
    <div class="note-body">${note.body.map((p) => `<p>${inlineHTML(p)}</p>`).join('')}</div>`;
}

function journalContent() {
  const scope = state.scope.journal;
  if (scope === 'todos') return todosContent();
  if (scope === 'templates') return templatesContent();

  const j = currentSelection();
  if (!j) return `<div class="empty">还没有日记。⌘⇧J 打开今天。</div>`;
  const open = j.sections.reduce((n, s) => n + s.items.filter((i) => !i.done).length, 0);
  return `
    <div class="journal-head">
      <h1>${esc(j.date)}</h1>
      <span class="wkd">${esc(j.weekday)}</span>
      <span class="tag">${open === 0 ? '待办已清空' : `未完成 ${open} 条`}</span>
    </div>
    ${j.sections.map((s) => `
      <div class="section">
        <h2>${esc(s.title)}</h2>
        <ul>${s.items.map((it) => `
          <li class="${it.done ? 'done' : ''}">
            <input type="checkbox" ${it.done ? 'checked' : ''} disabled>
            <span class="text">${esc(it.text)}</span>
          </li>`).join('')}</ul>
      </div>`).join('')}`;
}

function todosContent() {
  const rows = openTodos();
  return `
    <div class="note-head">
      <h1>待办总览</h1>
      <div class="note-meta"><span>跨全部日记聚合，共 ${rows.length} 条未完成</span></div>
    </div>
    <table class="todos">
      <thead><tr><th>日期</th><th>星期</th><th>段落</th><th>待办</th></tr></thead>
      <tbody>${rows.map((r) => `
        <tr>
          <td class="date">${esc(r.date)}</td>
          <td>${esc(r.weekday)}</td>
          <td>${esc(r.section)}</td>
          <td>${esc(r.text)}</td>
        </tr>`).join('')}</tbody>
    </table>`;
}

function templatesContent() {
  return `
    <div class="note-head">
      <h1>日记模板</h1>
      <div class="note-meta"><span>新建日记时按顺序取模板，注入骨架后不再校验</span></div>
    </div>
    ${TEMPLATES.map((t) => `
      <div class="section">
        <h2>${esc(t.name)}</h2>
        <ul>${t.sections.map((s) => `<li><span class="text">## ${esc(s)}</span></li>`).join('')}</ul>
      </div>`).join('')}`;
}

function clipContent() {
  const c = currentSelection();
  if (!c) return `<div class="empty">这个范围里没有剪藏。⌘⇧V 收一篇。</div>`;
  const badge = c.ai === 'done' ? '' : `<span class="readonly-note">${c.ai === 'failed' ? '整理失败，可重试' : '待整理'}</span>`;
  return `
    <div class="clip-head">
      <h1>${esc(c.title)}</h1>
      <div class="clip-source">${esc(c.site)} · ${esc(c.date)} · ${esc(c.status === 'unread' ? '未读' : c.status === 'archived' ? '已归档' : '已读')}</div>
      ${badge}
    </div>
    ${c.summary ? `<div class="summary"><strong>摘要</strong>　${esc(c.summary)}</div>` : ''}
    <div class="clip-body">${c.body.map((p) => `<p>${inlineHTML(p)}</p>`).join('')}</div>
    <button class="readonly-note" title="剪藏正文默认只读，可开编辑">编辑正文</button>`;
}

function contextHTML(module) {
  if (module === 'notes') return noteContext();
  if (module === 'journal') return journalContext();
  return clipContext();
}

function noteContext() {
  const n = currentSelection();
  if (!n) return '';
  return `
    <div class="group">
      <div class="group-title">反向链接 (${n.backlinks.length})</div>
      ${n.backlinks.length ? `<ul class="fake">${n.backlinks.map((t) => `<li>${esc(t)}</li>`).join('')}</ul>` : '<div class="hint">没有笔记引用它。</div>'}
    </div>
    <div class="group">
      <div class="group-title">出链 (${n.outgoing.length})</div>
      ${n.outgoing.length ? `<ul class="fake">${n.outgoing.map((t) => `<li>${esc(t)}</li>`).join('')}</ul>` : '<div class="hint">没有出链。</div>'}
    </div>
    <div class="group">
      <div class="group-title">未链接提及 (${n.mentions.length})</div>
      ${n.mentions.length ? `<ul class="fake">${n.mentions.map((t) => `<li>${esc(t)}</li>`).join('')}</ul>` : '<div class="hint">没有。</div>'}
    </div>`;
}

function journalContext() {
  const scope = state.scope.journal;
  if (scope === 'todos' || scope === 'templates') {
    return `<div class="group"><div class="group-title">说明</div>
      <div class="hint">${scope === 'todos' ? '待办总览占满中栏，不需要右栏。' : '模板是列表页，右栏留空。'}</div></div>`;
  }
  const j = currentSelection();
  if (!j) return '';
  const open = j.sections.reduce((n, s) => n + s.items.filter((i) => !i.done).length, 0);
  return `
    <div class="group">
      <div class="group-title">被引用 (${j.backlinks.length})</div>
      ${j.backlinks.length ? `<ul class="fake">${j.backlinks.map((t) => `<li>${esc(t)}</li>`).join('')}</ul>` : '<div class="hint">没有笔记引用它。</div>'}
    </div>
    <div class="group">
      <div class="group-title">当天</div>
      <dl class="kv">
        <dt>未完成</dt><dd>${open} 条</dd>
        <dt>承接自</dt><dd>${j.carriedFrom ? esc(j.carriedFrom) : '无'}</dd>
      </dl>
    </div>`;
}

function clipContext() {
  const c = currentSelection();
  if (!c) return '';
  return `
    <div class="group">
      <div class="group-title">来源</div>
      <dl class="kv">
        <dt>站点</dt><dd>${esc(c.site)}</dd>
        <dt>发布</dt><dd>${esc(c.date)}</dd>
        <dt>地址</dt><dd title="${esc(c.url)}">${esc(c.url)}</dd>
        <dt>标签</dt><dd>${c.tags.length ? c.tags.map(esc).join(' ') : '无'}</dd>
      </dl>
    </div>
    <div class="group">
      <div class="group-title">被引用 (${c.backlinks.length})</div>
      ${c.backlinks.length ? `<ul class="fake">${c.backlinks.map((t) => `<li>${esc(t)}</li>`).join('')}</ul>` : '<div class="hint">还没被任何笔记引用。</div>'}
    </div>
    <div class="actions">
      <button>复制引用</button>
      <button>${c.status === 'archived' ? '取消归档' : '归档'}</button>
      <button>导出 .md</button>
    </div>`;
}

function renderVariantBar() {
  const v = VARIANTS[state.variant];
  const bar = $('#variant-bar');
  bar.innerHTML = `
    ${Object.entries(VARIANTS).map(([id, item]) =>
      `<button data-variant="${id}" class="${id === state.variant ? 'on' : ''}">${item.name}</button>`).join('')}
    <span class="hint">${esc(v.note)}　直链：?variant=${state.variant}</span>`;
}

function renderStatePanel() {
  const panel = $('#state-panel');
  const sel = currentSelection();
  const mod = state.module;
  panel.className = 'state-panel' + (state.panelCollapsed ? ' collapsed' : '');
  panel.innerHTML = `
    <header>
      <b>状态</b>
      <span class="num">${state.variant.toUpperCase()}</span>
      <button data-panel="toggle">${state.panelCollapsed ? '展开' : '收起'}</button>
    </header>
    <div class="body">
      <dl>
        <dt>模块</dt><dd>${mod}</dd>
        <dt>范围</dt><dd>${esc(state.scope[mod])}</dd>
        <dt>选中</dt><dd>${sel ? esc(sel.title || sel.date) : '（空）'}</dd>
        <dt>查询</dt><dd>${state.query[mod] ? esc(state.query[mod]) : '（空）'}</dd>
      </dl>
      <div class="switches">
        <label><input type="checkbox" id="sw-remember" ${state.remember ? 'checked' : ''}>记住状态</label>
        <label><input type="checkbox" id="sw-narrow" ${state.narrow ? 'checked' : ''}>窄窗口</label>
      </div>
    </div>`;
}

// ---------- 事件 ----------

document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-go-module],[data-scope],[data-select],[data-variant],[data-panel],#btn-reset');
  if (!t) return;

  if (t.id === 'btn-reset') { state = initialState(state.variant); render(); return; }
  if (t.dataset.variant) { setVariant(t.dataset.variant); return; }
  if (t.dataset.panel === 'toggle') { state.panelCollapsed = !state.panelCollapsed; renderStatePanel(); return; }
  if (t.dataset.goModule && !t.disabled) { goModule(t.dataset.goModule); return; }
  if (t.dataset.scope) { goScope(t.dataset.scope); return; }
  if (t.dataset.select) { selectItem(t.dataset.select); return; }
});

document.addEventListener('change', (e) => {
  const el = e.target;
  if (el.id === 'sw-remember') { state.remember = el.checked; render(); return; }
  if (el.id === 'sw-narrow') { state.narrow = el.checked; render(); return; }
  if (el.id === 'nav-select') { goModule(el.value); return; }
});

document.addEventListener('input', (e) => {
  if (e.target.id !== 'q') return;
  state.query[state.module] = e.target.value;
  const items = currentItems();
  if (items.length && !items.some((it) => it.id === state.selection[state.module])) {
    state.selection[state.module] = items[0].id;
  }
  const panel = document.getElementById('list-panel');
  if (panel) panel.innerHTML = listHTML(state.module);
  renderStatePanel();
  const mid = document.querySelector('.col-mid');
  if (mid) mid.innerHTML = contentHTML(state.module);
});

document.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;

  if (e.metaKey && ['1', '2', '3'].includes(e.key)) {
    e.preventDefault();
    goModule(MODULES[Number(e.key) - 1].id);
    return;
  }

  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    const items = currentItems();
    if (!items.length) return;
    e.preventDefault();
    const cur = state.selection[state.module];
    let i = items.findIndex((it) => it.id === cur);
    if (i < 0) i = 0;
    i = e.key === 'ArrowDown' ? Math.min(items.length - 1, i + 1) : Math.max(0, i - 1);
    selectItem(items[i].id);
  }
});

render();
