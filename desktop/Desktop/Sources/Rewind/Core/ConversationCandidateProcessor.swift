import Foundation
import GRDB

actor ConversationCandidateProcessor {
    static let shared = ConversationCandidateProcessor()

    private init() {}

    func processRecentCompletedSessions(limit: Int = 25) async {
        guard LocalMode.isEnabled else { return }

        do {
            try await RewindDatabase.shared.initialize()
            guard let db = await RewindDatabase.shared.getDatabaseQueue() else { return }

            let sessionIds = try await db.read { database in
                try Int64.fetchAll(
                    database,
                    sql: """
                        SELECT s.id
                        FROM transcription_sessions s
                        LEFT JOIN conversation_candidates c ON c.sessionId = s.id
                        WHERE s.status = 'completed'
                          AND s.deleted = 0
                          AND s.discarded = 0
                          AND s.backendId LIKE 'local_session_%'
                          AND s.startedAt >= datetime('now', '-3 days')
                          AND c.id IS NULL
                        ORDER BY s.startedAt DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
            }

            guard !sessionIds.isEmpty else { return }
            log("ConversationCandidateProcessor: backfilling \(sessionIds.count) completed local session(s)")
            for sessionId in sessionIds {
                try await processCompletedSession(id: sessionId)
            }
        } catch {
            logError("ConversationCandidateProcessor: failed to backfill completed sessions", error: error)
        }
    }

    func processCompletedSession(id sessionId: Int64) async throws {
        guard LocalMode.isEnabled else { return }

        try await RewindDatabase.shared.initialize()
        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        let payload = try await db.read { database -> ProcessingPayload? in
            guard let session = try TranscriptionSessionRecord.fetchOne(database, key: sessionId) else {
                return nil
            }

            let existing = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM conversation_candidates WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
            guard existing == 0 else { return nil }

            let segments = try TranscriptionSegmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("segmentOrder").asc)
                .fetchAll(database)

            return ProcessingPayload(session: session, segments: segments)
        }

        guard let payload else {
            log("ConversationCandidateProcessor: session \(sessionId) already processed or missing")
            return
        }

        let result = buildResult(session: payload.session, segments: payload.segments)
        guard !result.candidates.isEmpty else {
            log("ConversationCandidateProcessor: no useful candidates for session \(sessionId)")
            return
        }

        try await db.write { database in
            if var session = try TranscriptionSessionRecord.fetchOne(database, key: sessionId) {
                if session.title?.isEmpty ?? true || session.title == "Local Conversation" {
                    session.title = result.title
                }
                if session.overview?.isEmpty ?? true {
                    session.overview = result.overview
                }
                if session.emoji?.isEmpty ?? true {
                    session.emoji = result.emoji
                }
                if session.category?.isEmpty ?? true {
                    session.category = result.category
                }
                session.updatedAt = Date()
                try session.update(database)
            }

            for candidate in result.candidates {
                try Self.insertCandidate(candidate, into: database)
            }
        }

        log(
            "ConversationCandidateProcessor: created \(result.candidates.count) candidate(s) for session \(sessionId)"
        )
    }

    private func buildResult(
        session: TranscriptionSessionRecord,
        segments: [TranscriptionSegmentRecord]
    ) -> ProcessingResult {
        let conversationId = session.backendId ?? "local_session_\(session.id ?? 0)"
        let sentences = makeSentences(from: segments)
        let salient = sentences.filter { isSalient($0.text) }
        let useful = salient.isEmpty ? sentences : salient
        let usefulWordCount = useful.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard useful.count >= 4, usefulWordCount >= 60 else {
            return ProcessingResult(
                title: session.title ?? "Local Conversation",
                overview: session.overview ?? "",
                emoji: session.emoji ?? "",
                category: session.category ?? "other",
                candidates: []
            )
        }
        let keywords = topKeywords(from: useful.map(\.text))
        let title = makeTitle(from: keywords, fallback: useful.first?.text)
        let overview = makeOverview(from: useful)
        let category = makeCategory(from: keywords, text: useful.map(\.text).joined(separator: " "))
        let emoji = makeEmoji(category: category)
        var candidates: [ConversationCandidateRecord] = []

        if !overview.isEmpty {
            candidates.append(
                makeCandidate(
                    session: session,
                    conversationId: conversationId,
                    type: .digest,
                    content: overview,
                    reasoning: "Local digest extracted from completed ambient transcription.",
                    confidence: useful.count >= 6 ? 0.58 : 0.52,
                    segmentIds: Array(useful.prefix(8).map(\.segmentId))
                )
            )
        }

        candidates.append(contentsOf: extractActions(session: session, conversationId: conversationId, sentences: useful))
        candidates.append(contentsOf: extractMemories(session: session, conversationId: conversationId, sentences: useful))
        candidates.append(contentsOf: extractAdvice(session: session, conversationId: conversationId, sentences: useful))

        return ProcessingResult(
            title: title,
            overview: overview.isEmpty ? "Ambient transcription captured with low signal." : overview,
            emoji: emoji,
            category: category,
            candidates: Array(candidates.prefix(16))
        )
    }

    private func makeSentences(from segments: [TranscriptionSegmentRecord]) -> [CandidateSentence] {
        segments.compactMap { segment in
            let text = normalizeText(segment.text)
            guard !text.isEmpty else { return nil }
            return CandidateSentence(
                segmentId: segment.id ?? Int64(segment.segmentOrder),
                text: text,
                order: segment.segmentOrder
            )
        }
    }

    private func extractActions(
        session: TranscriptionSessionRecord,
        conversationId: String,
        sentences: [CandidateSentence]
    ) -> [ConversationCandidateRecord] {
        let patterns = [
            "preciso comprar", "preciso pagar", "preciso enviar", "preciso ligar",
            "preciso marcar", "preciso instalar", "preciso corrigir", "preciso testar",
            "preciso commitar", "preciso fazer commit", "preciso fazer push",
            "tenho que comprar", "tenho que pagar", "tenho que enviar", "tenho que ligar",
            "tenho que marcar", "tenho que instalar", "tenho que corrigir", "tenho que testar",
            "não posso esquecer de comprar", "não posso esquecer de pagar",
            "i need to buy", "i need to pay", "i need to send", "i need to call",
            "i need to fix", "i need to test", "i need to commit", "i need to push",
            "remind me to",
        ]

        return sentences
            .filter { containsAny($0.text, patterns) && !isUnreliableCandidate($0.text) }
            .prefix(5)
            .map {
                makeCandidate(
                    session: session,
                    conversationId: conversationId,
                    type: .action,
                    content: $0.text,
                    reasoning: "Sentence contains an explicit task or commitment marker.",
                    confidence: 0.66,
                    segmentIds: [$0.segmentId]
                )
            }
    }

    private func extractMemories(
        session: TranscriptionSessionRecord,
        conversationId: String,
        sentences: [CandidateSentence]
    ) -> [ConversationCandidateRecord] {
        let patterns = [
            "eu gosto ", "eu prefiro ", "meu nome ", "minha empresa ",
            "meu projeto ", "estou construindo ", "trabalho com ", "moro em ",
            "i like ", "i prefer ", "my name ", "my company ", "my project ",
            "i work with ", "i live in ",
        ]

        return sentences
            .filter {
                containsAny($0.text, patterns)
                    && $0.text.split(separator: " ").count >= 6
                    && !isUnreliableCandidate($0.text)
            }
            .prefix(5)
            .map {
                makeCandidate(
                    session: session,
                    conversationId: conversationId,
                    type: .memory,
                    content: $0.text,
                    reasoning: "First-person durable fact or preference marker detected; pending review before canonical memory.",
                    confidence: 0.61,
                    segmentIds: [$0.segmentId]
                )
            }
    }

    private func extractAdvice(
        session: TranscriptionSessionRecord,
        conversationId: String,
        sentences: [CandidateSentence]
    ) -> [ConversationCandidateRecord] {
        let patterns = [
            "deveria ", "seria melhor ", "vale a pena ", "acho que precisamos ",
            "precisamos melhorar ", "precisamos otimizar ", "precisamos evitar ",
            "would be better ", "worth considering ", "we should improve ",
            "we should optimize ", "we should avoid ",
        ]

        return sentences
            .filter {
                containsAny($0.text, patterns)
                    && $0.text.split(separator: " ").count >= 8
                    && !isUnreliableCandidate($0.text)
            }
            .prefix(5)
            .map {
                makeCandidate(
                    session: session,
                    conversationId: conversationId,
                    type: .advice,
                    content: $0.text,
                    reasoning: "Sentence contains a possible improvement, concern, or recommendation marker.",
                    confidence: 0.58,
                    segmentIds: [$0.segmentId]
                )
            }
    }

    private func makeCandidate(
        session: TranscriptionSessionRecord,
        conversationId: String,
        type: ConversationCandidateType,
        content: String,
        reasoning: String,
        confidence: Double,
        segmentIds: [Int64]
    ) -> ConversationCandidateRecord {
        let sessionId = session.id ?? 0
        let normalized = normalizeText(content)
        let sourceSegmentIdsJson = try? String(data: JSONEncoder().encode(segmentIds), encoding: .utf8)
        let hash = stableHash("\(sessionId)|\(type.rawValue)|\(normalized.lowercased())")

        return ConversationCandidateRecord(
            sessionId: sessionId,
            conversationId: conversationId,
            candidateType: type,
            content: normalized,
            reasoning: reasoning,
            confidence: confidence,
            sourceSegmentIdsJson: sourceSegmentIdsJson,
            contentHash: hash
        )
    }

    private func makeOverview(from sentences: [CandidateSentence]) -> String {
        let selected = sentences.prefix(4).map(\.text)
        guard !selected.isEmpty else { return "" }
        let joined = selected.joined(separator: " ")
        return truncate(joined, max: 700)
    }

    private func makeTitle(from keywords: [String], fallback: String?) -> String {
        if !keywords.isEmpty {
            return "Sobre \(keywords.prefix(3).joined(separator: ", "))"
        }
        if let fallback {
            return truncate(fallback, max: 70)
        }
        return "Ambient transcription"
    }

    private func makeCategory(from keywords: [String], text: String) -> String {
        let lower = text.lowercased()
        if containsAny(lower, ["codigo", "código", "repo", "github", "app", "software", "swift", "python", "api"]) {
            return "work"
        }
        if containsAny(lower, ["comprar", "buy", "pagamento", "dinheiro", "money", "credit"]) {
            return "finance"
        }
        if containsAny(lower, ["saúde", "health", "médico", "doctor", "sono", "sleep"]) {
            return "health"
        }
        if containsAny(lower, ["família", "family", "amigo", "friend"]) {
            return "personal"
        }
        return keywords.isEmpty ? "other" : "conversation"
    }

    private func makeEmoji(category: String) -> String {
        switch category {
        case "work": return "💻"
        case "finance": return "💳"
        case "health": return "🩺"
        case "personal": return "👤"
        default: return "🗣️"
        }
    }

    private func isSalient(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count >= 4 else { return false }
        guard !isUnreliableCandidate(text) else { return false }
        let lower = text.lowercased()
        let lowSignal = [
            "obrigado", "obrigada", "thank you", "thanks", "tchau", "bye", "hum", "uh",
            "aham", "ok", "okay", "beleza",
        ]
        return !lowSignal.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    private func topKeywords(from texts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        let stopwords = Self.stopwords
        for text in texts {
            let words = text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 && !stopwords.contains($0) }
            for word in Set(words) {
                counts[word, default: 0] += 1
            }
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(5)
            .map(\.key)
    }

    private func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        let lower = text.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    private func normalizeText(_ text: String) -> String {
        var normalized = text
        normalized = normalized.replacingOccurrences(
            of: #"\[[^\]]+\]"#,
            with: " ",
            options: .regularExpression
        )
        return normalized
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)) + "…"
    }

    private func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func isUnreliableCandidate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let blocked = [
            "barulho", "som do computador", "música", "musica", "teclado", "porta",
            "caralho", "porra", "puta", "fuck", "shit",
            "você vai", "voce vai", "ele vai", "ela vai", "eles vão", "elas vão",
            "you will", "he will", "she will", "they will",
        ]
        if blocked.contains(where: { lower.contains($0) }) {
            return true
        }

        let words = lower.split(separator: " ").map(String.init)
        guard words.count >= 6 else { return true }
        let uniqueRatio = Double(Set(words).count) / Double(words.count)
        return uniqueRatio < 0.45
    }

    private static func insertCandidate(_ candidate: ConversationCandidateRecord, into db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO conversation_candidates (
                    sessionId, conversationId, candidateType, status, content, reasoning,
                    confidence, sourceSegmentIdsJson, contentHash, promotedTo, promotedAt,
                    createdAt, updatedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                candidate.sessionId,
                candidate.conversationId,
                candidate.candidateType.rawValue,
                candidate.status.rawValue,
                candidate.content,
                candidate.reasoning,
                candidate.confidence,
                candidate.sourceSegmentIdsJson,
                candidate.contentHash,
                candidate.promotedTo,
                candidate.promotedAt,
                candidate.createdAt,
                candidate.updatedAt,
            ]
        )
    }

    private struct ProcessingPayload {
        let session: TranscriptionSessionRecord
        let segments: [TranscriptionSegmentRecord]
    }

    private struct ProcessingResult {
        let title: String
        let overview: String
        let emoji: String
        let category: String
        let candidates: [ConversationCandidateRecord]
    }

    private struct CandidateSentence {
        let segmentId: Int64
        let text: String
        let order: Int
    }

    private static let stopwords: Set<String> = [
        "sobre", "porque", "quando", "entao", "então", "aqui", "isso", "essa", "esse",
        "para", "como", "mais", "muito", "voce", "você", "gente", "coisa", "coisas",
        "agora", "tambem", "também", "fazer", "falando", "acho", "tipo", "porta",
        "abrindo", "barulho", "computador", "está", "esta", "quer", "eles", "elas",
        "assim", "cara", "deus", "tudo", "dentro", "olha", "famosos", "there",
        "this", "that", "with", "from", "have", "will", "would", "should", "about",
        "because", "when", "what", "your", "just", "like", "really", "going",
    ]
}
