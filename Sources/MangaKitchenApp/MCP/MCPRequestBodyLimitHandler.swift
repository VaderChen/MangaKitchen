import NIOCore
import NIOHTTP1

/// 在配置 body buffer 前套用既有大小上限，也適用 chunked request。
// 可跨執行緒安裝；所有可變狀態僅由所屬 channel 的 event loop 存取。
final class MCPRequestBodyLimitHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let maximumBytes: Int
    private var receivedBytes = 0
    private var rejected = false
    private var version = HTTPVersion.http1_1

    init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        switch unwrapInboundIn(data) {
        case let .head(head):
            receivedBytes = 0
            version = head.version
            if let length = head.headers.first(name: "Content-Length"),
               let count = Int(length), count > maximumBytes {
                reject(context)
                return
            }
        case let .body(buffer):
            guard buffer.readableBytes <= maximumBytes - receivedBytes else {
                reject(context)
                return
            }
            receivedBytes += buffer.readableBytes
        case .end:
            receivedBytes = 0
        }
        context.fireChannelRead(data)
    }

    private func reject(_ context: ChannelHandlerContext) {
        rejected = true
        var head = HTTPResponseHead(version: version, status: .payloadTooLarge)
        head.headers.add(name: "Content-Length", value: "0")
        head.headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let promise = context.eventLoop.makePromise(of: Void.self)
        let channel = context.channel
        promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
    }
}
