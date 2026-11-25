import Foundation

/// 主窗口的三个内容模块。设置是独立窗口，不在这里。
enum AppModule: String, CaseIterable, Identifiable, Equatable {
    case notes
    case journal
    case clips

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "笔记"
        case .journal: return "日记"
        case .clips: return "剪藏"
        }
    }

    /// 模块图标用 emoji：免费、跨平台、不引第三方图标库。
    var icon: String {
        switch self {
        case .notes: return "📝"
        case .journal: return "📅"
        case .clips: return "🔖"
        }
    }
}

/// 概念笔记的范围。
enum NoteScope: Equatable, Hashable {
    case all
    case orphans
    case tag(String)

    var title: String {
        switch self {
        case .all: return "全部"
        case .orphans: return "孤儿笔记"
        case .tag(let name): return "#\(name)"
        }
    }
}

/// 日记的范围。
enum JournalScope: Equatable, Hashable {
    case today
    case all
    case todos
    case templates

    var title: String {
        switch self {
        case .today: return "今天"
        case .all: return "全部日记"
        case .todos: return "待办总览"
        case .templates: return "模板"
        }
    }
}

/// 剪藏的范围。
enum ClipScope: Equatable, Hashable {
    case unread
    case all
    case archived
    /// 正文已存但模型还没整理完（`aiState != done`）。
    case pending
    case tag(String)

    var title: String {
        switch self {
        case .unread: return "未读"
        case .all: return "全部"
        case .archived: return "已归档"
        case .pending: return "待整理"
        case .tag(let name): return "#\(name)"
        }
    }
}

/// 某个模块当前停在哪。三种范围不能互换，跨模块切换要走 `NavigationState.enter`。
enum ModuleScope: Equatable, Hashable {
    case note(NoteScope)
    case journal(JournalScope)
    case clip(ClipScope)

    var module: AppModule {
        switch self {
        case .note: return .notes
        case .journal: return .journal
        case .clip: return .clips
        }
    }

    var title: String {
        switch self {
        case .note(let scope): return scope.title
        case .journal(let scope): return scope.title
        case .clip(let scope): return scope.title
        }
    }
}

/// 一个模块记住的东西：范围、选中条目、搜索词。
struct ModuleMemory<Scope: Equatable>: Equatable {
    var scope: Scope
    var selection: String?
    var query: String = ""
}

/// 导航状态。纯值类型，不碰数据库，可以单测。
///
/// 每个模块各存一份记忆，切走不丢，切回还原。
struct NavigationState: Equatable {
    var active: AppModule = .notes
    var notes = ModuleMemory<NoteScope>(scope: .all)
    var journal = ModuleMemory<JournalScope>(scope: .today)
    var clips = ModuleMemory<ClipScope>(scope: .unread)

    // MARK: - 当前模块的读写口

    var selection: String? {
        switch active {
        case .notes: return notes.selection
        case .journal: return journal.selection
        case .clips: return clips.selection
        }
    }

    mutating func setSelection(_ id: String?) {
        switch active {
        case .notes: notes.selection = id
        case .journal: journal.selection = id
        case .clips: clips.selection = id
        }
    }

    var query: String {
        switch active {
        case .notes: return notes.query
        case .journal: return journal.query
        case .clips: return clips.query
        }
    }

    mutating func setQuery(_ text: String) {
        switch active {
        case .notes: notes.query = text
        case .journal: journal.query = text
        case .clips: clips.query = text
        }
    }

    var scope: ModuleScope {
        switch active {
        case .notes: return .note(notes.scope)
        case .journal: return .journal(journal.scope)
        case .clips: return .clip(clips.scope)
        }
    }

    /// 只改当前模块的范围。范围属于别的模块时直接忽略。
    mutating func setScope(_ scope: ModuleScope) {
        guard scope.module == active else { return }
        switch scope {
        case .note(let value): notes.scope = value
        case .journal(let value): journal.scope = value
        case .clip(let value): clips.scope = value
        }
    }

    // MARK: - 切模块

    /// 只切模块，记住的范围与选中都留着。
    mutating func enter(_ module: AppModule) {
        active = module
    }

    /// 切模块顺带指定范围。范围与模块不匹配时只切模块。
    mutating func enter(_ module: AppModule, scope: ModuleScope) {
        active = module
        guard scope.module == module else { return }
        setScope(scope)
    }

    // MARK: - 快捷读法

    var noteScope: NoteScope { notes.scope }
    var journalScope: JournalScope { journal.scope }
    var clipScope: ClipScope { clips.scope }
}
