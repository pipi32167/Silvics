import Foundation

/// 一次可撤销的修改操作（issue #35）。
///
/// 存前后两份正文而不是 record 一个 range：range 会随外部改正文而失效，
/// 失效后执行撤销就会删错位置。存全文的代价是每步一份副本，
/// 正文 100 KB、200 步上限，最坏 20 MB，对笔记应用可接受。
public struct EditorUndoStep: Equatable {
    public let before: String
    public let after: String
    /// 撤销后光标落在哪（UTF-16 偏移）。
    public let caretBefore: Int
    /// 重做后光标落在哪。
    public let caretAfter: Int
    /// 操作名。目前只用于调试与取证，不进菜单标题。
    public let name: String

    public init(before: String, after: String, caretBefore: Int, caretAfter: Int, name: String) {
        self.before = before
        self.after = after
        self.caretBefore = caretBefore
        self.caretAfter = caretAfter
        self.name = name
    }
}

/// 编辑器的前进/后退栈。
///
/// 为什么不用 `NSUndoManager`：它按「事件」自动分组，实测在真实的 App 事件循环里
/// 分组一直不关闭（`groupingLevel` 恒为 1），整场输入合成一步，⌘Z 一次清空整篇正文。
/// `breakUndoCoalescing()` 只断开「合并」，不断开分组，补不上这个坑。
/// 自己按操作记录前后快照，粒度、跨笔记隔离、外部替换后的安全性都可控。
///
/// 纯值类型，不碰 AppKit。
public struct EditorUndoStack {

    /// 最多保留多少步。超过丢最旧的一步。
    public var limit: Int = 200

    private var undoSteps: [EditorUndoStep] = []
    private var redoSteps: [EditorUndoStep] = []

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var undoCount: Int { undoSteps.count }
    public var redoCount: Int { redoSteps.count }
    public var undoName: String? { undoSteps.last?.name }
    public var redoName: String? { redoSteps.last?.name }

    /// 记一步。空操作（前后一样）不记。
    ///
    /// 记录新操作意味着「分叉」：重做栈作废，这是所有编辑器的通行做法。
    public mutating func record(_ step: EditorUndoStep) {
        guard step.before != step.after else { return }
        undoSteps.append(step)
        redoSteps.removeAll()
        if undoSteps.count > limit {
            undoSteps.removeFirst(undoSteps.count - limit)
        }
    }

    /// 取一步撤销：从撤销栈移到重做栈，交给调用方执行。
    public mutating func takeUndo() -> EditorUndoStep? {
        guard let step = undoSteps.popLast() else { return nil }
        redoSteps.append(step)
        return step
    }

    /// 取一步重做：从重做栈移回撤销栈。
    public mutating func takeRedo() -> EditorUndoStep? {
        guard let step = redoSteps.popLast() else { return nil }
        undoSteps.append(step)
        return step
    }

    /// 清空两个栈。外部整体替换正文后必须调（旧快照已不代表当前文档）。
    public mutating func removeAll() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }
}
