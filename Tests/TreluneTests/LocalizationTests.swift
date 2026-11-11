import XCTest
@testable import Trelune

/// Run with TRELUNE_LANGUAGE=en to exercise the English lookup (Portuguese is the identity).
final class LocalizationTests: XCTestCase {
    func testEnglishLookup() throws {
        try XCTSkipIf(AppLanguage.isPortuguese, "Set TRELUNE_LANGUAGE=en")
        XCTAssertEqual(L("Seu espaço criativo."), "Your creative space.")
        XCTAssertEqual(L("Criar para YouTube"), "Create for YouTube")
        XCTAssertEqual(L("0 conectadas   ·   6 disponíveis"), "0 connected   ·   6 available")
        XCTAssertEqual(L("5 destinos prontos para publicação"), "5 destinations ready for publishing")
        XCTAssertEqual(L("Conteúdo próprio do usuário"), "Conteúdo próprio do usuário")
        XCTAssertEqual(L("Monitorar"), "Monitor")
        XCTAssertEqual(L("Enviar o vídeo para Alice? Você finalizará a publicação no TikTok."), "Send the video to Alice? You will finish posting in TikTok.")
        XCTAssertEqual(L("Publicar o vídeo em Alice com a visibilidade Público?"), "Post the video to Alice with Public visibility?")
    }
    func testPortugueseIsIdentity() throws {
        try XCTSkipIf(!AppLanguage.isPortuguese)
        XCTAssertEqual(L("Seu espaço criativo."), "Seu espaço criativo.")
    }
}
