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

    func testInlineTranscriptIsHiddenWhenDrawerIsVisible() {
        XCTAssertFalse(
            ConversationDetailView.shouldShowInlineTranscript(
                localMode: true,
                isLoading: false,
                hasOverview: false,
                hasSegments: true,
                isTranscriptDrawerVisible: true
            )
        )
        XCTAssertTrue(
            ConversationDetailView.shouldShowInlineTranscript(
                localMode: true,
                isLoading: false,
                hasOverview: false,
                hasSegments: true,
                isTranscriptDrawerVisible: false
            )
        )
    }
}
