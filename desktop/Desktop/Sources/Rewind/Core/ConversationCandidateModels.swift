import Foundation
import GRDB

enum ConversationCandidateType: String, Codable, CaseIterable {
    case memory
    case action
    case advice
    case digest
}

enum ConversationCandidateStatus: String, Codable, CaseIterable {
    case pending
    case promoted
    case rejected
    case dismissed
}

/// Local candidate extracted from an ambient transcription.
///
/// Candidates are intentionally not canonical memory. They are a review queue
/// for heartbeat, chat, and future UI promotion.
struct ConversationCandidateRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var sessionId: Int64
    var conversationId: String
    var candidateType: ConversationCandidateType
    var status: ConversationCandidateStatus
    var content: String
    var reasoning: String?
    var confidence: Double
    var sourceSegmentIdsJson: String?
    var contentHash: String
    var promotedTo: String?
    var promotedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "conversation_candidates"

    init(
        id: Int64? = nil,
        sessionId: Int64,
        conversationId: String,
        candidateType: ConversationCandidateType,
        status: ConversationCandidateStatus = .pending,
        content: String,
        reasoning: String? = nil,
        confidence: Double,
        sourceSegmentIdsJson: String? = nil,
        contentHash: String,
        promotedTo: String? = nil,
        promotedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.candidateType = candidateType
        self.status = status
        self.content = content
        self.reasoning = reasoning
        self.confidence = confidence
        self.sourceSegmentIdsJson = sourceSegmentIdsJson
        self.contentHash = contentHash
        self.promotedTo = promotedTo
        self.promotedAt = promotedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ConversationCandidateRecord: TableDocumented {
    static var tableDescription: String { ChatPrompts.tableAnnotations["conversation_candidates"]! }
    static var columnDescriptions: [String: String] {
        ChatPrompts.columnAnnotations["conversation_candidates"] ?? [:]
    }
}
