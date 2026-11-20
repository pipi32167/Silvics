import Foundation
import GRDB

/// 数据库句柄与迁移。
final class AppDatabase {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    var reader: any DatabaseReader { writer }

    // MARK: - 位置

    /// `~/Library/Application Support/Silvics/silvics.sqlite`
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Silvics", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeOnDisk() throws -> AppDatabase {
        let url = try defaultDirectory().appendingPathComponent("silvics.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try AppDatabase(queue)
    }

    static func makeInMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try AppDatabase(queue)
    }

    // MARK: - 迁移

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            // 笔记本体。正文 = 唯一真相。
            try db.execute(sql: """
                CREATE TABLE note (
                  id        TEXT PRIMARY KEY,
                  title     TEXT NOT NULL,
                  titleKey  TEXT NOT NULL,
                  body      TEXT NOT NULL,
                  status    TEXT NOT NULL DEFAULT 'seedling',
                  createdAt INTEGER NOT NULL,
                  updatedAt INTEGER NOT NULL,
                  bodyHash  TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX idx_note_titleKey ON note(titleKey)")
            try db.execute(sql: "CREATE INDEX idx_note_updatedAt ON note(updatedAt DESC)")

            // 别名。P2 使用，P1 建表占位。
            try db.execute(sql: """
                CREATE TABLE alias (
                  noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  name   TEXT NOT NULL,
                  nameKey TEXT NOT NULL,
                  PRIMARY KEY (noteId, name)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_alias_nameKey ON alias(nameKey)")

            // 标签。
            try db.execute(sql: """
                CREATE TABLE tag (
                  noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  name   TEXT NOT NULL,
                  PRIMARY KEY (noteId, name)
                )
                """)

            // 引用边。索引，可从正文全量重建。
            try db.execute(sql: """
                CREATE TABLE link (
                  id          INTEGER PRIMARY KEY AUTOINCREMENT,
                  fromId      TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  toId        TEXT REFERENCES note(id) ON DELETE SET NULL,
                  rawTarget   TEXT NOT NULL,
                  displayText TEXT NOT NULL,
                  anchor      TEXT,
                  location    INTEGER NOT NULL,
                  length      INTEGER NOT NULL,
                  status      TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_link_fromId ON link(fromId)")
            try db.execute(sql: "CREATE INDEX idx_link_toId ON link(toId)")

            // 未链接提及。P2 使用。
            try db.execute(sql: """
                CREATE TABLE mention (
                  id        INTEGER PRIMARY KEY AUTOINCREMENT,
                  noteId    TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  targetId  TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  location  INTEGER NOT NULL,
                  length    INTEGER NOT NULL,
                  kind      TEXT NOT NULL,
                  dismissed INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_mention_noteId ON mention(noteId)")

            // 全文搜索。trigram 分词器支持中文子串，已实测。
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                  title,
                  body,
                  tokenize='trigram'
                )
                """)

            // 元信息：上次重建索引时间等。
            try db.execute(sql: """
                CREATE TABLE meta (
                  key   TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                )
                """)
        }

        return m
    }
}
