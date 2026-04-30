import XCTest
@testable import Omi_Computer

final class SpeakerSegmentIdentityTests: XCTestCase {
    func testSegmentsWithoutBackendIdsStillHaveUniqueSwiftUIIds() {
        let first = SpeakerSegment(
            speaker: 0,
            text: "Alo, testando um, dois, tres",
            start: 0,
            end: 10,
            isUser: true
        )
        let second = SpeakerSegment(
            speaker: 0,
            text: "Outra frase na proxima janela",
            start: 0,
            end: 10,
            isUser: true
        )

        XCTAssertNotEqual(first.id, second.id)
    }

    func testBackendSegmentIdRemainsPreferredIdentity() {
        let segment = SpeakerSegment(
            segmentId: "backend-segment-1",
            speaker: 0,
            text: "Alo",
            start: 0,
            end: 1
        )

        XCTAssertEqual(segment.id, "backend-segment-1")
    }
}
