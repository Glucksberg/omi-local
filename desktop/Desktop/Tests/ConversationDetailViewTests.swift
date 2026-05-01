import XCTest
@testable import Omi_Computer

final class ConversationDetailViewTests: XCTestCase {
    func testLocalTranscriptPollingOnlyRunsForActiveLocalConversations() {
        XCTAssertTrue(
            ConversationDetailView.shouldPollLocalTranscript(
                conversationId: "local_session_32",
                status: .inProgress
            )
        )
        XCTAssertTrue(
            ConversationDetailView.shouldPollLocalTranscript(
                conversationId: "local_session_32",
                status: .processing
            )
        )
        XCTAssertFalse(
            ConversationDetailView.shouldPollLocalTranscript(
                conversationId: "local_session_32",
                status: .completed
            )
        )
        XCTAssertFalse(
            ConversationDetailView.shouldPollLocalTranscript(
                conversationId: "server_conversation_32",
                status: .inProgress
            )
        )
    }

}
