#if DEBUG
import Foundation

/// 开发用演示数据。仅在设置了 `SILVICS_SEED=1` 且库为空时写入。
/// Release 构建不包含这个文件。
enum DemoSeeder {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SILVICS_SEED"] == "1"
    }

    struct Seed {
        var title: String
        var status: NoteStatus
        var body: String
    }

    static let seeds: [Seed] = [
        Seed(
            title: "稀疏重复优于集中突击",
            status: .evergreen,
            body: """
            集中突击可以短期记住更多，但[[遗忘曲线决定复习时机]]决定了长期留存。
            把同样的总时长摊到多天，[[间隔重复能提高长期留存]]。

            这条结论的前提是「总投入时间相同」。总时长不同时不成立。
            """
        ),
        Seed(
            title: "遗忘曲线决定复习时机",
            status: .evergreen,
            body: """
            记忆强度随时间指数衰减。衰减最快的区间是刚学完的头几小时。

            因此第一次复习要尽量贴近[[间隔重复能提高长期留存]]的关键点，
            而不是等忘干净再重学。重学的成本远高于复习。
            """
        ),
        Seed(
            title: "间隔重复能提高长期留存",
            status: .evergreen,
            body: """
            相邻两次复习的间隔应随记忆强度增长而拉长。

            这是[[稀疏重复优于集中突击]]的机制解释。
            配合[[主动回忆比重读更有效]]，效果叠加。
            """
        ),
        Seed(
            title: "主动回忆比重读更有效",
            status: .budding,
            body: """
            重读带来「熟悉感」，熟悉感会被误判为掌握。
            合上书回忆一次，暴露的是真实缺口。

            所以[[检索练习能暴露理解缺口]]，而重读不能。
            """
        ),
        Seed(
            title: "检索练习能暴露理解缺口",
            status: .budding,
            body: """
            输出比输入更能检验理解。这也解释了[[写作是最有效的思考方式]]。

            与[[理解需要费力参与]]同源：不费力就没有编码。
            """
        ),
        Seed(
            title: "写作是最有效的思考方式",
            status: .evergreen,
            body: """
            写作强迫把模糊的直觉压成可检验的句子。压不下去的地方，就是没想清楚的地方。

            因此[[理解需要费力参与]]，而[[笔记标题应当写成断言句]]是这条原则的落地形式。
            """
        ),
        Seed(
            title: "理解需要费力参与",
            status: .evergreen,
            body: """
            被动接收不产生长期记忆。费力加工才产生。 #记忆

            这条原则支撑了[[检索练习能暴露理解缺口]]与[[写作是最有效的思考方式]]。
            """
        ),
        Seed(
            title: "笔记应该原子化",
            status: .evergreen,
            body: """
            一条笔记只装一个概念。装两个概念的笔记，将来只能被引用一半。

            与[[笔记应该以概念为中心]]配套：原子化定义粒度，概念导向定义归属。
            """
        ),
        Seed(
            title: "笔记应该以概念为中心",
            status: .evergreen,
            body: """
            笔记属于概念，不属于书、作者或日期。

            「读完某本书的感想」这种归属，在半年后就失效了。
            概念归属不会失效。这也是[[笔记应该原子化]]的另一面。
            """
        ),
        Seed(
            title: "笔记应该密集链接",
            status: .evergreen,
            body: """
            建链接的成本必须接近零，链接才会真的发生。 #笔记方法

            这是本产品要做自动连接的全部理由：[[未链接提及是低成本的连接来源]]，
            [[语义近邻只能作为建议]]。

            与[[联想式组织优于层级分类]]一致。写完之后不做每日回顾能激活沉睡的笔记，图就会慢慢冷掉。
            """
        ),
        Seed(
            title: "联想式组织优于层级分类",
            status: .budding,
            body: """
            层级分类要求每条笔记属于唯一父节点。真实的概念不满足这个约束。

            用图代替树。前提是[[笔记应该密集链接]]，否则图会碎成孤岛。
            """
        ),
        Seed(
            title: "笔记标题应当写成断言句",
            status: .evergreen,
            body: """
            标题写成「稀疏重复优于集中突击」，就能在别的笔记正文里当作句子使用。 #写作
            机器因此能定位它，连接才能自动成立。

            这是[[笔记应该以概念为中心]]的可执行形式，
            也是[[未链接提及是低成本的连接来源]]的前提。
            """
        ),
        Seed(
            title: "未链接提及是低成本的连接来源",
            status: .budding,
            body: """
            正文里出现的已有标题，可以直接变成引用。用户不需要重新想一次。

            比[[语义近邻只能作为建议]]可靠得多，因为它是字符串精确匹配，不是推测。
            前提仍是[[笔记标题应当写成断言句]]。
            """
        ),
        Seed(
            title: "语义近邻只能作为建议",
            status: .seedling,
            body: """
            向量相似度会误报。本机实测中，无关句与相关句的相似度只差 0.005。

            因此这一层永远不进正文、不进主图，只出现在侧栏。
            这是[[笔记应该密集链接]]里「硬连接与软连接分离」的来源。
            """
        ),
        Seed(
            title: "常绿笔记会随时间累积价值",
            status: .evergreen,
            body: """
            临时笔记写完就死。常绿笔记每被引用一次就多一层上下文。

            前提是[[笔记应该原子化]]与[[笔记应该密集链接]]。
            """
        ),
        Seed(
            title: "反向链接需要带上下文片段",
            status: .budding,
            body: """
            只给来源标题没有用。用户需要看到「在什么语境下被引用」。

            这与[[常绿笔记会随时间累积价值]]直接相关：上下文是价值本身。
            """
        ),
        Seed(
            title: "概念重复会导致知识分裂",
            status: .budding,
            body: """
            同一条概念被写成两条笔记，引用就分散到两处，两处都不完整。

            因此新建笔记时必须查重。与[[笔记应该以概念为中心]]配套。
            """
        ),
        Seed(
            title: "编辑器的手感决定写作频率",
            status: .seedling,
            body: """
            写作工具的核心指标不是功能数量，是每次开口的摩擦。

            中文输入是这条路径上最脆弱的一环，见[[中文输入是笔记应用的关键路径]]。

            另一条会影响频率的是笔记应该密集链接：链接越少，回来查东西的动力越小。
            """
        ),
        Seed(
            title: "中文输入是笔记应用的关键路径",
            status: .seedling,
            body: """
            中文输入法有组合期。组合期内任何文本重排、光标移动、属性重写都可能出错。 #工程

            结论：不走 Web 编辑器，用原生 NSTextView。
            这也是[[编辑器的手感决定写作频率]]的具体约束。
            """
        ),
        Seed(
            title: "每日回顾能激活沉睡的笔记",
            status: .seedling,
            body: """
            库里超过一半的笔记长期不被访问。它们不是没价值，是没入口。 #回顾

            入口来自[[笔记应该密集链接]]，也来自[[反向链接需要带上下文片段]]。
            """
        ),
        Seed(
            title: "冷启动阶段先跑通写作流程再谈连接质量",
            status: .seedling,
            body: """
            前两周只有几十条笔记，自动连接的收益还不明显。

            这时候先保证每天都写。连接密度是结果，不是前提。
            """
        ),
        // 代码高亮取证用：六种语言各一个块，围栏行本身不该上色（见批次 5 的截图验收）。
        Seed(
            title: "代码高亮取证",
            status: .evergreen,
            body: #"""
            六个块，六种词法。围栏行不上色，块内按语言上色。
            ```swift
            // 计数器
            struct Counter {
                let hits = 0x1F
                func bump(_ step: Int) -> Int { return hits + step }
            }
            ```
            ```js
            const label = "step // 不是注释";
            function bump(n) { return n * 1.5e-3; } // 真注释
            ```
            ```python
            def bump(step):
                """跨行
                字符串"""
                return step + 1  # 注释
            ```
            ```bash
            #!/bin/sh
            echo $#
            total=$((1 + 2))   # 注释
            ```
            ```json
            {"hits": 31, "ok": true, "label": "x"}
            ```
            ```latex
            \frac{a}{b} + \alpha = 0 % 注释
            ```
            """#
        ),
    ]

    /// 库为空时写入演示数据。返回写入条数。
    @MainActor
    static func seedIfEmpty(_ app: AppState) -> Int {
        guard isRequested else { return 0 }
        guard app.summaries.isEmpty else { return 0 }

        var count = 0
        for seed in seeds {
            if let note = app.createNote(title: seed.title) {
                app.bodyDidChange(seed.body)
                app.flushPendingSave()
                if note.status != seed.status {
                    app.updateStatus(seed.status)
                }
                count += 1
            }
        }
        app.loadAll(selectFirst: true)
        seedJournals(app)
        app.loadAll(selectFirst: true)
        return count
    }

    /// 演示日记：前两天 + 今天，含承接段、未完成 / 已完成待办、以及一处可触发提及的概念标题。
    /// 只给截图取证用，不写模板文件（正文里的 `##` 模块标题直接生成）。
    @MainActor
    private static func seedJournals(_ app: AppState) {
        let today = JournalDate.today()
        let day1 = JournalDate.offset(today, by: -2)
        let day2 = JournalDate.offset(today, by: -1)
        let entries: [(date: String, body: String)] = [
            (day1, """
            ## 工作
            - [ ] 把日记接到界面上
            - [x] 补类型注册表
            ## 生活
            - [ ] 跑步 20 分钟
            """),
            (day2, """
            ## 承接（来自 \(JournalTodo.short(day1))）
            - [ ] 把日记接到界面上
            - [ ] 跑步 20 分钟

            ## 工作
            - [ ] 写批次 6 的测试
            - [ ] 把日记接到界面上
            ## 生活
            - [ ] 买咖啡豆
            """),
            (today, """
            ## 承接（来自 \(JournalTodo.short(day2))）
            - [ ] 写批次 6 的测试
            - [ ] 买咖啡豆

            ## 工作
            - [ ] 截图：日记列表、待办总览
            - [ ] 把日记接到界面上
            ## 生活
            - [ ] 跑步 20 分钟
            - [x] 早睡

            今天重读 稀疏重复优于集中突击 的论证，集中突击只能短期见效。
            """),
        ]
        for entry in entries {
            guard app.openJournal(on: entry.date, using: []) != nil else { continue }
            app.bodyDidChange(entry.body)
            app.flushPendingSave()
        }
    }
}
#endif
