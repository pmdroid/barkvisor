import BarkVisorCore
import Foundation
import NIOCore
import Vapor

/// NIO channel handler: forwards socket bytes → WebSocket binary frames
final class SocketToWSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let ws: WebSocket

    init(ws: WebSocket) {
        self.ws = ws
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        ws.send(raw: buffer.readableBytesView, opcode: .binary, fin: true, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {}

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
