import XCTest
@testable import Omi_Computer

final class ConversationCandidateProcessorTests: XCTestCase {
    func testLowSignalAmbientDoesNotCreateDigestCandidate() async {
        let repeatedNoise = Array(repeating: "obrigado obrigado obrigado obrigado obrigado obrigado", count: 12)

        let preview = await ConversationCandidateProcessor.shared.candidatePreviewForTesting(texts: repeatedNoise)

        XCTAssertEqual(preview.candidateCount, 0)
    }

    func testUsefulAmbientCreatesPendingEvidenceCandidate() async {
        let texts = [
            "Eu gosto mais dos limites do ChatGPT porque isso encaixa melhor no meu fluxo de trabalho diario",
            "Estou construindo o omi local para manter dados sensiveis no laptop e evitar vendors desnecessarios",
            "Preciso testar a transcricao ambiente depois do build para confirmar que portugues e ingles funcionam bem",
            "Seria melhor manter esse processo simples com revisao antes de promover qualquer memoria canonica",
        ]

        let preview = await ConversationCandidateProcessor.shared.candidatePreviewForTesting(texts: texts)

        XCTAssertGreaterThan(preview.candidateCount, 0)
        XCTAssertFalse(preview.overview.isEmpty)
    }
}
