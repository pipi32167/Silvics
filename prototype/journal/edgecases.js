/* 日记编辑器边界用例。
 *
 * 每条用例都有一个稳定编号（S/E/T/C/X/P），与 docs/日记编辑器边界用例.md 一一对应。
 * 编号的作用：写 Swift 实现时，直接拿编号对照验收，不再重新想一遍边角。
 *
 * kind = "auto" 由面板一键跑；"manual" 只能在真机上人工确认（输入法、跨行选区、撤销）。
 */

(function () {
  const M = () => window.SilvicsModel;

  // ---------- 断言小工具 ----------

  function eq(actual, expected, label) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    return { ok: a === e, detail: a === e ? "" : `${label || ""} 期望 ${e}，实际 ${a}` };
  }
  function truthy(value, label) {
    return { ok: !!value, detail: value ? "" : `${label || ""} 期望为真，实际为假` };
  }
  function falsy(value, label) {
    return { ok: !value, detail: value ? `${label || ""} 期望为假，实际为真` : "" };
  }
  function all(results) {
    const bad = results.filter((r) => !r.ok);
    return { ok: bad.length === 0, detail: bad.map((r) => r.detail).join("；") };
  }

  const D = (body, i = 0) => M().describeLines(body)[i];
  const html = (text) => M().inlineHTML(text);

  // ---------- 用例 ----------

  const CASES = [
    // ===== S：语法识别 =====
    {
      id: "S01", group: "语法", title: "`## 工作` 识别为二级标题",
      run: () => all([
        eq(D("## 工作").kind, "heading", "kind"),
        eq(D("## 工作").level, 2, "level"),
        eq(D("## 工作").text, "工作", "text"),
      ]),
    },
    {
      id: "S02", group: "语法", title: "`#工作`（# 后无空格）不是标题",
      run: () => eq(D("#工作").kind, "p", "kind"),
    },
    {
      id: "S03", group: "语法", title: "`#### 深` 只支持 1–3 级，四级当段落",
      run: () => eq(D("#### 深").kind, "p", "kind"),
    },
    {
      id: "S04", group: "语法", title: "`##   工作` 多余空格不进标题文本",
      run: () => all([eq(D("##   工作").text, "工作", "text"), eq(D("##   工作").level, 2)]),
    },
    {
      id: "S05", group: "语法", title: "`## ` 空标题保持为标题（内容为空）",
      run: () => eq(D("## ").kind, "heading", "kind"),
    },
    {
      id: "S06", group: "语法", title: "`- [ ] a` 识别为未完成待办",
      run: () => all([eq(D("- [ ] a").kind, "todo"), eq(D("- [ ] a").done, false), eq(D("- [ ] a").text, "a")]),
    },
    {
      id: "S07", group: "语法", title: "`- [X] a` 大写 X 也算已完成",
      run: () => eq(D("- [X] a").done, true, "done"),
    },
    {
      id: "S08", group: "语法", title: "`* [ ]` 与 `+ [x]` 也识别为待办（GFM）",
      run: () => all([eq(D("* [ ] a").kind, "todo"), eq(D("+ [x] b").kind, "todo")]),
    },
    {
      id: "S09", group: "语法", title: "`- [ ]a`（] 后无空格）不是待办",
      run: () => eq(D("- [ ]a").kind, "p", "kind"),
    },
    {
      id: "S10", group: "语法", title: "缩进两格的待办保留缩进量",
      run: () => all([eq(D("  - [ ] a").kind, "todo"), eq(D("  - [ ] a").indent, 2)]),
    },
    {
      id: "S11", group: "语法", title: "`[[a]]` 渲染成可点链接，目标为 a",
      run: () => all([
        truthy(html("[[a]]").includes('class="wikilink"'), "含 wikilink"),
        truthy(html("[[a]]").includes('data-target="a"'), "目标"),
      ]),
    },
    {
      id: "S12", group: "语法", title: "`[[a|显示]]` 目标取 a，显示取「显示」",
      run: () => all([
        truthy(html("[[a|显示]]").includes('data-target="a"'), "目标"),
        truthy(html("[[a|显示]]").includes(">显示<"), "显示名"),
      ]),
    },
    {
      id: "S13", group: "语法", title: "`[[a#锚点]]` 目标只取 a",
      run: () => truthy(html("[[a#锚点]]").includes('data-target="a"'), "目标"),
    },
    {
      id: "S14", group: "语法", title: "未闭合的 `[[a` 当纯文本",
      run: () => falsy(html("[[a").includes("wikilink"), "不应有链接"),
    },
    {
      id: "S15", group: "语法", title: "`[[ ]]` 空目标不产生链接",
      run: () => falsy(html("[[ ]]").includes("wikilink"), "不应有链接"),
    },
    {
      id: "S16", group: "语法", title: "行内代码里的 `[[a]]` 不变成链接",
      run: () => all([
        falsy(html("`[[a]]`").includes("wikilink"), "不应有链接"),
        truthy(html("`[[a]]`").includes("<code>"), "应是 code"),
      ]),
    },
    {
      id: "S17", group: "语法", title: "代码块里的 `## x` 不变成标题",
      run: () => eq(D("```\n## x\n```", 1).kind, "fence", "kind"),
    },
    {
      id: "S18", group: "语法", title: "`**粗**` 与 `*斜*` 正确配对",
      run: () => all([
        truthy(html("**粗**").includes("<strong>粗</strong>"), "粗体"),
        truthy(html("*斜*").includes("<em>斜</em>"), "斜体"),
      ]),
    },
    {
      id: "S19", group: "语法", title: "未闭合的 `**粗` 当纯文本",
      run: () => falsy(html("**粗").includes("<strong>"), "不应有 strong"),
    },
    {
      id: "S20", group: "语法", title: "`> 引用` 不特殊处理，原样显示",
      run: () => all([
        eq(D("> 引用").kind, "p", "kind"),
        truthy(html("> 引用").includes("&gt;"), "尖括号要转义"),
      ]),
    },
    {
      id: "S21", group: "语法", title: "`#标签` 不是标题（# 后无空格）",
      run: () => eq(D("#标签").kind, "p", "kind"),
    },
    {
      id: "S22", group: "语法", title: "行内代码里的 `**x**` 不被加粗",
      run: () => falsy(html("`**x**`").includes("<strong>"), "不应有 strong"),
    },

    // ===== E：文本编辑 =====
    {
      id: "E01", group: "编辑", title: "回车拆分：在第 2 个字符后拆分",
      run: () => {
        const r = M().Model.splitLine("abcdef", 0, 2);
        return all([eq(r.body, "ab\ncdef", "body"), eq(r.line, 1, "line"), eq(r.offset, 0, "offset")]);
      },
    },
    {
      id: "E02", group: "编辑", title: "行首退格：与上一行合并，光标落在接缝处",
      run: () => {
        const r = M().Model.mergeBackward("ab\ncdef", 1);
        return all([eq(r.body, "abcdef", "body"), eq(r.line, 0, "line"), eq(r.offset, 2, "offset")]);
      },
    },
    {
      id: "E03", group: "编辑", title: "行尾删除：把下一行并上来",
      run: () => {
        const r = M().Model.mergeForward("ab\ncdef", 0);
        return all([eq(r.body, "abcdef", "body"), eq(r.offset, 6, "offset")]);
      },
    },
    {
      id: "E04", group: "编辑", title: "勾选只改目标行，其他行一个字符不动",
      run: () => {
        const body = "- [ ] a\n- [ ] b\n- [ ] c";
        const out = M().Model.toggleTodo(body, 1);
        return eq(out, "- [ ] a\n- [x] b\n- [ ] c");
      },
    },
    {
      id: "E05", group: "编辑", title: "空文档也有一行，可以开始输入",
      run: () => all([eq(M().describeLines("").length, 1), eq(M().describeLines("")[0].kind, "blank")]),
    },
    {
      id: "E06", group: "编辑", title: "行尾空格原样保留，不被 trim",
      run: () => eq(M().Model.setLine("x", 0, "abc   "), "abc   "),
    },
    {
      id: "E07", group: "编辑", title: "删光当前行内容后行数不变",
      run: () => eq(M().Model.setLine("abc\ndef", 0, ""), "\ndef"),
    },
    {
      id: "E08", group: "编辑", title: "多行插入把内容插到指定行之前",
      run: () => {
        const r = M().Model.insertLines("a\nb", 1, ["x", "y"]);
        return eq(r.body, "a\nx\ny\nb");
      },
    },
    {
      id: "E09", group: "编辑", title: "空标题在回车后降级为空行（不留空 `##`）",
      run: () => eq(M().dropEmptyHeadings("## 工作\n\n## \n正文"), "## 工作\n\n\n正文"),
    },

    // ===== T：待办 =====
    {
      id: "T01", group: "待办", title: "勾选不改变条目文本",
      run: () => {
        const out = M().Model.toggleTodo("- [ ] 复核冲突留档", 0);
        return eq(out, "- [x] 复核冲突留档");
      },
    },
    {
      id: "T02", group: "待办", title: "勾两次回到未完成",
      run: () => {
        const once = M().Model.toggleTodo("- [ ] a", 0);
        return eq(M().Model.toggleTodo(once, 0), "- [ ] a");
      },
    },
    {
      id: "T03", group: "待办", title: "待办条目里的 `[[概念]]` 仍可点",
      run: () => truthy(html("查 [[标题即接口]]").includes("wikilink"), "含链接"),
    },
    {
      id: "T04", group: "待办", title: "已完成的条目不进待办总览",
      run: () => eq(M().openTodosIn("- [x] a\n- [ ] b"), ["b"]),
    },
    {
      id: "T05", group: "待办", title: "同一句话出现在两天，总览取最近一天的状态",
      run: () => {
        const journals = [
          { id: "a", date: "2026-11-21", body: "- [ ] 同一件事" },
          { id: "b", date: "2026-11-24", body: "- [x] 同一件事" },
        ];
        const open = M().aggregatedTodosOn(journals);
        const done = M().aggregatedTodosOn([
          { id: "a", date: "2026-11-21", body: "- [ ] 同一件事" },
          { id: "b", date: "2026-11-24", body: "- [ ] 同一件事" },
        ]);
        return all([
          eq(open.length, 0, "最近一天已勾掉，总览应为空"),
          eq(done.length, 1, "最近一天未完成，总览应有一条"),
          eq(done[0].days.length, 2, "应记录两天"),
        ]);
      },
    },
    {
      id: "T06", group: "待办", title: "删掉 `- [ ] ` 前缀后不再算待办",
      run: () => {
        const body = M().Model.setLine("- [ ] a", 0, "a");
        return eq(M().openTodosIn(body), []);
      },
    },

    // ===== C：承接 =====
    {
      id: "C01", group: "承接", title: "承接块 = 标题行 + 每条未完成一行",
      run: () => eq(M().carryLines("2026-11-21", ["a", "b"]), [
        "## 承接（来自 11-21）",
        "- [ ] a",
        "- [ ] b",
      ]),
    },
    {
      id: "C02", group: "承接", title: "插到指定行之前，条数等于来源未完成数",
      run: () => {
        const r = M().insertCarry("## 工作\n正文", 0, "2026-11-21", ["a", "b"], false);
        return all([
          truthy(r.body.startsWith("## 承接（来自 11-21）\n- [ ] a\n- [ ] b\n"), "块在文首"),
          eq(M().openTodosIn(r.body).length, 2, "条数"),
        ]);
      },
    },
    {
      id: "C03", group: "承接", title: "上一行不是空行时补一个空行",
      run: () => {
        const r = M().insertCarry("## 工作", 1, "2026-11-21", ["a"]);
        return truthy(r.body.includes("## 工作\n\n## 承接（来自 11-21）"), "补空行");
      },
    },
    {
      id: "C04", group: "承接", title: "已经在正文里的承接不重复插入",
      run: () => truthy(M().hasCarryFor("## 承接（来自 11-21）\n- [ ] a", "2026-11-21"), "判重"),
    },
    {
      id: "C05", group: "承接", title: "来源那天没有未完成项时不插入",
      run: () => eq(M().openTodosIn("## 工作\n- [x] 做完了"), []),
    },
    {
      id: "C06", group: "承接", title: "承接块插在文中间时，前后都有空行分隔",
      run: () => {
        const r = M().insertCarry("## 工作\n正文\n\n## 生活\n", 2, "2026-11-21", ["a"], true);
        return all([
          truthy(r.body.includes("正文\n\n## 承接（来自 11-21）"), "前空行"),
          truthy(r.body.includes("- [ ] a\n\n## 生活"), "后空行"),
        ]);
      },
    },

    // ===== X：与笔记系统的交叉 =====
    {
      id: "X01", group: "交叉", title: "代码块里的 `[[a]]` 不进反向链接",
      run: () => falsy(M().plainTextOf("```\n[[a]]\n```").includes("[[a]]"), "应被剔除"),
    },
    {
      id: "X02", group: "交叉", title: "正文里的 `[[a]]` 计入反向链接",
      run: () => truthy(M().plainTextOf("今天想通了 [[a]]").includes("[[a]]"), "应保留"),
    },
    {
      id: "X03", group: "交叉", title: "行内代码里的 `[[a]]` 也不进反向链接",
      run: () => falsy(M().plainTextOf("看 `[[a]]` 这段").includes("[[a]]"), "应被剔除"),
    },
    {
      id: "X04", group: "交叉", title: "提及扫描忽略方括号，只看裸标题",
      run: () => {
        const body = "写了 [[标题即接口]] 和裸写 标题即接口";
        const plain = M().plainTextOf(body).replace(/\[\[[^\]]+\]\]/g, "");
        return all([falsy(plain.includes("[[标题即接口]]"), "方括号应被剔除"), truthy(plain.includes("裸写 标题即接口"))]);
      },
    },

    // ===== P：性能 =====
    {
      id: "P01", group: "性能", title: "3000 行正文解析 < 50ms",
      run: () => {
        const body = Array.from({ length: 3000 }, (_, i) => (i % 3 === 0 ? `## 段 ${i}` : `第 ${i} 行正文`)).join("\n");
        const t0 = performance.now();
        M().describeLines(body);
        const ms = performance.now() - t0;
        return { ok: ms < 50, detail: `耗时 ${ms.toFixed(1)}ms` };
      },
    },
    {
      id: "P02", group: "性能", title: "5000 字的单行渲染 < 50ms",
      run: () => {
        const text = "字".repeat(5000);
        const t0 = performance.now();
        M().inlineHTML(text);
        const ms = performance.now() - t0;
        return { ok: ms < 50, detail: `耗时 ${ms.toFixed(1)}ms` };
      },
    },
  ];

  // 需要人工在真机上确认的用例，面板里只列清单
  const MANUAL = [
    { id: "I01", group: "输入法", title: "拼音组合期间不重绘、不丢字", how: "用系统拼音连续输入一句话，观察是否整字出现、有无吞字" },
    { id: "I02", group: "输入法", title: "组合结束后整行才刷新渲染", how: "打完一个词再点别的行，看该行是否变回渲染态" },
    { id: "I03", group: "输入法", title: "组合中按回车只上屏，不换行", how: "拼音未上屏时按回车，应只确认候选" },
    { id: "I04", group: "输入法", title: "组合中移动光标不触发重排", how: "拼音输入中途按方向键" },
    { id: "E10", group: "编辑", title: "跨行选中后删除/输入", how: "原型只允许单行编辑，跨行选区应被显式拒绝并给提示" },
    { id: "E11", group: "编辑", title: "撤销（⌘Z）", how: "原型不保证；实现时用 NSTextView 原生撤销栈" },
    { id: "E12", group: "编辑", title: "点击行中间，光标落在点击处", how: "实现里靠 TextKit 天然支持；原型落行尾" },
    { id: "E13", group: "编辑", title: "粘贴 HTML（从网页复制）只取纯文本", how: "从浏览器复制一段带样式的文字粘进日记" },
    { id: "E14", group: "编辑", title: "粘贴多行 Markdown 逐行解析", how: "复制三行含 `##` 与 `- [ ]` 的文本粘贴" },
  ];

  window.EDGE_CASES = { CASES, MANUAL };

  // ---------- 面板 ----------

  window.runEdgeCases = function () {
    const results = CASES.map((c) => {
      let res;
      try {
        res = c.run();
      } catch (err) {
        res = { ok: false, detail: "抛错：" + err.message };
      }
      return { ...c, ...res };
    });
    const pass = results.filter((r) => r.ok).length;
    const fail = results.length - pass;

    const row = (r) => `<tr class="${r.ok ? "pass" : "fail"}">
      <td class="id">${r.id}</td>
      <td>${r.title}</td>
      <td class="verdict">${r.ok ? "通过" : "失败"}</td>
      <td class="detail">${r.detail ? r.detail.replace(/</g, "&lt;") : ""}</td>
    </tr>`;

    $("#test-summary").textContent = `${pass} 通过 / ${fail} 失败 / ${MANUAL.length} 条需人工`;
    $("#test-summary").className = fail ? "fail" : "pass";
    $("#test-body").innerHTML = results.map(row).join("");
    $("#test-manual").innerHTML = MANUAL.map(
      (m) => `<li><b>${m.id}</b> ${m.title}<span class="muted"> — ${m.how}</span></li>`
    ).join("");
    $("#modal-tests").hidden = false;
    return { pass, fail };
  };
})();
