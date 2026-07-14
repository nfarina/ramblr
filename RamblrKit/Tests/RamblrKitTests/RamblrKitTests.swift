import XCTest
@testable import RamblrKit

final class RamblrKitTests: XCTestCase {

    func testModelIdentifierRoundTrip() {
        let groq = TranscriptionModel(identifier: "groq:whisper-large-v3")
        XCTAssertEqual(groq.provider, .groq)
        XCTAssertEqual(groq.modelName, "whisper-large-v3")
        XCTAssertEqual(groq.identifier, "groq:whisper-large-v3")
        XCTAssertEqual(groq.displayName, "Whisper (Groq)")
    }

    func testModelParsingFallsBackToOpenAIWhisper() {
        // Legacy bare value and unknown provider both fall back.
        XCTAssertEqual(TranscriptionModel(identifier: "whisper-1").identifier, "openai:whisper-1")
        XCTAssertEqual(TranscriptionModel(identifier: "bogus:thing").identifier, "openai:whisper-1")
    }

    func testProviderBaseURLs() {
        XCTAssertEqual(TranscriptionModel.Provider.groq.baseURL.absoluteString, "https://api.groq.com/openai")
        XCTAssertEqual(TranscriptionModel.Provider.openai.baseURL.absoluteString, "https://api.openai.com")
    }

    func testMimeTypeMapping() {
        XCTAssertEqual(TranscriptionService.mimeType(for: "WAV"), "audio/wav")
        XCTAssertEqual(TranscriptionService.mimeType(for: "m4a"), "audio/mp4")
        XCTAssertEqual(TranscriptionService.mimeType(for: "xyz"), "application/octet-stream")
    }

    func testMultipartBodyContainsFields() {
        let body = TranscriptionService.multipartBody(
            boundary: "BOUND",
            audioData: Data([0x01, 0x02, 0x03]),
            filename: "recording.wav",
            mimeType: "audio/wav",
            model: "whisper-large-v3",
            prompt: "AcmeCloud, NexaDB"
        )
        let string = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(string.contains("--BOUND\r\n"))
        XCTAssertTrue(string.contains("filename=\"recording.wav\""))
        XCTAssertTrue(string.contains("name=\"model\""))
        XCTAssertTrue(string.contains("whisper-large-v3"))
        XCTAssertTrue(string.contains("name=\"prompt\""))
        XCTAssertTrue(string.contains("AcmeCloud, NexaDB"))
        XCTAssertTrue(string.contains("name=\"temperature\""))
        XCTAssertTrue(string.contains("--BOUND--\r\n"))
    }

    func testMultipartBodyOmitsEmptyPrompt() {
        let body = TranscriptionService.multipartBody(
            boundary: "BOUND",
            audioData: Data(),
            filename: "recording.wav",
            mimeType: "audio/wav",
            model: "whisper-1",
            prompt: "  \n"
        )
        let string = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(string.contains("name=\"prompt\""))
    }

    func testErrorRetriability() {
        XCTAssertTrue(TranscriptionError.timeout.isRetriable)
        XCTAssertTrue(TranscriptionError.apiError(429, "rate").isRetriable)
        XCTAssertTrue(TranscriptionError.apiError(503, "down").isRetriable)
        XCTAssertFalse(TranscriptionError.apiError(400, "invalid audio").isRetriable)
        XCTAssertFalse(TranscriptionError.apiError(401, "auth").isRetriable)
        XCTAssertFalse(TranscriptionError.noAPIKey.isRetriable)
    }
}
