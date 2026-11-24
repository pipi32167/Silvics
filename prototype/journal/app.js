/* Silvics 日记 · 低保真原型（v3）
 *
 * v2：日记 = 一份 Markdown 文本，源码 / 预览切换。
 * v3：改成 Typora 式混合模式 —— 光标所在行露源码，其他行渲染，边看边写。
 *
 * 核心约定：
 *   文本是唯一真相（state.body），DOM 只是投影。
 *   只有「当前行」是真 contenteditable，里面是原始文本；
 *   其他行是渲染结果，不可编辑，点击后切换为本行的编辑态。
 *   勾选待办 = 改文本里那一行，不引入第二份状态。
 */

const TODAY = "2026-11-24";
const STORAGE_KEY = "{{SECRET_9p2k4m6t}}";

const SEED = {
  templates: [
    { name: "工作", order: 10 },
    { name: "生活", order: 20 },
    { name: "锻炼", order: 30 },
  ],
  notes: [
    {
      id: "n1",
      title: "稀疏重复优于集中突击",
      body: "集中突击可以短期记住更多，但 [[遗忘曲线决定复习时机]] 决定长期留存。\n把同样的总时长摊到多天，[[间隔重复能提高长期留存]]。",
    },
    {
      id: "n2",
      title: "标题即接口",
      body: "标题写成完整断言句，才能在别的笔记正文里当作自然语言使用。\n这也是 [[笔记应该密集链接]] 能自动成立的前提。",
    },
    {
      id: "n3",
      title: "笔记应该密集链接",
      body: "连接本身就是理解。孤立的笔记等于没写。\n相关：[[标题即接口]]、[[稀疏重复优于集中突击]]。",
    },
    {
      id: "n4",
      title: "遗忘曲线决定复习时机",
      body: "相邻两次复习的间隔应随记忆强度增长而拉长。",
    },
    {
      id: "n5",
      title: "还没连上的草稿",
      body: "这条没有任何引用，也不引用别人 —— 用来演示孤儿计数。",
    },
  ],
  journals: [
    {
      id: "j20261121",
      date: "2026-11-21",
      body: [
        "## 工作",
        "- [x] 写完同步方案的验收项",
        "- [ ] 把 0.1.1 的坑补进 HANDOFF",
        "",
        "## 生活",
        "- [ ] 复核同步的冲突留档",
        "",
        "今天重读 [[标题即接口]] 这一段，有了新感觉。",
      ].join("\n"),
    },
    {
      id: "j20261123",
      date: "2026-11-23",
      body: [
        "## 承接（来自 11-21）",
        "- [ ] 把 0.1.1 的坑补进 HANDOFF",
        "- [ ] 复核同步的冲突留档",
        "",
        "## 工作",
        "- [x] 讨论日记方案",
        "- [ ] 补 issue 里五个待定项",
        "",
        "## 生活",
        "早上跑步 5 公里，[[稀疏重复优于集中突击]] 在跑步上同样成立。",
        "另外想到标题即接口这件事 —— 这里故意不写引用，用来演示未链接提及。",
      ].join("\n"),
    },
  ],
  lastModules: ["工作", "生活"],
};

// ---------- 状态 ----------

let state;

function load() {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw) {
    try {
      state = JSON.parse(raw);
      if (!state.mode) state.mode = "wysiwyg";
      if (state.activeLine == null) state.activeLine = 0;
      return;
    } catch {
      /* 落回种子 */
    }
  }
  state = {
    ...structuredClone(SEED),
    scope: "all",
    searchScope: "notes",
    search: "",
    selection: { type: "note", id: "n1" },
    journalMentions: false,
    mode: "wysiwyg",
    activeLine: 0,
  };
}

function save() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

// ---------- 小工具 ----------

const $ = (sel) => document.querySelector(sel);
const esc = (s) =>
  String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const weekday = (date) => "周" + "日一二三四五六"[new Date(date + "T00:00:00").getDay()];
const noteByTitle = (t) => state.notes.find((n) => n.title === t);
const journalByDate = (d) => state.journals.find((j) => j.date === d);
const journalById = (id) => state.journals.find((j) => j.id === id);
const todayJournalId = () => journalByDate(TODAY)?.id || null;

// ---------- Markdown：行分类 ----------
//
// 只认四种行：标题、待办、段落、代码块。代码块是唯一带上下文（fence 状态）的。

const RE_HEADING = /^(#{1,3})\s+(.*)$/;
const RE_FENCE = /^\s*```/;
const RE_TODO = /^(\s*)[-*+]\s+\[([ xX])\]\s(.*)$/;

function describeLines(body) {
  const lines = String(body).split("\n");
  let inFence = false;
  return lines.map((raw, i) => {
    if (RE_FENCE.test(raw)) {
      inFence = !inFence;
      return { kind: "fence", raw, i };
    }
    if (inFence) return { kind: "fence", raw, i };

    const h = raw.match(RE_HEADING);
    // `#标签`（# 后面没空格）不是标题
    if (h) return { kind: "heading", level: h[1].length, text: h[2], raw, i };

    const t = raw.match(RE_TODO);
    if (t) {
      return {
        kind: "todo",
        indent: t[1].length,
        done: t[2].toLowerCase() === "x",
        text: t[3],
        raw,
        i,
      };
    }

    return { kind: raw.trim() ? "p" : "blank", text: raw, raw, i };
  });
}

/** 行内：`代码` / [[目标|显示]] / **粗** / *斜*。未闭合的一律当纯文本。 */
const RE_INLINE = /(`[^`\n]*`)|(\[\[[^\]\n]*\]\])|(\*\*[^*\n]+\*\*)|(\*[^*\n]+\*)/g;

function inlineHTML(text) {
  let out = "";
  let last = 0;
  RE_INLINE.lastIndex = 0;
  let m;
  while ((m = RE_INLINE.exec(text))) {
    out += esc(text.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith("`")) {
      out += `<code>${esc(tok.slice(1, -1))}</code>`;
    } else if (tok.startsWith("[[")) {
      const inner = tok.slice(2, -2);
      const [targetRaw, displayRaw] = inner.split("|");
      const target = (targetRaw || "").split("#")[0].trim();
      const display = (displayRaw || targetRaw || "").trim();
      if (!target) {
        out += esc(tok); // `[[ ]]` 空目标当纯文本
      } else {
        out += `<span class="wikilink" data-target="${esc(target)}">${esc(display)}</span>`;
      }
    } else if (tok.startsWith("**")) {
      out += `<strong>${esc(tok.slice(2, -2))}</strong>`;
    } else {
      out += `<em>${esc(tok.slice(1, -1))}</em>`;
    }
    last = m.index + tok.length;
  }
  out += esc(text.slice(last));
  return out;
}

// 空 `[[ ]]` 不该产生链接：上面正则要求中间至少 1 个字符，`[[ ]]` 会匹配到空格，这里兜一层
function inlineHTMLSafe(text) {
  return inlineHTML(text).replace(/(<span class="wikilink" data-target="">\s*<\/span>)/g, (m) => m);
}

/** 一行渲染成 HTML（非编辑态）。 */
function renderLineHTML(d) {
  switch (d.kind) {
    case "fence": {
      // 围栏行本身淡一点：代码块看着像一块，但标记仍可见、可点进去改
      const isMark = /^\s*```/.test(d.raw);
      return `<div class="line code${isMark ? " fence-mark" : ""}" data-i="${d.i}">${esc(d.raw) || '<span class="zws"></span>'}</div>`;
    }
    case "heading":
      return `<div class="line h${d.level}" data-i="${d.i}">${inlineHTML(d.text) || '<span class="zws"></span>'}</div>`;
    case "todo":
      return `<div class="line todo ${d.done ? "done" : ""}" data-i="${d.i}" style="padding-left:${d.indent ? 10 : 0}px">
        <span class="todo-box ${d.done ? "on" : ""}" data-line="${d.i}" role="checkbox" aria-checked="${d.done}"></span>
        <span class="todo-text">${inlineHTML(d.text)}</span>
      </div>`;
    case "blank":
      return `<div class="line blank" data-i="${d.i}"><span class="zws"></span></div>`;
    default:
      return `<div class="line" data-i="${d.i}">${inlineHTML(d.text)}</div>`;
  }
}

// ---------- 文本操作（纯函数，供编辑器与测试共用）----------

const Model = {
  lines: (body) => String(body).split("\n"),

  splitLine(body, i, offset) {
    const lines = Model.lines(body);
    const raw = lines[i] ?? "";
    const cut = Math.max(0, Math.min(offset, raw.length));
    lines[i] = raw.slice(0, cut);
    lines.splice(i + 1, 0, raw.slice(cut));
    return { body: lines.join("\n"), line: i + 1, offset: 0 };
  },

  mergeBackward(body, i) {
    const lines = Model.lines(body);
    if (i <= 0) return { body, line: 0, offset: 0 };
    const prev = lines[i - 1];
    lines[i - 1] = prev + lines[i];
    lines.splice(i, 1);
    return { body: lines.join("\n"), line: i - 1, offset: prev.length };
  },

  mergeForward(body, i) {
    const lines = Model.lines(body);
    if (i >= lines.length - 1) return { body, line: i, offset: lines[i].length };
    const merged = lines[i] + lines[i + 1];
    lines[i] = merged;
    lines.splice(i + 1, 1);
    return { body: lines.join("\n"), line: i, offset: merged.length };
  },

  insertLines(body, i, newLines) {
    const lines = Model.lines(body);
    lines.splice(i, 0, ...newLines);
    return { body: lines.join("\n"), line: i + newLines.length };
  },

  replaceLine(body, i, parts) {
    const lines = Model.lines(body);
    lines.splice(i, 1, ...parts);
    return lines.join("\n");
  },

  setLine(body, i, text) {
    const lines = Model.lines(body);
    if (i < 0 || i >= lines.length) return body;
    lines[i] = text;
    return lines.join("\n");
  },

  toggleTodo(body, lineIndex) {
    const lines = Model.lines(body);
    if (lines[lineIndex] == null) return body;
    lines[lineIndex] = lines[lineIndex].replace(/- \[([ xX])\]/, (_, mark) =>
      mark.toLowerCase() === "x" ? "- [ ]" : "- [x]"
    );
    return lines.join("\n");
  },
};

// ---------- 承接 ----------

function openTodosIn(body) {
  return describeLines(body)
    .filter((d) => d.kind === "todo" && !d.done)
    .map((d) => d.text);
}

function carryLines(fromDate, items) {
  return [`## 承接（来自 ${fromDate.slice(5)}）`, ...items.map((t) => `- [ ] ${t}`)];
}

/**
 * 把承接块插到第 atLine 行之前。
 * `blockOnBlank` 为 true 时，如果上一行不是空行就补一个空行（避免标题贴在正文后面）。
 */
function insertCarry(body, atLine, fromDate, items, blockOnBlank = true) {
  const lines = Model.lines(body);
  const at = Math.max(0, Math.min(atLine, lines.length));
  const block = carryLines(fromDate, items);
  const prevIsBlank = at === 0 || lines[at - 1].trim() === "";
  const nextIsBlank = at >= lines.length || lines[at].trim() === "";
  const payload = [
    ...(blockOnBlank && !prevIsBlank ? [""] : []),
    ...block,
    ...(nextIsBlank ? [] : [""]),
  ];
  lines.splice(at, 0, ...payload);
  return { body: lines.join("\n"), line: at + payload.length };
}

function hasCarryFor(body, date) {
  return body.includes(`## 承接（来自 ${date.slice(5)}）`);
}

// ---------- 派生数据 ----------

function plainTextOf(body) {
  // 代码块与行内代码里的内容不算引用，也不该参与提及扫描
  let inFence = false;
  return describeLines(body)
    .filter((d) => {
      if (d.kind === "fence") {
        inFence = !inFence;
        return false;
      }
      return !inFence;
    })
    .map((d) => (d.text || "").replace(/`[^`]*`/g, ""))
    .join("\n");
}

function backlinksFor(title) {
  const out = [];
  for (const n of state.notes) {
    if (n.title === title) continue;
    if (plainTextOf(n.body).includes(`[[${title}]]`)) {
      out.push({ type: "note", id: n.id, label: n.title, snippet: n.body.split("\n")[0] });
    }
  }
  for (const j of state.journals) {
    const text = plainTextOf(j.body);
    if (!text.includes(`[[${title}]]`)) continue;
    const hit = text.split("\n").find((l) => l.includes(`[[${title}]]`)) || "";
    out.push({ type: "journal", date: j.date, label: `${j.date} 日记`, snippet: hit });
  }
  return out;
}

function mentionsIn(j) {
  const plain = plainTextOf(j.body).replace(/\[\[[^\]]+\]\]/g, "");
  return state.notes
    .filter((n) => plain.includes(n.title))
    .map((n) => ({
      title: n.title,
      snippet: j.body.split("\n").find((l) => l.includes(n.title)) || "",
    }));
}

function orphans() {
  return state.notes.filter((n) => {
    const text = plainTextOf(n.body);
    const hasOut = /\[\[[^\]]+\]\]/.test(text);
    const hasIn =
      state.notes.some((o) => o.id !== n.id && plainTextOf(o.body).includes(`[[${n.title}]]`)) ||
      state.journals.some((j) => plainTextOf(j.body).includes(`[[${n.title}]]`));
    return !hasOut && !hasIn;
  });
}

function aggregatedTodosOn(journals) {
  const map = new Map();
  for (const j of [...journals].sort((a, b) => a.date.localeCompare(b.date))) {
    for (const d of describeLines(j.body)) {
      if (d.kind !== "todo") continue;
      const key = d.text.trim();
      const rec = map.get(key) || { text: key, days: [], done: false, latest: j.date };
      if (!rec.days.includes(j.date)) rec.days.push(j.date);
      rec.done = d.done;
      rec.latest = j.date;
      map.set(key, rec);
    }
  }
  return [...map.values()].filter((r) => !r.done).sort((a, b) => b.latest.localeCompare(a.latest));
}

function aggregatedTodos() {
  return aggregatedTodosOn(state.journals);
}

// ---------- 渲染 ----------

function render() {
  renderSidebar();
  renderEditor();
  renderRight();
  save();
}

function renderSidebar() {
  $("#count-all").textContent = state.notes.length;
  $("#count-journal").textContent = state.journals.length;
  $("#count-orphan").textContent = orphans().length;

  ["#scope-all", "#scope-journal", "#scope-orphan"].forEach((s) =>
    $(s).classList.toggle("on", $(s).dataset.scope === state.scope)
  );
  document.querySelectorAll("#search-scope button").forEach((b) =>
    b.classList.toggle("on", b.dataset.scope === state.searchScope)
  );

  const list = $("#list");
  const q = state.search.trim();

  if (state.scope === "journal") {
    $("#list-title").textContent = "日记（倒序）";
    const matched = q
      ? state.journals.filter((j) => j.body.includes(q) || j.date.includes(q))
      : state.journals;
    list.innerHTML =
      [...matched]
        .sort((a, b) => b.date.localeCompare(a.date))
        .map((j) => {
          const open = openTodosIn(j.body).length;
          const on = state.selection.type === "journal" && state.selection.id === j.id;
          return `<button class="item journal ${on ? "on" : ""}" data-kind="journal" data-id="${j.id}">
            <span class="date">${j.date}</span>${open ? `<span class="dot"></span>` : ""}
            <span class="sub">${weekday(j.date)} · 未完成 ${open} 条</span>
          </button>`;
        })
        .join("") || `<div class="hint">${q ? "没有命中的日记" : "还没有日记"}</div>`;
    return;
  }

  $("#list-title").textContent = state.scope === "orphan" ? "孤儿笔记" : "笔记";
  let notes = state.scope === "orphan" ? orphans() : state.notes;
  if (q) notes = notes.filter((n) => n.title.includes(q) || n.body.includes(q));

  const noteRows = notes.map((n) => {
    const on = state.selection.type === "note" && state.selection.id === n.id;
    return `<button class="item ${on ? "on" : ""}" data-kind="note" data-id="${n.id}">
      ${esc(n.title)}<span class="sub">被引用 ${backlinksFor(n.title).length}</span>
    </button>`;
  });

  const journalRows =
    q && state.searchScope === "all"
      ? state.journals
          .filter((j) => j.body.includes(q) || j.date.includes(q))
          .sort((a, b) => b.date.localeCompare(a.date))
          .map(
            (j) => `<button class="item journal" data-kind="journal" data-id="${j.id}">
              <span class="date">${j.date}</span><span class="sub">日记 · 命中正文</span>
            </button>`
          )
      : [];

  list.innerHTML = [...noteRows, ...journalRows].join("") || `<div class="hint">没有命中</div>`;
}

function renderEditor() {
  const el = $("#editor");

  if (state.selection.type === "note") {
    const n = state.notes.find((x) => x.id === state.selection.id);
    el.innerHTML = n
      ? `<div class="note-head">
           <h1>${esc(n.title)}</h1>
           <div class="note-meta">概念笔记 · 反向链接 ${backlinksFor(n.title).length} 条</div>
         </div>
         <div class="note-body">${n.body.split("\n").map((p) => `<p>${inlineHTML(p)}</p>`).join("")}</div>`
      : `<div class="empty">笔记不存在</div>`;
    bindWikilinks();
    return;
  }

  const j = journalById(state.selection.id);
  if (!j) {
    el.innerHTML = `<div class="empty">日记不存在</div>`;
    return;
  }

  el.innerHTML = `
    <div class="journal-head">
      <h1>${j.date}</h1>
      <span class="wkd">${weekday(j.date)}</span>
      <span class="tag">日记 · Markdown · 不可改名</span>
    </div>

    <div class="editor-bar">
      <div class="seg" id="journal-mode">
        <button data-mode="wysiwyg" class="${state.mode === "wysiwyg" ? "on" : ""}">所见即所得</button>
        <button data-mode="source" class="${state.mode === "source" ? "on" : ""}">源码</button>
      </div>
      <button id="btn-carry" class="ghost">插入承接（光标处）</button>
      <span class="caret-info" id="caret-info"></span>
    </div>

    ${
      state.mode === "wysiwyg"
        ? `<div class="doc" id="doc">${renderDoc(j)}</div>
           <div class="hint tiny">当前行显示源码，离开后自动渲染。点任意一行即可开始写。</div>`
        : `<textarea id="journal-src" spellcheck="false">${esc(j.body)}</textarea>`
    }
  `;

  $("#journal-mode").onclick = (e) => {
    const btn = e.target.closest("button");
    if (!btn) return;
    state.mode = btn.dataset.mode;
    render();
  };
  $("#btn-carry").onclick = () => insertCarryAtCaret(j);

  if (state.mode === "wysiwyg") bindDoc(j);
  else bindSource(j);
}

function renderDoc(j) {
  const descs = describeLines(j.body);
  const active = Math.min(Math.max(state.activeLine, 0), descs.length - 1);
  state.activeLine = active;
  return descs
    .map((d, i) => {
      if (i !== active) return renderLineHTML(d);
      const cls =
        d.kind === "heading" ? `h${d.level}` : d.kind === "todo" ? "todo" : d.kind === "fence" ? "code" : "";
      return `<div class="line active ${cls}" data-i="${i}" contenteditable="true"
                   spellcheck="false" autocapitalize="off" autocorrect="off">${esc(d.raw) || "<br>"}</div>`;
    })
    .join("");
}

// ---------- 编辑器：混合模式 ----------

let composing = false;

function currentJournal() {
  return state.selection.type === "journal" ? journalById(state.selection.id) : null;
}

function bindDoc(j) {
  const doc = $("#doc");

  // 点击：复选框 / 链接 / 切行
  doc.onclick = (e) => {
    const box = e.target.closest(".todo-box");
    if (box) {
      e.preventDefault();
      j.body = Model.toggleTodo(j.body, Number(box.dataset.line));
      state.activeLine = Number(box.dataset.line);
      renderDocInto(j);
      afterRender();
      if (isCarriedLine(j, Number(box.dataset.line))) {
        toast("已勾掉。承接来源那天的正文没变 —— 历史不改，总览按最近一天算。");
      }
      return;
    }
    const link = e.target.closest(".wikilink");
    if (link) {
      e.preventDefault();
      jumpToWiki(link.dataset.target);
      return;
    }
    const line = e.target.closest(".line");
    if (line && !line.classList.contains("active")) {
      activate(Number(line.dataset.i), null);
    }
  };

  doc.onkeydown = onDocKeydown;
  doc.onbeforeinput = onDocBeforeInput;
  doc.oninput = onDocInput;
  doc.onpaste = onDocPaste;
  doc.oncompositionstart = () => {
    composing = true;
    logIME("compositionstart");
  };
  doc.oncompositionend = () => {
    composing = false;
    logIME("compositionend");
    syncActiveLine(j);
    renderDocInto(j);
    afterRender();
  };
  doc.onkeyup = updateCaretInfo;

  // 首帧：把焦点放到当前行末尾
  const activeEl = doc.querySelector(".line.active");
  if (activeEl) placeCaret(activeEl, activeEl.textContent.length);
}

function renderDocInto(j) {
  const doc = $("#doc");
  if (!doc) return;
  doc.innerHTML = renderDoc(j);
}

function afterRender() {
  const j = currentJournal();
  if (!j) return;
  refreshCounts();
  renderRight();
  save();
  updateCaretInfo();
}

function activate(i, offset) {
  const j = currentJournal();
  if (!j) return;
  const lines = Model.lines(j.body);
  state.activeLine = Math.max(0, Math.min(i, lines.length - 1));
  renderDocInto(j);
  const el = $(`#doc .line[data-i="${state.activeLine}"]`);
  if (el) placeCaret(el, offset == null ? (lines[state.activeLine] || "").length : offset);
  save();
}

function activeLineEl() {
  return document.querySelector("#doc .line.active");
}

function offsetInLine(el) {
  const sel = window.getSelection();
  if (!sel || !sel.rangeCount) return (el.textContent || "").length;
  const range = sel.getRangeAt(0);
  if (!el.contains(range.startContainer)) return (el.textContent || "").length;
  const probe = document.createRange();
  probe.selectNodeContents(el);
  probe.setEnd(range.startContainer, range.startOffset);
  return probe.toString().length;
}

function placeCaret(el, offset) {
  el.focus();
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  let remaining = Math.max(0, offset);
  let node = walker.nextNode();
  while (node) {
    if (remaining <= node.textContent.length) {
      const range = document.createRange();
      range.setStart(node, remaining);
      range.collapse(true);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      return;
    }
    remaining -= node.textContent.length;
    node = walker.nextNode();
  }
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);
}

function syncActiveLine(j) {
  const el = activeLineEl();
  if (!el) return;
  const i = Number(el.dataset.i);
  // 浏览器可能把关照里的换行（<div>/<br>）写进当前行，这里必须拆成多行，
  // 否则一格正文里带 \n，行号会整体错位，后面的编辑就会越写越乱。
  // 用 innerText：浏览器若把 <div>/<br> 塞进来，只有它会保留行边界；
  // textContent 会把跨块内容直接粘成一行。
  const rawText = typeof el.innerText === "string" ? el.innerText : el.textContent || "";
  const text = String(rawText).replace(/\r\n?/g, "\n").replace(/\n+$/, "");
  if (text.includes("\n")) {
    const parts = text.split("\n");
    j.body = Model.replaceLine(j.body, i, parts);
    state.activeLine = i + parts.length - 1;
    renderDocInto(j);
    const next = activeLineEl();
    if (next) placeCaret(next, parts[parts.length - 1].length);
    refreshCounts();
    save();
    return;
  }
  j.body = Model.setLine(j.body, i, text);
}

function onDocInput(e) {
  if (composing) return; // 组合期不碰模型，等 compositionend
  const j = currentJournal();
  if (!j) return;
  syncActiveLine(j);
  refreshCounts();
  save();
  updateCaretInfo();
}

function onDocBeforeInput(e) {
  if (composing) return;
  const j = currentJournal();
  if (!j) return;
  const el = activeLineEl();
  if (!el) return;

  // 跨行选区：当前实现只允许单行编辑，这里显式拦掉并提示
  const sel = window.getSelection();
  if (sel && sel.rangeCount > 1) return;

  if (e.inputType === "insertParagraph" || e.inputType === "insertLineBreak") {
    e.preventDefault();
    const el2 = activeLineEl();
    if (!el2) return;
    const i = Number(el2.dataset.i);
    const offset = offsetInLine(el2);
    syncActiveLine(j);
    const res = Model.splitLine(j.body, i, offset);
    j.body = dropEmptyHeadings(res.body);
    state.activeLine = res.line;
    renderDocInto(j);
    const next = activeLineEl();
    if (next) placeCaret(next, 0);
    afterRender();
    return;
  }

  if (e.inputType === "deleteContentBackward") {
    if (offsetInLine(el) === 0 && Number(el.dataset.i) > 0) {
      e.preventDefault();
      const i = Number(el.dataset.i);
      syncActiveLine(j);
      const res = Model.mergeBackward(j.body, i);
      j.body = res.body;
      state.activeLine = res.line;
      renderDocInto(j);
      const next = activeLineEl();
      if (next) placeCaret(next, res.offset);
      afterRender();
    }
    return;
  }

  if (e.inputType === "deleteContentForward") {
    const i = Number(el.dataset.i);
    const len = (el.textContent || "").length;
    if (offsetInLine(el) === len && i < Model.lines(j.body).length - 1) {
      e.preventDefault();
      syncActiveLine(j);
      const res = Model.mergeForward(j.body, i);
      j.body = res.body;
      state.activeLine = res.line;
      renderDocInto(j);
      const next = activeLineEl();
      if (next) placeCaret(next, res.offset);
      afterRender();
    }
  }
}

/** 光标矩形，用来判断是否停在首/末行（自动换行时要先在本行内走）。 */
function caretRect() {
  const sel = window.getSelection();
  if (!sel || !sel.rangeCount) return null;
  const range = sel.getRangeAt(0).cloneRange();
  range.collapse(true);
  const rects = range.getClientRects();
  if (rects.length) return rects[0];
  const r = range.getBoundingClientRect();
  return r && (r.width || r.height) ? r : null;
}

function lineHeightOf(el) {
  const raw = getComputedStyle(el).lineHeight;
  const px = parseFloat(raw);
  return Number.isFinite(px) ? px : 20;
}

function onDocKeydown(e) {
  const j = currentJournal();
  if (!j) return;
  const el = activeLineEl();
  if (!el) return;

  // 方向键跨行：只有当前行可编辑，浏览器不会自己跳到别的行，这里手工接管
  if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.key)) {
    const i = Number(el.dataset.i);
    const lines = Model.lines(j.body);
    const text = el.textContent || "";
    const offset = offsetInLine(el);
    const box = el.getBoundingClientRect();
    const rect = caretRect();
    const lh = lineHeightOf(el);

    if (e.key === "ArrowUp" && i > 0 && (!rect || rect.top < box.top + lh * 0.6)) {
      e.preventDefault();
      activate(i - 1, offset);
      return;
    }
    if (e.key === "ArrowDown" && i < lines.length - 1 && (!rect || rect.top > box.bottom - lh * 1.6)) {
      e.preventDefault();
      activate(i + 1, offset);
      return;
    }
    if (e.key === "ArrowLeft" && offset === 0 && i > 0) {
      e.preventDefault();
      activate(i - 1, (lines[i - 1] || "").length);
      return;
    }
    if (e.key === "ArrowRight" && offset === text.length && i < lines.length - 1) {
      e.preventDefault();
      activate(i + 1, 0);
      return;
    }
    return;
  }

  // Home / End（以及 ⌘←/→）自己接管：只有当前行可编辑，浏览器默认行为在这套结构里不可靠
  const isHome = e.key === "Home" || (e.metaKey && e.key === "ArrowLeft");
  const isEnd = e.key === "End" || (e.metaKey && e.key === "ArrowRight");
  if (isHome || isEnd) {
    e.preventDefault();
    placeCaret(el, isHome ? 0 : (el.textContent || "").length);
    updateCaretInfo();
    return;
  }

  if (e.key === "Enter") {
    e.preventDefault();
    if (composing) return;
    const offset = offsetInLine(el);
    const i = Number(el.dataset.i);
    syncActiveLine(j);
    const res = Model.splitLine(j.body, i, offset);
    j.body = res.body;
    state.activeLine = res.line;
    renderDocInto(j);
    // 换行后，如果上一行变成空标题（`## `），退化成普通段落
    normalizeHeadingLines(j);
    renderDocInto(j);
    const next = activeLineEl();
    if (next) placeCaret(next, res.offset);
    afterRender();
    return;
  }

  if (e.key === "Tab") {
    e.preventDefault();
    document.execCommand("insertText", false, "  ");
  }
}

function onDocPaste(e) {
  const j = currentJournal();
  if (!j) return;
  const text = (e.clipboardData || window.clipboardData)?.getData("text/plain") ?? "";
  if (!text) return;
  e.preventDefault();
  if (composing) return;

  const el = activeLineEl();
  const i = Number(el.dataset.i);
  const offset = offsetInLine(el);
  syncActiveLine(j);

  const parts = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  if (parts.length === 1) {
    const lines = Model.lines(j.body);
    const raw = lines[i];
    lines[i] = raw.slice(0, offset) + parts[0] + raw.slice(offset);
    j.body = lines.join("\n");
    renderDocInto(j);
    const next = activeLineEl();
    if (next) placeCaret(next, offset + parts[0].length);
  } else {
    const lines = Model.lines(j.body);
    const raw = lines[i];
    const head = raw.slice(0, offset) + parts[0];
    const tail = parts[parts.length - 1] + raw.slice(offset);
    const middle = parts.slice(1, -1);
    lines.splice(i, 1, head, ...middle, tail);
    j.body = lines.join("\n");
    state.activeLine = i + parts.length - 1;
    renderDocInto(j);
    const next = activeLineEl();
    if (next) placeCaret(next, parts[parts.length - 1].length);
  }
  afterRender();
}

/** `## ` 后面没内容时，退化成普通空行（避免出现空标题）。 */
function dropEmptyHeadings(body) {
  return Model.lines(body)
    .map((l) => (/^#{1,3}\s*$/.test(l) ? "" : l))
    .join("\n");
}

function normalizeHeadingLines(j) {
  j.body = dropEmptyHeadings(j.body);
}

function isCarriedLine(j, line) {
  const lines = Model.lines(j.body);
  for (let i = line; i >= 0; i--) {
    if (/^#{1,3}\s/.test(lines[i])) return /^#{1,3}\s*承接（来自/.test(lines[i]);
  }
  return false;
}

function jumpToWiki(target) {
  const n = noteByTitle(target);
  if (n) selectNote(n.id);
  else toast(`「${target}」还没有笔记（悬空引用）`);
}

function bindSource(j) {
  const ta = $("#journal-src");
  ta.oninput = () => {
    j.body = ta.value;
    refreshCounts();
    save();
    updateCaretInfo();
  };
  ta.onkeyup = ta.onclick = updateCaretInfo;
  updateCaretInfo();
}

function updateCaretInfo() {
  const info = $("#caret-info");
  if (!info) return;
  const j = currentJournal();
  if (!j) return;
  if (state.mode === "source") {
    const ta = $("#journal-src");
    if (!ta) return;
    const line = ta.value.slice(0, ta.selectionStart).split("\n").length;
    info.textContent = `源码模式 · 第 ${line} 行`;
    return;
  }
  const el = activeLineEl();
  if (!el) return;
  info.textContent = `第 ${Number(el.dataset.i) + 1} 行 · 光标 ${offsetInLine(el)}`;
}

function refreshCounts() {
  const j = currentJournal();
  if (!j) return;
  const open = openTodosIn(j.body).length;
  document.querySelectorAll(".item.journal").forEach((btn) => {
    if (btn.dataset.id !== j.id) return;
    const sub = btn.querySelector(".sub");
    if (sub) sub.textContent = `${weekday(j.date)} · 未完成 ${open} 条`;
  });
}

function renderRight() {
  const el = $("#backlinks");
  const sel = state.selection;

  if (sel.type === "note") {
    const n = state.notes.find((x) => x.id === sel.id);
    const links = n ? backlinksFor(n.title) : [];
    el.innerHTML =
      links
        .map(
          (b) => `<button class="item" data-kind="${b.type}" ${
            b.type === "note" ? `data-id="${b.id}"` : `data-date="${b.date}"`
          }>${esc(b.label)}<span class="sub">${esc(b.snippet.slice(0, 26))}…</span></button>`
        )
        .join("") || `<div class="hint">还没有反向链接</div>`;
    el.querySelectorAll(".item").forEach((btn) => {
      btn.onclick = () =>
        btn.dataset.kind === "note" ? selectNote(btn.dataset.id) : selectJournalByDate(btn.dataset.date);
    });
    $("#mentions").innerHTML = "";
    $("#mention-hint").textContent = "提及面板只对日记有意义，这条是概念笔记。";
    return;
  }

  const j = journalById(sel.id);
  if (!j) return;

  const text = plainTextOf(j.body);
  const asSource = state.notes.filter((n) => text.includes(`[[${n.title}]]`));
  el.innerHTML =
    asSource
      .map(
        (n) => `<button class="item" data-kind="note" data-id="${n.id}">
          ${esc(n.title)}<span class="sub">这一天引用了它</span></button>`
      )
      .join("") || `<div class="hint">这一天还没引用任何概念</div>`;
  el.querySelectorAll(".item").forEach((btn) => {
    btn.onclick = () => selectNote(btn.dataset.id);
  });

  $("#toggle-journal-mentions").checked = state.journalMentions;
  const mentionBox = $("#mentions");
  if (!state.journalMentions) {
    $("#mention-hint").textContent = "已关闭：日记不参与提及扫描（设置项）";
    mentionBox.innerHTML = "";
  } else {
    const found = mentionsIn(j);
    $("#mention-hint").textContent = found.length
      ? `扫描到 ${found.length} 处（未加 [[ ]] 就写了概念标题）`
      : "这一天没有未链接的提及";
    mentionBox.innerHTML = found
      .map(
        (m) => `<div class="item">${esc(m.title)}<span class="sub">${esc(m.snippet.slice(0, 26))}…</span></div>`
      )
      .join("");
  }
}

function bindWikilinks() {
  document.querySelectorAll(".wikilink").forEach((el) => {
    el.onclick = () => jumpToWiki(el.dataset.target);
  });
}

// ---------- 选择 / 新建 / 承接 ----------

function selectNote(id) {
  state.selection = { type: "note", id };
  if (state.scope === "journal") state.scope = "all";
  render();
}

function selectJournalByDate(date) {
  const j = journalByDate(date);
  if (!j) {
    toast(`${date} 没有日记`);
    return;
  }
  state.selection = { type: "journal", id: j.id };
  state.scope = "journal";
  state.activeLine = 0;
  render();
}

function goToday() {
  if (todayJournalId()) selectJournalByDate(TODAY);
  else {
    toast("还没有今天的日记。点「新建今天的日记」。");
    openNewToday();
  }
}

function openNewToday() {
  if (todayJournalId()) {
    toast("今天已经有日记了。不会再承接一次，避免重复。");
    selectJournalByDate(TODAY);
    return;
  }
  $("#module-picker").innerHTML = state.templates
    .slice()
    .sort((a, b) => a.order - b.order)
    .map(
      (t) => `<label><input type="checkbox" value="${esc(t.name)}"
        ${state.lastModules.includes(t.name) ? "checked" : ""}> ${esc(t.name)}</label>`
    )
    .join("");
  renderCarryPreview();
  $("#module-picker").onchange = renderCarryPreview;
  $("#modal-new").hidden = false;
}

function renderCarryPreview() {
  const prev = previousJournal(TODAY);
  const box = $("#carry-preview");
  if (!prev) {
    box.textContent = "没有更早的日记，今天不承接。";
    return;
  }
  const open = openTodosIn(prev.body);
  box.textContent = open.length
    ? `来自 ${prev.date}（上一个有日记的日子），将带入 ${open.length} 条未完成，插在光标所在行之前：\n` +
      open.map((t) => `· ${t}`).join("\n")
    : `来自 ${prev.date}，那天没有未完成项，不需要承接。`;
}

function createToday() {
  const picked = [...document.querySelectorAll("#module-picker input:checked")].map((i) => i.value);
  if (!picked.length) {
    toast("至少选一个模块");
    return;
  }
  const skeleton = state.templates
    .filter((t) => picked.includes(t.name))
    .sort((a, b) => a.order - b.order)
    .map((t) => `## ${t.name}\n`)
    .join("\n");

  const j = { id: `j${TODAY.replace(/-/g, "")}`, date: TODAY, body: skeleton };
  state.journals.push(j);
  state.lastModules = picked;
  state.selection = { type: "journal", id: j.id };
  state.scope = "journal";
  state.mode = "wysiwyg";
  state.activeLine = 0;
  $("#modal-new").hidden = true;
  render();

  const prev = previousJournal(TODAY);
  const items = prev ? openTodosIn(prev.body) : [];
  if (items.length) insertCarryAtCaret(j, prev.date);
  else toast(`已创建 ${TODAY}。模板已预填，光标在文首。`);
}

function previousJournal(beforeDate) {
  return (
    [...state.journals].filter((x) => x.date < beforeDate).sort((a, b) => b.date.localeCompare(a.date))[0] ||
    null
  );
}

/** 承接插在「当前行之前」。行内光标不拆分当前行，避免把一句话拦腰切断。 */
function insertCarryAtCaret(j, forcedDate) {
  const prev = forcedDate ? journalByDate(forcedDate) : previousJournal(j.date);
  if (!prev) return toast("没有更早的日记可承接");
  if (hasCarryFor(j.body, prev.date)) return toast(`${prev.date} 的承接已经在正文里了，不重复插入。`);

  const items = openTodosIn(prev.body);
  if (!items.length) return toast(`${prev.date} 没有未完成项`);

  const at = state.mode === "source" ? Model.lines(j.body).length : state.activeLine;
  const res = insertCarry(j.body, at, prev.date, items);
  j.body = res.body;
  state.activeLine = res.line;
  render();
  toast(`承接 ${items.length} 条，插在第 ${at + 1} 行之前。`);
}

// ---------- 待办总览 ----------

function openTodos() {
  const rows = aggregatedTodos();
  $("#todo-list").innerHTML =
    rows
      .map(
        (r) => `<button class="item" data-date="${r.latest}" data-text="${esc(r.text)}">
          ${esc(r.text)}
          <span class="sub">最早 ${r.days[0]} · 最近 ${r.latest}${r.days.length > 1 ? ` · 共 ${r.days.length} 天` : ""}</span>
        </button>`
      )
      .join("") || `<div class="hint">没有未完成的待办</div>`;
  document.querySelectorAll("#todo-list .item").forEach((btn) => {
    btn.onclick = () => {
      $("#modal-todos").hidden = true;
      selectJournalByDate(btn.dataset.date);
      highlight(btn.dataset.text);
    };
  });
  $("#modal-todos").hidden = false;
}

function highlight(text) {
  setTimeout(() => {
    document.querySelectorAll("#doc .line").forEach((line) => {
      if (line.textContent.includes(text)) {
        line.classList.add("hit");
        line.scrollIntoView({ block: "center" });
      }
    });
  }, 40);
}

// ---------- 按标题打开 ----------

function openQuick() {
  $("#quick-input").value = "";
  renderQuick("");
  $("#modal-quick").hidden = false;
  $("#quick-input").focus();
}

function renderQuick(q) {
  const notes = state.notes.filter((n) => n.title.includes(q));
  $("#quick-list").innerHTML =
    notes.map((n) => `<button class="item" data-id="${n.id}">${esc(n.title)}</button>`).join("") ||
    `<div class="hint">没有命中</div>`;
  document.querySelectorAll("#quick-list .item").forEach((btn) => {
    btn.onclick = () => {
      $("#modal-quick").hidden = true;
      selectNote(btn.dataset.id);
    };
  });
}

// ---------- 提示 / 输入法日志 ----------

let toastTimer;
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 4200);
}

const imeLog = [];
function logIME(event) {
  imeLog.unshift(`${new Date().toLocaleTimeString()} ${event}`);
  imeLog.length = Math.min(imeLog.length, 8);
  const box = $("#ime-log");
  if (box) box.innerHTML = imeLog.map((l) => `<div>${esc(l)}</div>`).join("");
}

// ---------- 事件 ----------

function bind() {
  $("#scope-all").onclick = () => {
    state.scope = "all";
    render();
  };
  $("#scope-journal").onclick = () => {
    state.scope = "journal";
    const first = [...state.journals].sort((a, b) => b.date.localeCompare(a.date))[0];
    if (first) state.selection = { type: "journal", id: first.id };
    state.activeLine = 0;
    render();
  };
  $("#scope-orphan").onclick = () => {
    state.scope = "orphan";
    render();
  };

  $("#list").onclick = (e) => {
    const btn = e.target.closest(".item");
    if (!btn) return;
    if (btn.dataset.kind === "journal") selectJournalByDate(journalById(btn.dataset.id)?.date);
    else selectNote(btn.dataset.id);
  };

  $("#search").oninput = (e) => {
    state.search = e.target.value;
    render();
  };
  document.querySelectorAll("#search-scope button").forEach((b) => {
    b.onclick = () => {
      state.searchScope = b.dataset.scope;
      render();
    };
  });

  $("#btn-today").onclick = goToday;
  $("#btn-new-today").onclick = openNewToday;
  $("#btn-todos").onclick = openTodos;
  $("#btn-quickopen").onclick = openQuick;
  $("#btn-tests").onclick = () => window.runEdgeCases?.();

  $("#modal-new-cancel").onclick = () => ($("#modal-new").hidden = true);
  $("#modal-new-confirm").onclick = createToday;
  $("#modal-todos-close").onclick = () => ($("#modal-todos").hidden = true);
  $("#modal-quick-close").onclick = () => ($("#modal-quick").hidden = true);
  $("#modal-tests-close").onclick = () => ($("#modal-tests").hidden = true);
  $("#quick-input").oninput = (e) => renderQuick(e.target.value);

  $("#toggle-journal-mentions").onchange = (e) => {
    state.journalMentions = e.target.checked;
    render();
  };

  $("#btn-reset").onclick = () => {
    localStorage.removeItem(STORAGE_KEY);
    location.reload();
  };

  window.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === "p") {
      e.preventDefault();
      openQuick();
      return;
    }
    if (!(e.metaKey || e.ctrlKey) || !e.shiftKey) return;
    if (e.key.toLowerCase() === "j") {
      e.preventDefault();
      goToday();
    }
    if (e.key.toLowerCase() === "t") {
      e.preventDefault();
      openTodos();
    }
  });
}

// ---------- 导出（给测试面板用）----------

window.SilvicsModel = {
  TODAY,
  describeLines,
  inlineHTML,
  renderLineHTML,
  Model,
  openTodosIn,
  insertCarry,
  carryLines,
  dropEmptyHeadings,
  hasCarryFor,
  plainTextOf,
  aggregatedTodos,
  aggregatedTodosOn,
  backlinksFor: (title, dataset) => {
    const saved = state;
    if (dataset) state = dataset;
    const out = backlinksFor(title);
    state = saved;
    return out;
  },
  getState: () => state,
  selectJournalByDate,
  selectNoteById: (id) => selectNote(id),
  activateLine: (i, off) => activate(i, off),
  offsetInActive: () => {
    const el = activeLineEl();
    return el ? offsetInLine(el) : -1;
  },
};

// ---------- 启动 ----------

load();
bind();
render();
