import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// 將官方 framework-agnostic StatefulHTTPServerTransport 接到 NIO listener。
actor MangaKitchenMCPHTTPHost {
    struct Configuration: Sendable {
        var host: String = "0.0.0.0"
        var advertisedHost: String = "127.0.0.1"
        var port: Int = 12_080
        var allowedClients: [String] = ["127.0.0.1"]
        var endpoint: String = "/mcp"
        var sessionTimeout: TimeInterval = 3_600
        var maximumRequestBytes: Int = 32 * 1_024 * 1_024

        var endpointURL: URL {
            URL(string: "http://\(advertisedHost):\(port)\(endpoint)")!
        }
    }

    private struct SessionContext {
        var server: Server
        var transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        var sessionID: String

        func generateSessionID() -> String { sessionID }
    }

    private let configuration: Configuration
    private let clientAllowlist: MCPClientAllowlist
    private let service: MCPWorkflowService
    private var channel: (any Channel)?
    private var sessions: [String: SessionContext] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(configuration: Configuration, service: MCPWorkflowService) throws {
        self.configuration = configuration
        clientAllowlist = try MCPClientAllowlist(entries: configuration.allowedClients)
        self.service = service
    }

    var endpointURL: URL { configuration.endpointURL }

    /// 啟動後會持續等待 listener 關閉；onReady 於 bind 成功後呼叫。
    func run(onReady: @escaping @Sendable (URL) -> Void) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(MCPHTTPHandler(host: self))
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

            let channel = try await bootstrap.bind(
                host: configuration.host,
                port: configuration.port
            ).get()
            self.channel = channel
            cleanupTask = Task { [weak self] in
                await self?.sessionCleanupLoop()
            }
            onReady(configuration.endpointURL)
            try await channel.closeFuture.get()
            cleanupTask?.cancel()
            cleanupTask = nil
            await closeAllSessions()
            try await group.shutdownGracefully()
        } catch {
            cleanupTask?.cancel()
            cleanupTask = nil
            await closeAllSessions()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
    }

    func handle(_ request: HTTPRequest, remoteAddress: String?) async -> HTTPResponse {
        guard clientAllowlist.allows(remoteAddress) else {
            return .error(statusCode: 403, .invalidRequest("Client address is not allowed"))
        }
        guard request.path == configuration.endpoint else {
            return .error(statusCode: 404, .invalidRequest("Not Found"))
        }
        if let body = request.body, body.count > configuration.maximumRequestBytes {
            return .error(statusCode: 413, .invalidRequest("Request body is too large"))
        }

        let sessionID = request.header(HTTPHeaderName.sessionID)
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID)
        )
        let server = await MangaKitchenMCPServer.makeServer(service: service)
        do {
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                lastAccessedAt: Date()
            )
            let response = await transport.handleRequest(request)
            if case .error = response {
                await closeSession(sessionID)
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create MCP session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.server.stop()
    }

    private func closeAllSessions() async {
        for sessionID in Array(sessions.keys) {
            await closeSession(sessionID)
        }
    }

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            let expiry = Date().addingTimeInterval(-configuration.sessionTimeout)
            let expired = sessions.compactMap { key, session in
                session.lastAccessedAt < expiry ? key : nil
            }
            for sessionID in expired {
                await closeSession(sessionID)
            }
        }
    }

    private static func isInitializeRequest(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "initialize"
    }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private let host: MangaKitchenMCPHTTPHost
    private var requestState: RequestState?

    init(host: MangaKitchenMCPHTTPHost) {
        self.host = host
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            nonisolated(unsafe) let context = context
            Task { @MainActor in
                await self.process(state: state, context: context)
            }
        }
    }

    private func process(state: RequestState, context: ChannelHandlerContext) async {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(
               at: state.bodyBuffer.readerIndex,
               length: state.bodyBuffer.readableBytes
           ) {
            body = Data(bytes)
        } else {
            body = nil
        }
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        let request = HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
        let response = await host.handle(
            request,
            remoteAddress: context.channel.remoteAddress?.ipAddress
        )
        await write(response, version: state.head.version, context: context)
    }

    private func write(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let context = context
        let eventLoop = context.eventLoop

        switch response {
        case let .stream(stream, headers):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                context.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = context.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        context.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                            promise: nil
                        )
                    }
                }
            } catch {
                // Transport 關閉時由下方統一結束 HTTP response。
            }
            eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let body = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                if !head.headers.contains(name: "Content-Length") {
                    head.headers.add(name: "Content-Length", value: String(body?.count ?? 0))
                }
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body {
                    var buffer = context.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
