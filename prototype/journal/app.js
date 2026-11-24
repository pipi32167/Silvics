/* Silvics 日记 · 低保真原型（v2）
 *
 * 关键改动：日记就是一份 Markdown 文本，和概念笔记同构。
 * 模板只在新建时注入骨架；勾选、承接都是对文本的编辑，不是对结构化字段的编辑。
 * 单栏，可在「源码 / 预览」之间切换。
 */

const TODAY = "2026-11-24";
const STORAGE_KEY = "{{SECRET_0c4n1r7g}}";

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
  // 日记 = 纯 Markdown 文本
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
      if (!state.journalMode) state.journalMode = "source";
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
    journalMode: "source",
  };
}

function save() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

// ---------- 小工具 ----------

const $ = (sel) => document.querySelector(sel);
const esc = (s) =>
  String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function renderWikilinks(text) {
  return esc(text).replace(/\[\[([^\]]+)\]\]/g, (_, target) =>
    `<span class="wikilink" data-target="${esc(target)}">${esc(target)}</span>`
  );
}

function weekday(date) {
  const d = new Date(date + "T00:00:00");
  return "周" + "日一二三四五六"[d.getDay()];
}

const noteByTitle = (t) => state.notes.find((n) => n.title === t);
const journalByDate = (d) => state.journals.find((j) => j.date === d);
const journalById = (id) => state.journals.find((j) => j.id === id);
const todayJournalId = () => journalByDate(TODAY)?.id || null;

// ---------- Markdown 极简解析 ----------
//
// 只认三种：`## 标题`、`- [ ] / - [x]`、其余当段落。
// 返回的行都带 line 号，勾选时靠它把「视图里的一次点击」写回「文本里的那一行」。

function parseBody(body) {
  const lines = body.split("\n");
  const blocks = [];
  let para = null;

  lines.forEach((raw, i) => {
    const line = raw;
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    const todo = line.match(/^(\s*)[-*]\s+\[([ xX])\]\s+(.*)$/);

    if (heading) {
      para = null;
      blocks.push({ type: "heading", level: heading[1].length, text: heading[2], line: i });
      return;
    }
    if (todo) {
      para = null;
      blocks.push({
        type: "todo",
        indent: todo[1].length,
        done: todo[2].toLowerCase() === "x",
        text: todo[3],
        line: i,
      });
      return;
    }
    if (!line.trim()) {
      para = null;
      return;
    }
    if (!para) {
      para = { type: "p", text: line, line: i };
      blocks.push(para);
    } else {
      para.text += "\n" + line;
    }
  });

  return blocks;
}

/** 文本里所有未完成待办。 */
function openTodosIn(body) {
  return parseBody(body)
    .filter((b) => b.type === "todo" && !b.done)
    .map((b) => b.text);
}

/** 翻转某一行的复选框，其余字符一个不动。 */
function toggleTodoLine(body, lineIndex) {
  const lines = body.split("\n");
  lines[lineIndex] = lines[lineIndex].replace(/- \[([ xX])\]/, (_, mark) =>
    mark.toLowerCase() === "x" ? "- [ ]" : "- [x]"
  );
  return lines.join("\n");
}

// ---------- 派生数据 ----------

function backlinksFor(title) {
  const out = [];
  for (const n of state.notes) {
    if (n.title === title) continue;
    if (n.body.includes(`[[${title}]]`)) {
      out.push({ type: "note", id: n.id, label: n.title, snippet: n.body.split("\n")[0] });
    }
  }
  for (const j of state.journals) {
    if (!j.body.includes(`[[${title}]]`)) continue;
    const hit = j.body.split("\n").find((l) => l.includes(`[[${title}]]`)) || "";
    out.push({ type: "journal", date: j.date, label: `${j.date} 日记`, snippet: hit });
  }
  return out;
}

function mentionsIn(j) {
  const plain = j.body.replace(/\[\[[^\]]+\]\]/g, "");
  return state.notes
    .filter((n) => plain.includes(n.title))
    .map((n) => ({
      title: n.title,
      snippet: j.body.split("\n").find((l) => l.includes(n.title)) || "",
    }));
}

function orphans() {
  return state.notes.filter((n) => {
    const hasOut = /\[\[[^\]]+\]\]/.test(n.body);
    const hasIn =
      state.notes.some((o) => o.id !== n.id && o.body.includes(`[[${n.title}]]`)) ||
      state.journals.some((j) => j.body.includes(`[[${n.title}]]`));
    return !hasOut && !hasIn;
  });
}

/** 跨日记聚合待办：同一句话取最近一天的状态。 */
function aggregatedTodos() {
  const map = new Map();
  for (const j of [...state.journals].sort((a, b) => a.date.localeCompare(b.date))) {
    for (const b of parseBody(j.body)) {
      if (b.type !== "todo") continue;
      const key = b.text.trim();
      const rec = map.get(key) || { text: key, days: [], done: false, latest: j.date, earliest: j.date };
      if (!rec.days.includes(j.date)) rec.days.push(j.date);
      rec.done = b.done;
      rec.latest = j.date;
      map.set(key, rec);
    }
  }
  return [...map.values()].filter((r) => !r.done).sort((a, b) => b.latest.localeCompare(a.latest));
}

/** 「上一个有日记的日子」：最近那一篇，不跳天。 */
function previousJournal(beforeDate) {
  return [...state.journals]
    .filter((j) => j.date < beforeDate)
    .sort((a, b) => b.date.localeCompare(a.date))[0] || null;
}

function carryBlock(fromDate, items) {
  return [
    `## 承接（来自 ${fromDate.slice(5)}）`,
    ...items.map((t) => `- [ ] ${t}`),
    "",
    "",
  ].join("\n");
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
         <div class="note-body">
           ${n.body.split("\n").map((p) => `<p>${renderWikilinks(p)}</p>`).join("")}
         </div>`
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
        <button data-mode="source" class="${state.journalMode === "source" ? "on" : ""}">源码</button>
        <button data-mode="preview" class="${state.journalMode === "preview" ? "on" : ""}">预览</button>
      </div>
      <button id="btn-carry" class="ghost">插入承接（光标处）</button>
      <span class="caret-info" id="caret-info"></span>
    </div>

    ${
      state.journalMode === "source"
        ? `<textarea id="journal-src" spellcheck="false">${esc(j.body)}</textarea>`
        : `<div class="preview-body" id="journal-preview">${renderMarkdown(j.body)}</div>`
    }
  `;

  $("#journal-mode").onclick = (e) => {
    const btn = e.target.closest("button");
    if (!btn) return;
    state.journalMode = btn.dataset.mode;
    render();
  };
  $("#btn-carry").onclick = () => insertCarry(j);

  if (state.journalMode === "source") {
    const ta = $("#journal-src");
    ta.oninput = () => {
      j.body = ta.value;
      refreshCounts();
      save();
    };
    ta.onkeyup = ta.onclick = updateCaretInfo;
    updateCaretInfo();
  } else {
    bindWikilinks();
    document.querySelectorAll("#journal-preview input[data-line]").forEach((box) => {
      box.onchange = () => {
        const line = Number(box.dataset.line);
        j.body = toggleTodoLine(j.body, line);
        render();
        if (isCarriedLine(j, line)) {
          toast("已勾掉。承接来源那天的正文没变 —— 历史不改，总览按最近一天算。");
        }
      };
    });
  }
}

/** 日记的 markdown → 可点的视图。 */
function renderMarkdown(body) {
  const blocks = parseBody(body);
  let html = "";
  let listOpen = null;

  const closeList = () => {
    if (listOpen !== null) {
      html += "</ul>";
      listOpen = null;
    }
  };

  for (const b of blocks) {
    if (b.type === "heading") {
      closeList();
      const inner = renderWikilinks(b.text).replace(
        /（来自 (\d{2}-\d{2})）/g,
        '<span class="src">（来自 $1）</span>'
      );
      html += `<h${b.level}>${inner}</h${b.level}>`;
      continue;
    }
    if (b.type === "todo") {
      if (listOpen !== b.indent) {
        closeList();
        html += `<ul class="todo">`;
        listOpen = b.indent;
      }
      html += `<li class="${b.done ? "done" : ""}">
        <input type="checkbox" data-line="${b.line}" ${b.done ? "checked" : ""}>
        <span>${renderWikilinks(b.text)}</span>
      </li>`;
      continue;
    }
    closeList();
    html += `<p>${renderWikilinks(b.text).replace(/\n/g, "<br>")}</p>`;
  }
  closeList();
  return html || `<div class="hint">这一天还是空的。切到「源码」开始写。</div>`;
}

function isCarriedLine(j, line) {
  // 往上找最近的 `## 承接（来自 xx-xx）`
  const lines = j.body.split("\n");
  for (let i = line; i >= 0; i--) {
    if (/^##\s/.test(lines[i])) return /^##\s*承接（来自/.test(lines[i]);
  }
  return false;
}

function updateCaretInfo() {
  const ta = $("#journal-src");
  const info = $("#caret-info");
  if (!ta || !info) return;
  const before = ta.value.slice(0, ta.selectionStart);
  const line = before.split("\n").length;
  info.textContent = `光标：第 ${line} 行`;
}

function refreshCounts() {
  // 输入时不重绘编辑器（会丢焦点），只更新左栏计数与条目上的未完成数
  $("#count-journal").textContent = state.journals.length;
  const j = journalById(state.selection.id);
  if (!j) return;
  const open = openTodosIn(j.body).length;
  document.querySelectorAll(".item.journal").forEach((btn) => {
    if (btn.dataset.id !== j.id) return;
    const sub = btn.querySelector(".sub");
    if (sub) sub.textContent = `${weekday(j.date)} · 未完成 ${open} 条`;
  });
}

function bindWikilinks() {
  document.querySelectorAll(".wikilink").forEach((el) => {
    el.onclick = () => {
      const n = noteByTitle(el.dataset.target);
      if (n) selectNote(n.id);
      else toast(`「${el.dataset.target}」还没有笔记（悬空引用）`);
    };
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

  const asSource = state.notes.filter((n) => j.body.includes(`[[${n.title}]]`));
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
      .map((m) => `<div class="item">${esc(m.title)}<span class="sub">${esc(m.snippet.slice(0, 26))}…</span></div>`)
      .join("");
  }
}

// ---------- 选择 ----------

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
  render();
}

function goToday() {
  if (todayJournalId()) selectJournalByDate(TODAY);
  else {
    toast("还没有今天的日记。点「新建今天的日记」。");
    openNewToday();
  }
}

// ---------- 新建 / 承接 ----------

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
    ? `来自 ${prev.date}（上一个有日记的日子），将带入 ${open.length} 条未完成，插入位置＝创建后光标所在处：\n` +
      open.map((t) => `· ${t}`).join("\n")
    : `来自 ${prev.date}，那天没有未完成项，不需要承接。`;
}

function createToday() {
  const picked = [...document.querySelectorAll("#module-picker input:checked")].map((i) => i.value);
  if (!picked.length) {
    toast("至少选一个模块");
    return;
  }

  // 模板 = 一次性骨架，之后随便改
  const skeleton = state.templates
    .filter((t) => picked.includes(t.name))
    .sort((a, b) => a.order - b.order)
    .map((t) => `## ${t.name}\n\n`)
    .join("");

  const j = { id: `j${TODAY.replace(/-/g, "")}`, date: TODAY, body: skeleton };
  state.journals.push(j);
  state.lastModules = picked;
  state.selection = { type: "journal", id: j.id };
  state.scope = "journal";
  state.journalMode = "source";
  $("#modal-new").hidden = true;
  render();

  // 创建后光标落在文首，承接插在光标处
  const ta = $("#journal-src");
  if (ta) {
    ta.focus();
    ta.selectionStart = ta.selectionEnd = 0;
    const prev = previousJournal(TODAY);
    const items = prev ? openTodosIn(prev.body) : [];
    if (items.length) {
      ta.selectionStart = ta.selectionEnd = 0;
      insertCarry(j, prev.date);
    } else {
      toast(`已创建 ${TODAY}。模板已预填，光标在文首。`);
    }
  }
}

/** 把上一个有日记的日子的未完成项，插到光标处。 */
function insertCarry(j, forcedDate) {
  const ta = $("#journal-src");
  const prev = forcedDate ? journalByDate(forcedDate) : previousJournal(j.date);
  if (!prev) {
    toast("没有更早的日记可承接");
    return;
  }
  const header = `承接（来自 ${prev.date.slice(5)}）`;
  if (j.body.includes(header)) {
    toast(`${prev.date} 的承接已经在正文里了，不重复插入。`);
    return;
  }
  const items = openTodosIn(prev.body);
  if (!items.length) {
    toast(`${prev.date} 没有未完成项`);
    return;
  }

  const block = carryBlock(prev.date, items);
  if (!ta) {
    // 预览模式下没有光标，退回插到文首
    j.body = block + j.body;
    render();
    toast(`预览模式没有光标，承接到插到文首（${items.length} 条）。`);
    return;
  }

  const pos = ta.selectionStart ?? 0;
  // 光标前不是空行时补空行，避免承接标题贴在上面那段正文后面
  const head = j.body.slice(0, pos);
  const lead = pos === 0 || head.endsWith("\n\n") ? "" : head.endsWith("\n") ? "\n" : "\n\n";
  j.body = head + lead + block + j.body.slice(pos);
  ta.value = j.body;
  ta.focus();
  const caret = pos + lead.length + block.length;
  ta.selectionStart = ta.selectionEnd = caret;
  updateCaretInfo();
  refreshCounts();
  save();
  toast(`承接 ${items.length} 条，插在第 ${j.body.slice(0, caret).split("\n").length} 行。`);
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
    document.querySelectorAll("#journal-preview li").forEach((li) => {
      if (li.textContent.includes(text)) {
        li.classList.add("hit");
        li.scrollIntoView({ block: "center" });
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

// ---------- 提示 ----------

let toastTimer;
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 4200);
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

  $("#modal-new-cancel").onclick = () => ($("#modal-new").hidden = true);
  $("#modal-new-confirm").onclick = createToday;
  $("#modal-todos-close").onclick = () => ($("#modal-todos").hidden = true);
  $("#modal-quick-close").onclick = () => ($("#modal-quick").hidden = true);
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

// ---------- 启动 ----------

load();
bind();
render();
