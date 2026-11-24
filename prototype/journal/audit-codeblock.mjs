// 代码块真实交互审计：不是页内单测，而是真的在浏览器里点、敲、粘。
//
// 用法：
//   cd prototype/journal && python3 -m http.server 8791
//   ego-browser nodejs < prototype/journal/audit-codeblock.mjs
//
// 与 edgecases.js 的分工：页内 77 条是纯函数 / 渲染用例，跑得快；
// 这里 28 条是端到端交互（键入、回车、退格、粘贴、方向键、300 行耗时），
// 覆盖「键盘事件 → DOM → 模型 → 重渲染」整条链路。
const task = await taskSpace("codeblock audit");
const page = task.page("p1");
const URL = "http://127.0.0.1:8791/index.html";

const results = [];
const check = (name, ok, detail = "") => results.push({ name, ok: !!ok, detail });
const T = (n) => `\n== ${n}`;

await page.cdp("Network.enable");
await page.cdp("Network.setCacheDisabled", { cacheDisabled: true });

// ---------- 工具 ----------

async function fresh() {
  await page.goto(URL);
  await page.evaluate(() => localStorage.clear());
  await page.goto(URL);
  await page.waitForSelector("#editor");
}

/** 把日记正文设成给定内容并渲染 */
async function setBody(lines) {
  await page.evaluate((body) => {
    const s = window.SilvicsModel.getState();
    const j = s.journals.find((x) => x.date === "2026-11-23");
    j.body = body;
    window.SilvicsModel.selectJournalByDate("2026-11-23");
    window.SilvicsModel.activateLine(0, 0);
  }, lines.join("\n"));
  await page.waitForSelector("#doc");
  await page.waitForTimeout(80);
}

const body = () =>
  page.evaluate(() => window.SilvicsModel.getState().journals.find((j) => j.date === "2026-11-23").body);

const kinds = () =>
  page.evaluate(() => {
    const b = window.SilvicsModel.getState().journals.find((j) => j.date === "2026-11-23").body;
    return window.SilvicsModel.describeLines(b).map((d) => `${d.i}:${d.kind}${d.isMark ? "*" : ""}`);
  });

const tokCount = (cls) =>
  page.evaluate((c) => document.querySelectorAll(`#doc .line.code span.tok-${c}`).length, cls);

async function clickLine(i) {
  await page.evaluate((idx) => {
    const el = document.querySelector(`#doc .line[data-i='${idx}']`);
    if (el) el.click();
  }, i);
  await page.waitForTimeout(120);
}

async function caretTo(i, off) {
  await page.evaluate(
    ([idx, o]) => {
      window.SilvicsModel.activateLine(idx, o);
    },
    [i, off],
  );
  await page.waitForTimeout(100);
}

const active = () => page.evaluate(() => Number(document.querySelector("#doc .line.active").dataset.i));

// ---------- C1 基础：键入一个 swift 代码块 ----------
await fresh();
await setBody(["## 工作", "", "正文"]);
await caretTo(2, 2);
await page.keyboard.press("Enter");
await page.keyboard.type("```swift\n");
await page.keyboard.type("func f() -> Int { return 1 } // ok\n");
await page.keyboard.type("```");
await page.waitForTimeout(200);
{
  const b = await body();
  const lines = b.split("\n");
  check("C1 代码块落在正确的三行", lines[3] === "```swift" && lines[5] === "```", lines.slice(2, 7).join(" | "));
  check("C1 关键字有高亮", (await tokCount("kw")) >= 2, `kw=${await tokCount("kw")}`);
  check("C1 注释有高亮", (await tokCount("com")) >= 1, `com=${await tokCount("com")}`);
  check("C1 数字有高亮", (await tokCount("num")) >= 1, `num=${await tokCount("num")}`);
}

// ---------- C2 点进去改代码行，离开后重新高亮 ----------
await clickLine(4);
{
  const isRaw = await page.evaluate(() =>
    document.querySelector("#doc .line.active").textContent.startsWith("func f()"),
  );
  check("C2 激活行显示源码", isRaw);
  const spansInActive = await page.evaluate(
    () => document.querySelectorAll("#doc .line.active span[class^='tok-']").length,
  );
  check("C2 激活行不再带 token span", spansInActive === 0, `spans=${spansInActive}`);
}
await page.keyboard.press("End");
await page.keyboard.type(" // changed");
await page.waitForTimeout(120);
await clickLine(0);
{
  const b = await body();
  check("C2 编辑写回正文", b.includes("return 1 } // ok // changed"), b.split("\n")[4]);
  const hasTok = await page.evaluate(() => {
    const line = [...document.querySelectorAll("#doc .line.code")].find((l) => l.textContent.includes("changed"));
    return line ? line.querySelectorAll("span[class^='tok-']").length > 0 : false;
  });
  check("C2 离开后重新高亮", hasTok);
}

// ---------- C3 块内回车继续留在块里 ----------
await clickLine(4);
await page.keyboard.press("End");
await page.keyboard.press("Enter");
await page.keyboard.type("let x = 2");
await page.waitForTimeout(150);
{
  const k = await kinds();
  const hit = k.find((s) => s.includes(":fence"));
  const bodyLines = (await body()).split("\n");
  const idx = bodyLines.findIndex((l) => l === "let x = 2");
  check(
    "C3 新行仍在代码块内",
    idx > 0 && k[idx] === `${idx}:fence`,
    `idx=${idx} kinds=${k.slice(-5).join(" ")} body=${JSON.stringify(bodyLines.slice(3, 8))}`,
  );
}

// ---------- C4 删掉闭合围栏 → 后文变代码 ----------
await fresh();
await setBody(["```js", "let a = 1", "```", "", "后面的段落"]);
{
  const before = await kinds();
  check("C4 初始后文是段落", before[4] === "4:p", before.join(" "));
}
await caretTo(2, 3);
await page.keyboard.press("Backspace");
await page.keyboard.press("Backspace");
await page.keyboard.press("Backspace");
await page.keyboard.press("Backspace");
await page.waitForTimeout(200);
{
  const b = await body();
  const k = await kinds();
  check("C4 闭合围栏被删", b.split("\n")[2] === "", JSON.stringify(b.split("\n")));
  const allLines = (await body()).split("\n");
  const paraIdx = allLines.findIndex((l) => l.includes("后面的段落"));
  check("C4 后文变成代码", k[paraIdx] === `${paraIdx}:fence`, `${k.join(" ")} | paraIdx=${paraIdx}`);
}

// ---------- C5 在围栏行上补语言标记 → 换语言高亮 ----------
await fresh();
await setBody(["```", "func f() {}", "```"]);
{
  const kwBefore = await tokCount("kw");
  check("C5 无语言标记时不认 swift 关键字", kwBefore === 0, `kw=${kwBefore}`);
}
await clickLine(0);
await page.keyboard.press("End");
await page.keyboard.type("swift");
await page.waitForTimeout(150);
{
  const b = await body();
  check("C5 围栏行写入了语言", b.split("\n")[0] === "```swift", b.split("\n")[0]);
  await clickLine(1); // 先离开围栏行
  await clickLine(0); // 再回来，触发整块重渲染
  const kwAfter = await tokCount("kw");
  check("C5 补语言后有关键字高亮", kwAfter >= 1, `kw=${kwAfter}`);
}

// ---------- C6 语言标记写错 → 通用词法，不报错 ----------
await fresh();
await setBody(["```swiftx", "func f() {} // x", "```"]);
{
  const err = await page.evaluate(() => [...document.querySelectorAll("#doc .line")].length);
  check("C6 未知语言不报错、仍渲染", err >= 3, `lines=${err}`);
  const com = await tokCount("com");
  check("C6 通用词法仍识别注释", com >= 1, `com=${com}`);
}

// ---------- C7 空代码块 ----------
await fresh();
await setBody(["```", "```", "后面"]);
{
  const k = await kinds();
  check("C7 空块不产生内容行", k.length === 3, k.join(" "));
  const box = await page.evaluate(
    () => [...document.querySelectorAll("#doc .line.code")].every((l) => l.textContent.trim().startsWith("```")),
  );
  check("C7 空块只渲染两行围栏", box);
}

// ---------- C8 块内 `##` 与 `[[ ]]` 不解析 ----------
await fresh();
await setBody(["```md", "## 不是标题", "[[不是链接]]", "```"]);
{
  const h = await page.evaluate(() => document.querySelectorAll("#doc .line.h1, #doc .line.h2").length);
  const link = await page.evaluate(() => document.querySelectorAll("#doc .wikilink").length);
  const linkInsideCode = await page.evaluate(
    () => [...document.querySelectorAll("#doc .line.code")].some((l) => l.querySelector(".wikilink")),
  );
  check("C8 块内不生成标题", h === 0, `h=${h}`);
  check("C8 块内不生成链接", link === 0 && !linkInsideCode, `link=${link}`);
}

// ---------- C9 粘贴多行代码 ----------
await fresh();
await setBody(["正文"]);
await caretTo(0, 2);
await page.keyboard.press("Enter");
await page.evaluate(() => {
  const dt = new DataTransfer();
  dt.setData("text/plain", "```python\n# 注释\ndef f():\n    return 1\n```");
  document
    .querySelector("#doc")
    .dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
});
await page.waitForTimeout(250);
{
  const k = await kinds();
  const b = await body();
  check("C9 粘贴后形成代码块", k.filter((s) => s.includes(":fence")).length === 5, k.join(" "));
  check("C9 python 注释/关键字高亮", (await tokCount("com")) >= 1 && (await tokCount("kw")) >= 1);
  check("C9 内容未丢字", b.includes("def f():") && b.includes("    return 1"), JSON.stringify(b.split("\n").slice(-6)));
}

// ---------- C10 复制文本完整性：渲染不丢字 ----------
await fresh();
await setBody(["```swift", "let a = 1 // 注释含 < > & \" 引号", "```"]);
{
  const rendered = await page.evaluate(() => {
    const line = [...document.querySelectorAll("#doc .line.code")].find((l) => l.textContent.includes("let a"));
    return line ? line.textContent : null;
  });
  check("C10 渲染文本与原文字符一致", rendered === 'let a = 1 // 注释含 < > & " 引号', rendered);
}

// ---------- C11 大块渲染耗时 ----------
await fresh();
const big = ["```js"].concat(Array.from({ length: 300 }, (_, i) => `const v${i} = ${i}; // 第 ${i} 行`)).concat(["```"]);
const t0 = Date.now();
await setBody(big);
const ms = Date.now() - t0;
check("C11 300 行代码块渲染 < 1500ms", ms < 1500, `${ms}ms`);

// ---------- C12 代码块内的方向键跨行 ----------
await fresh();
await setBody(["```js", "let a = 1", "let b = 2", "```"]);
await caretTo(1, 3);
await page.keyboard.press("ArrowDown");
await page.waitForTimeout(150);
check("C12 ↓ 在块内跨到下一行", (await active()) === 2, `active=${await active()}`);
await page.keyboard.press("ArrowDown");
await page.waitForTimeout(150);
check("C12 ↓ 跨到闭合围栏行", (await active()) === 3, `active=${await active()}`);

// ---------- 汇总 ----------
const failed = results.filter((r) => !r.ok);
console.log(
  results.map((r) => `${r.ok ? "PASS" : "FAIL"}  ${r.name}${r.detail && !r.ok ? "  ← " + r.detail : ""}`).join("\n"),
);
console.log(`\n${results.length - failed.length}/${results.length} 通过`);
await page.screenshot({ path: "/tmp/reports/silvics-journal-proto/v4/codeblock-audit.png" });
