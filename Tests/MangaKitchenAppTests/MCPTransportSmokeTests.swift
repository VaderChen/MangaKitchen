import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import MangaKitchenApp

final class MCPTransportSmokeTests: XCTestCase {
    func testChunkedRequestIsRejectedBeforeOverflowIsForwarded() throws {
        let channel = EmbeddedChannel(handler: MCPRequestBodyLimitHandler(maximumBytes: 4))
        defer { _ = try? channel.finish() }
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "1234")))
        _ = try channel.readInbound(as: HTTPServerRequestPart.self)
        _ = try channel.readInbound(as: HTTPServerRequestPart.self)
        try channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "5")))
        XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self))
        guard case let .head(response) = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            return XCTFail("應回覆 HTTP 413")
        }
        XCTAssertEqual(response.status, .payloadTooLarge)
    }

    func testOversizedContentLengthIsRejectedImmediately() throws {
        let channel = EmbeddedChannel(handler: MCPRequestBodyLimitHandler(maximumBytes: 4))
        defer { _ = try? channel.finish() }
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Content-Length", value: "5")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self))
        guard case let .head(response) = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            return XCTFail("應立即回覆 HTTP 413")
        }
        XCTAssertEqual(response.status.code, 413)
    }

    func testBudgetResetsForNextKeepAliveRequest() throws {
        let channel = EmbeddedChannel(handler: MCPRequestBodyLimitHandler(maximumBytes: 4))
        defer { _ = try? channel.finish() }
        for _ in 0..<2 {
            try channel.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .POST, uri: "/mcp")))
            try channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "1234")))
            try channel.writeInbound(HTTPServerRequestPart.end(nil))
            for _ in 0..<3 { XCTAssertNotNil(try channel.readInbound(as: HTTPServerRequestPart.self)) }
        }
        XCTAssertNil(try channel.readOutbound(as: HTTPServerResponsePart.self))
    }

    func testExistingAllowlistSemanticsRemainUnchanged() throws {
        let clients = try MCPClientAllowlist(entries: ["127.0.0.1", "10.20.0.0/16", "2001:db8::/32"])
        XCTAssertTrue(clients.allows("127.0.0.1"))
        XCTAssertTrue(clients.allows("10.20.3.4"))
        XCTAssertTrue(clients.allows("2001:db8::1"))
        XCTAssertFalse(clients.allows("10.21.3.4"))
        XCTAssertFalse(clients.allows(nil))
        XCTAssertFalse(try MCPClientAllowlist(entries: []).allows("127.0.0.1"))
        XCTAssertThrowsError(try MCPClientAllowlist(entries: ["127.0.0.1/33"]))
    }
}
