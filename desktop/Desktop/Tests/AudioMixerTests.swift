import XCTest
@testable import Omi_Computer

final class AudioMixerTests: XCTestCase {
    func testMonoMixerEmitsMicrophoneOnlyAudioWhenSystemAudioIsIdle() {
        let mixer = AudioMixer()
        var chunks: [Data] = []
        mixer.start { chunks.append($0) }

        let micOnly = Data(repeating: 1, count: 3_200)
        mixer.setMicAudio(micOnly)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, micOnly.count)
    }

    func testMonoMixerEmitsSystemOnlyAudioWhenMicrophoneIsIdle() {
        let mixer = AudioMixer()
        var chunks: [Data] = []
        mixer.start { chunks.append($0) }

        let systemOnly = Data(repeating: 1, count: 3_200)
        mixer.setSystemAudio(systemOnly)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, systemOnly.count)
    }
}
