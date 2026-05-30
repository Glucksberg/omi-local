import Foundation
import GRDB

actor LocalChatStore {
    static let shared = LocalChatStore()

    private init() {}

    func fetchSessions(appId: String?, starred: Bool?) async throws -> [ChatSession] {
        let db = try await database()
        return try await db.read { db in
            var sql = """
                SELECT id, title, preview, createdAt, updatedAt, appId, messageCount, starred
                FROM chat_sessions
                WHERE IFNULL(appId, '') = IFNULL(?, '')
            """
            var arguments: StatementArguments = [appId]
            if let starred {
                sql += " AND starred = ?"
                arguments += [starred]
            }
            sql += " ORDER BY updatedAt DESC"

            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.session(from:))
        }
    }

    func createSession(title: String?, appId: String?) async throws -> ChatSession {
        let db = try await database()
        let session = ChatSession(title: title ?? "New Chat", appId: appId)
        try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO chat_sessions
                      (id, title, preview, createdAt, updatedAt, appId, messageCount, starred)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id, session.title, session.preview, session.createdAt, session.updatedAt,
                    session.appId, session.messageCount, session.starred,
                ]
            )
        }
        return session
    }

    func updateSession(sessionId: String, title: String? = nil, starred: Bool? = nil) async throws -> ChatSession? {
        let db = try await database()
        return try await db.write { db in
            if let title {
                try db.execute(
                    sql: "UPDATE chat_sessions SET title = ?, updatedAt = ? WHERE id = ?",
                    arguments: [title, Date(), sessionId]
                )
            }
            if let starred {
                try db.execute(
                    sql: "UPDATE chat_sessions SET starred = ?, updatedAt = ? WHERE id = ?",
                    arguments: [starred, Date(), sessionId]
                )
            }
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, preview, createdAt, updatedAt, appId, messageCount, starred
                    FROM chat_sessions
                    WHERE id = ?
                """,
                arguments: [sessionId]
            ).map(Self.session(from:))
        }
    }

    func deleteSession(sessionId: String) async throws {
        let db = try await database()
        try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_messages WHERE sessionId = ?", arguments: [sessionId])
            try db.execute(sql: "DELETE FROM chat_sessions WHERE id = ?", arguments: [sessionId])
        }
    }

    func fetchMessages(appId: String?, sessionId: String?, limit: Int, offset: Int) async throws -> [ChatMessageDB] {
        let db = try await database()
        return try await db.read { db in
            var sql = """
                SELECT id, text, createdAt, sender, appId, sessionId, rating, reported
                FROM chat_messages
            """
            var clauses: [String] = []
            var arguments: StatementArguments = []
            if let sessionId {
                clauses.append("sessionId = ?")
                arguments += [sessionId]
            } else {
                clauses.append("sessionId IS NULL")
                clauses.append("IFNULL(appId, '') = IFNULL(?, '')")
                arguments += [appId]
            }
            sql += " WHERE " + clauses.joined(separator: " AND ")
            sql += " ORDER BY createdAt DESC LIMIT ? OFFSET ?"
            arguments += [limit, offset]

            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.message(from:)).reversed()
        }
    }

    func saveMessage(
        id: String? = nil,
        text: String,
        sender: String,
        appId: String?,
        sessionId: String?,
        metadata: String?
    ) async throws -> SaveMessageResponse {
        let db = try await database()
        let messageId = id ?? UUID().uuidString
        let createdAt = Date()
        try await db.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO chat_messages
                      (id, text, createdAt, sender, appId, sessionId, rating, reported, metadata)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, 0, ?)
                """,
                arguments: [messageId, text, createdAt, sender, appId, sessionId, metadata]
            )

            if let sessionId {
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                try db.execute(
                    sql: """
                        UPDATE chat_sessions
                        SET preview = ?,
                            updatedAt = ?,
                            messageCount = (SELECT COUNT(*) FROM chat_messages WHERE sessionId = ?)
                        WHERE id = ?
                    """,
                    arguments: [String(preview.prefix(160)), createdAt, sessionId, sessionId]
                )
            }
        }
        return SaveMessageResponse(id: messageId, createdAt: createdAt)
    }

    func deleteMessages(appId: String?) async throws -> MessageDeleteResponse {
        let db = try await database()
        let deleted = try await db.write { db in
            if let appId {
                try db.execute(sql: "DELETE FROM chat_messages WHERE IFNULL(appId, '') = IFNULL(?, '')", arguments: [appId])
            } else {
                try db.execute(sql: "DELETE FROM chat_messages")
            }
            return db.changesCount
        }
        return MessageDeleteResponse(status: "ok", deletedCount: deleted)
    }

    private func database() async throws -> DatabasePool {
        try await RewindDatabase.shared.initialize()
        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            throw LocalChatStoreError.databaseUnavailable
        }
        try await ensureSchema(db)
        return db
    }

    private func ensureSchema(_ db: DatabasePool) async throws {
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chat_sessions (
                  id TEXT PRIMARY KEY,
                  title TEXT NOT NULL,
                  preview TEXT,
                  createdAt DATETIME NOT NULL,
                  updatedAt DATETIME NOT NULL,
                  appId TEXT,
                  messageCount INTEGER NOT NULL DEFAULT 0,
                  starred BOOLEAN NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chat_messages (
                  id TEXT PRIMARY KEY,
                  text TEXT NOT NULL,
                  createdAt DATETIME NOT NULL,
                  sender TEXT NOT NULL,
                  appId TEXT,
                  sessionId TEXT,
                  rating INTEGER,
                  reported BOOLEAN NOT NULL DEFAULT 0,
                  metadata TEXT
                )
            """)
            try db.create(index: "idx_chat_sessions_app_updated", on: "chat_sessions", columns: ["appId", "updatedAt"], ifNotExists: true)
            try db.create(index: "idx_chat_messages_session_created", on: "chat_messages", columns: ["sessionId", "createdAt"], ifNotExists: true)
            try db.create(index: "idx_chat_messages_app_created", on: "chat_messages", columns: ["appId", "createdAt"], ifNotExists: true)
        }
    }

    private static func session(from row: Row) -> ChatSession {
        ChatSession(
            id: row["id"],
            title: row["title"],
            preview: row["preview"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            appId: row["appId"],
            messageCount: row["messageCount"],
            starred: row["starred"]
        )
    }

    private static func message(from row: Row) -> ChatMessageDB {
        ChatMessageDB(
            id: row["id"],
            text: row["text"],
            createdAt: row["createdAt"],
            sender: row["sender"],
            appId: row["appId"],
            sessionId: row["sessionId"],
            rating: row["rating"],
            reported: row["reported"]
        )
    }
}

enum LocalChatStoreError: LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        "Local chat database is not available"
    }
}
