/* Silvics 日记 · 低保真原型
 *
 * 只做能点的界面与状态变化，不做 Markdown 渲染、不做补全、不做持久化到 vault。
 * 所有数据在 SEED 里，用户点击结果存 localStorage，方便反复评审。
 */

const TODAY = "2026-11-24";
const STORAGE_KEY = "silvics.journal.proto.v1";

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
      sections: [
        {
          name: "工作",
          items: [
            { text: "写完同步方案的验收项", done: true },
            { text: "把 0.1.1 的坑补进 HANDOFF", done: false },
          ],
          paras: [],
        },
        {
          name: "生活",
          items: [{ text: "复核同步的冲突留档", done: false }],
          paras: ["今天重读 [[标题即接口]] 这一段，有了新感觉。"],
        },
      ],
    },
    {
      id: "j20261123",
      date: "2026-11-23",
      sections: [
        {
          name: "承接",
          carriedFrom: "2026-11-21",
          items: [
            { text: "把 0.1.1 的坑补进 HANDOFF", done: false },
            { text: "复核同步的冲突留档", done: false },
          ],
          paras: [],
        },
        {
          name: "工作",
          items: [
            { text: "讨论日记方案", done: true },
            { text: "补 issue 里五个待定项", done: false },
          ],
          paras: [],
        },
        {
          name: "生活",
          items: [],
          paras: [
            "早上跑步 5 公里，[[稀疏重复优于集中突击]] 在跑步上同样成立。",
            "另外想到标题即接口这件事 —— 这里故意不写引用，用来演示未链接提及。",
          ],
        },
      ],
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
    highlight: null,
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

function noteByTitle(title) {
  return state.notes.find((n) => n.title === title);
}

function journalByDate(date) {
  return state.journals.find((j) => j.date === date);
}

function allJournalTexts(j) {
  return j.sections.flatMap((s) => [...s.items.map((i) => i.text), ...s.paras]);
}

function journalOpenItems(j) {
  return j.sections.flatMap((s) => s.items.filter((i) => !i.done).map((i) => i.text));
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
    const hit = allJournalTexts(j).find((t) => t.includes(`[[${title}]]`));
    if (hit) out.push({ type: "journal", date: j.date, label: `${j.date} 日记`, snippet: hit });
  }
  return out;
}

/** 日记里「没加 [[ ]] 就写了概念标题」的地方。 */
function mentionsIn(j) {
  const texts = allJournalTexts(j);
  const plain = texts.join("\n").replace(/\[\[[^\]]+\]\]/g, "");
  return state.notes
    .filter((n) => plain.includes(n.title))
    .map((n) => ({
      title: n.title,
      snippet: texts.find((t) => t.includes(n.title)) || "",
    }));
}

function orphans() {
  return state.notes.filter((n) => {
    const hasOut = /\[\[[^\]]+\]\]/.test(n.body);
    const hasIn = state.notes.some((o) => o.id !== n.id && o.body.includes(`[[${n.title}]]`))
      || state.journals.some((j) => allJournalTexts(j).some((t) => t.includes(`[[${n.title}]]`)));
    return !hasOut && !hasIn;
  });
}

/** 跨日记聚合待办：同一句话取最近一天的状态。 */
function aggregatedTodos() {
  const map = new Map();
  for (const j of [...state.journals].sort((a, b) => a.date.localeCompare(b.date))) {
    for (const s of j.sections) {
      for (const it of s.items) {
        const key = it.text.trim();
        if (!key) continue;
        const rec = map.get(key) || { text: key, days: [], done: false, date: j.date };
        if (!rec.days.includes(j.date)) rec.days.push(j.date);
        rec.done = it.done;
        rec.latest = j.date;
        map.set(key, rec);
      }
    }
  }
  return [...map.values()]
    .filter((r) => !r.done)
    .sort((a, b) => (b.latest || "").localeCompare(a.latest || ""));
}

/** 「上一个有日记的日子」：不跳天，就是最近那篇。 */
function previousJournal(beforeDate) {
  const earlier = state.journals
    .filter((j) => j.date < beforeDate)
    .sort((a, b) => b.date.localeCompare(a.date));
  return earlier[0] || null;
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

  document.querySelectorAll("#scope-all, #scope-journal, #scope-orphan").forEach((b) => {
    b.classList.toggle("on", b.dataset.scope === state.scope);
  });
  document.querySelectorAll("#search-scope button").forEach((b) => {
    b.classList.toggle("on", b.dataset.scope === state.searchScope);
  });

  const list = $("#list");
  const q = state.search.trim();

  if (state.scope === "journal") {
    $("#list-title").textContent = "日记（倒序）";
    const rows = [...state.journals]
      .sort((a, b) => b.date.localeCompare(a.date))
      .map((j) => {
        const open = journalOpenItems(j).length;
        const on = state.selection.type === "journal" && state.selection.id === j.id;
        const dot = open ? `<span class="dot" title="有 ${open} 条未完成"></span>` : "";
        return `<button class="item journal ${on ? "on" : ""}" data-kind="journal" data-id="${j.id}">
          <span class="date">${j.date}</span>${dot}
          <span class="sub">${weekday(j.date)} · 未完成 ${open} 条</span>
        </button>`;
      });
    list.innerHTML = rows.join("") || `<div class="hint">还没有日记</div>`;
    return;
  }

  $("#list-title").textContent = state.scope === "orphan" ? "孤儿笔记" : "笔记";
  let notes = state.scope === "orphan" ? orphans() : state.notes;
  if (q) {
    notes = notes.filter((n) => n.title.includes(q) || n.body.includes(q));
  }
  const noteRows = notes.map((n) => {
    const on = state.selection.type === "note" && state.selection.id === n.id;
    const bl = backlinksFor(n.title).length;
    return `<button class="item ${on ? "on" : ""}" data-kind="note" data-id="${n.id}">
      ${esc(n.title)}
      <span class="sub">被引用 ${bl}</span>
    </button>`;
  });

  // 搜索范围内含日记时，命中正文的日记也列出来
  const journalRows =
    q && state.searchScope === "all"
      ? state.journals
          .filter((j) => allJournalTexts(j).some((t) => t.includes(q)) || j.date.includes(q))
          .sort((a, b) => b.date.localeCompare(a.date))
          .map((j) => `<button class="item journal" data-kind="journal" data-id="${j.id}">
            <span class="date">${j.date}</span>
            <span class="sub">日记 · 命中正文</span>
          </button>`)
      : [];

  list.innerHTML = [...noteRows, ...journalRows].join("") || `<div class="hint">没有命中</div>`;
}

function renderEditor() {
  const el = $("#editor");
  if (state.selection.type === "note") {
    const n = state.notes.find((x) => x.id === state.selection.id);
    if (!n) {
      el.innerHTML = `<div class="empty">笔记不存在</div>`;
      return;
    }
    el.innerHTML = `
      <div class="note-head">
        <h1>${esc(n.title)}</h1>
        <div class="note-meta">概念笔记 · 反向链接 ${backlinksFor(n.title).length} 条</div>
      </div>
      <div class="note-body">
        ${n.body.split("\n").map((p) => `<p>${renderWikilinks(p)}</p>`).join("")}
      </div>`;
    bindWikilinks();
    return;
  }

  const j = state.journals.find((x) => x.id === state.selection.id);
  if (!j) {
    el.innerHTML = `<div class="empty">日记不存在</div>`;
    return;
  }

  const sections = j.sections
    .map((s) => {
      const head = s.carriedFrom
        ? `<h2>承接 <span class="src">（来自 ${s.carriedFrom.slice(5)}）</span></h2>`
        : `<h2>${esc(s.name)}</h2>`;
      const items = s.items
        .map(
          (it, idx) => `<li class="${it.done ? "done" : ""}" data-item="${idx}" data-section="${esc(s.name)}">
            <input type="checkbox" ${it.done ? "checked" : ""}
                   data-toggle="${idx}" data-section="${esc(s.name)}">
            <span class="text">${renderWikilinks(it.text)}</span>
          </li>`
        )
        .join("");
      const paras = s.paras.map((p) => `<p>${renderWikilinks(p)}</p>`).join("");
      return `<div class="section">${head}<ul>${items}</ul>${paras}</div>`;
    })
    .join("");

  el.innerHTML = `
    <div class="journal-head">
      <h1>${j.date}</h1>
      <span class="wkd">${weekday(j.date)}</span>
      <span class="tag">日记 · 不可改名 · 不进 ⌘P</span>
    </div>
    ${sections}
    <div class="composer">
      <input id="composer" type="text" placeholder="写一条…（支持 [[概念]]）">
      <button id="composer-add">添加</button>
    </div>
    ${
      j.id === todayJournalId()
        ? `<div class="callout">勾掉这里的条目不会改昨天那一份。历史保留未完成，待办总览按「最近一天的状态」聚合。</div>`
        : ""
    }`;

  bindWikilinks();
  bindJournalEditor(j);
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
          (b) => `<button class="item" data-kind="${b.type}" ${b.type === "note" ? `data-id="${b.id}"` : `data-date="${b.date}"`}>
            ${esc(b.label)}<span class="sub">${esc(b.snippet.slice(0, 28))}…</span>
          </button>`
        )
        .join("") || `<div class="hint">还没有反向链接</div>`;
    el.querySelectorAll(".item").forEach((btn) => {
      btn.onclick = () => {
        if (btn.dataset.kind === "note") selectNote(btn.dataset.id);
        else selectJournalByDate(btn.dataset.date);
      };
    });

    $("#mentions").innerHTML = "";
    $("#mention-hint").textContent = "提及面板只对日记有意义，这条是概念笔记。";
    return;
  }

  const j = state.journals.find((x) => x.id === sel.id);
  if (!j) return;

  // 日记视角：这里演示「日记作为来源」出现在谁的反向链接里
  const asSource = state.notes.filter((n) => allJournalTexts(j).some((t) => t.includes(`[[${n.title}]]`)));
  el.innerHTML =
    asSource
      .map((n) => `<button class="item" data-kind="note" data-id="${n.id}">
        ${esc(n.title)}<span class="sub">这一天引用了它</span>
      </button>`)
      .join("") || `<div class="hint">这一天还没引用任何概念</div>`;
  el.querySelectorAll(".item").forEach((btn) => {
    btn.onclick = () => selectNote(btn.dataset.id);
  });

  const toggle = $("#toggle-journal-mentions");
  toggle.checked = state.journalMentions;

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

function bindWikilinks() {
  document.querySelectorAll(".wikilink").forEach((el) => {
    el.onclick = () => {
      const target = el.dataset.target;
      const n = noteByTitle(target);
      if (n) selectNote(n.id);
      else toast(`「${target}」还没有笔记（悬空引用）`);
    };
  });
}

function bindJournalEditor(j) {
  document.querySelectorAll("input[data-toggle]").forEach((box) => {
    box.onchange = () => {
      const section = j.sections.find((s) => s.name === box.dataset.section);
      const item = section.items[Number(box.dataset.toggle)];
      item.done = box.checked;
      render();
      if (section.carriedFrom && box.checked) {
        toast(`已勾掉。${section.carriedFrom} 那份仍是未完成 —— 历史不改，总览按最近一天算。`);
      }
    };
  });

  const input = $("#composer");
  const add = () => {
    const text = input.value.trim();
    if (!text) return;
    const last = j.sections[j.sections.length - 1];
    last.paras.push(text);
    input.value = "";
    render();
    // 新加的内容里如果出现某条笔记标题，提示它成为了反向链接来源
    const hit = state.notes.find((n) => text.includes(n.title));
    if (hit) toast(`已记录。「${hit.title}」的反向链接会多出「${j.date} 日记」`);
  };
  $("#composer-add").onclick = add;
  input.onkeydown = (e) => {
    if (e.key === "Enter") add();
  };
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

function todayJournalId() {
  return journalByDate(TODAY)?.id || null;
}

function goToday() {
  if (todayJournalId()) {
    selectJournalByDate(TODAY);
  } else {
    toast("还没有今天的日记。点「新建今天的日记」。");
    openNewToday();
  }
}

// ---------- 新建今天的日记 ----------

function openNewToday() {
  if (todayJournalId()) {
    toast("今天已经有日记了。不会再承接一次，避免重复。");
    selectJournalByDate(TODAY);
    return;
  }
  const picker = $("#module-picker");
  picker.innerHTML = state.templates
    .slice()
    .sort((a, b) => a.order - b.order)
    .map(
      (t) => `<label><input type="checkbox" value="${esc(t.name)}"
        ${state.lastModules.includes(t.name) ? "checked" : ""}> ${esc(t.name)}</label>`
    )
    .join("");

  renderCarryPreview();
  picker.onchange = renderCarryPreview;
  $("#modal-new").hidden = false;
}

function renderCarryPreview() {
  const prev = previousJournal(TODAY);
  const box = $("#carry-preview");
  if (!prev) {
    box.textContent = "没有更早的日记，今天不承接。";
    return;
  }
  const open = journalOpenItems(prev);
  box.textContent = open.length
    ? `来自 ${prev.date}（上一个有日记的日子），将带入 ${open.length} 条未完成：\n` +
      open.map((t) => `· ${t}`).join("\n")
    : `来自 ${prev.date}，那天没有未完成项，不需要承接。`;
}

function createToday() {
  const picked = [...document.querySelectorAll("#module-picker input:checked")].map((i) => i.value);
  if (!picked.length) {
    toast("至少选一个模块");
    return;
  }
  const prev = previousJournal(TODAY);
  const sections = [];

  if (prev) {
    const open = journalOpenItems(prev);
    if (open.length) {
      sections.push({
        name: "承接",
        carriedFrom: prev.date,
        items: open.map((text) => ({ text, done: false })),
        paras: [],
      });
    }
  }

  for (const name of picked) {
    sections.push({ name, items: [], paras: [] });
  }

  const j = { id: `j${TODAY.replace(/-/g, "")}`, date: TODAY, sections };
  state.journals.push(j);
  state.lastModules = picked;
  state.selection = { type: "journal", id: j.id };
  state.scope = "journal";
  $("#modal-new").hidden = true;
  render();
  toast(`已创建 ${TODAY}。承接 ${sections[0]?.carriedFrom ? sections[0].items.length : 0} 条未完成。`);
}

// ---------- 待办总览 ----------

function openTodos() {
  const rows = aggregatedTodos();
  $("#todo-list").innerHTML =
    rows
      .map(
        (r) => `<button class="item" data-date="${r.latest}" data-text="${esc(r.text)}">
          ${esc(r.text)}
          <span class="sub">最近出现在 ${r.latest}${r.days.length > 1 ? ` · 共 ${r.days.length} 天` : ""}</span>
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
    document.querySelectorAll(".section li").forEach((li) => {
      if (li.textContent.includes(text)) {
        li.classList.add("hit");
        li.scrollIntoView({ block: "center" });
      }
    });
  }, 30);
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
    notes
      .map((n) => `<button class="item" data-id="${n.id}">${esc(n.title)}</button>`)
      .join("") || `<div class="hint">没有命中</div>`;
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
  toastTimer = setTimeout(() => (el.hidden = true), 3600);
}

// ---------- 事件绑定 ----------

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
    if (btn.dataset.kind === "journal") selectJournalByDate(
      state.journals.find((j) => j.id === btn.dataset.id)?.date
    );
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
    if (!(e.metaKey || e.ctrlKey) || !e.shiftKey) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "p") {
        e.preventDefault();
        openQuick();
      }
      return;
    }
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
