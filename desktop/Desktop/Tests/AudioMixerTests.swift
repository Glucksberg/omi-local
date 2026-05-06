import XCTest

@testable import Omi_Computer

final class AudioMixerTests: XCTestCase {
  private func audioChunk(value: Int16 = 1000, byteCount: Int = 3200) -> Data {
    let sampleCount = byteCount / 2
    var samples = [Int16](repeating: value, count: sampleCount)
    return samples.withUnsafeMutableBufferPointer { Data(buffer: $0) }
  }

  func testMonoMixerEmitsMicrophoneOnlyAudioWhenSystemAudioIsIdle() {
    let mixer = AudioMixer()
    var chunks: [Data] = []
    mixer.start { chunks.append($0) }

    let micOnly = audioChunk(value: 100)
    mixer.setMicAudio(micOnly)

    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.count, micOnly.count)

    let samples = chunks[0].withUnsafeBytes { $0.bindMemory(to: Int16.self) }
    XCTAssertEqual(samples[0], 100)
  }

  func testMonoMixerEmitsSystemOnlyAudioWhenMicrophoneIsIdle() {
    let mixer = AudioMixer()
    var chunks: [Data] = []
    mixer.start { chunks.append($0) }

    let systemOnly = audioChunk(value: 200)
    mixer.setSystemAudio(systemOnly)

    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.count, systemOnly.count)

    let samples = chunks[0].withUnsafeBytes { $0.bindMemory(to: Int16.self) }
    XCTAssertEqual(samples[0], 200)
  }

  func testMonoMixerSumsOverlappingBufferedAudio() {
    let mixer = AudioMixer(outputMode: .mono)
    var chunks: [Data] = []
    mixer.start { chunks.append($0) }

    mixer.setMicAudio(audioChunk(value: 100, byteCount: 1600))
    XCTAssertEqual(chunks.count, 0)

    mixer.setSystemAudio(audioChunk(value: 200))
    XCTAssertEqual(chunks.count, 1)

    let samples = chunks[0].withUnsafeBytes { $0.bindMemory(to: Int16.self) }
    XCTAssertEqual(samples[0], 300)
  }

  func testStereoMixerInterleavesOverlappingBufferedAudio() {
    let mixer = AudioMixer(outputMode: .stereo)
    var chunks: [Data] = []
    mixer.start { chunks.append($0) }

    mixer.setMicAudio(audioChunk(value: 100, byteCount: 1600))
    XCTAssertEqual(chunks.count, 0)

    mixer.setSystemAudio(audioChunk(value: 200))
    XCTAssertEqual(chunks.count, 1)

    let samples = chunks[0].withUnsafeBytes { $0.bindMemory(to: Int16.self) }
    XCTAssertEqual(samples[0], 100)
    XCTAssertEqual(samples[1], 200)
  }

  func testStopFlushesRemainingAudio() {
    let mixer = AudioMixer(outputMode: .mono)
    var chunks: [Data] = []
    mixer.start { chunks.append($0) }

    mixer.setMicAudio(audioChunk(value: 100, byteCount: 1000))
    mixer.setSystemAudio(audioChunk(value: 200, byteCount: 1000))
    XCTAssertEqual(chunks.count, 0)

    mixer.stop()
    XCTAssertEqual(chunks.count, 1)

    let samples = chunks[0].withUnsafeBytes { $0.bindMemory(to: Int16.self) }
    XCTAssertEqual(samples[0], 300)
  }
}
