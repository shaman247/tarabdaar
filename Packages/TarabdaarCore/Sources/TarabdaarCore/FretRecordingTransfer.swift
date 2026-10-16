import Foundation
import Compression

/// A completed fitting record travels in bounded, ordered TLP event chunks.
public struct FretRecordingChunk: Equatable, Sendable {
    public static let payloadBytes = 256
    public static let maxRecordBytes = 1024 * 1024
    public let session: UInt32
    public let record: UInt32
    public let index: UInt16
    public let count: UInt16
    public let bytes: [UInt8]

    public init(session: UInt32, record: UInt32, index: UInt16, count: UInt16, bytes: [UInt8]) {
        self.session = session
        self.record = record
        self.index = index
        self.count = count
        self.bytes = bytes
    }

    var isValid: Bool {
        session != 0 && record != 0 && count > 0
            && Int(count) <= (Self.maxRecordBytes + 1024 + Self.payloadBytes - 1) / Self.payloadBytes
            && index < count && !bytes.isEmpty && bytes.count <= Self.payloadBytes
            && (index == count - 1 || bytes.count == Self.payloadBytes)
    }
}

/// Link-queue-only pending records; performance frames are sent before each chunk.
final class FretRecordingOutbox {
    private var records: [(session: UInt32, id: UInt32, data: Data)] = []
    private var offset = 0
    private var queuedBytes = 0
    private var finishingSession: UInt32?

    func append(session: UInt32, data: Data) {
        guard session != 0, !data.isEmpty, data.count <= FretRecordingChunk.maxRecordBytes,
              queuedBytes + data.count <= 4 * FretRecordingChunk.maxRecordBytes else {
            NSLog("Tarabdaar: fret recording transfer exceeds its buffer limit")
            return
        }
        guard let encoded = FretRecordingCompression.encode(data) else { return }
        records.append((session, UInt32.random(in: 1...UInt32.max), encoded))
        queuedBytes += encoded.count
    }

    func finish(session: UInt32) { finishingSession = session }

    func next() -> TLPEvent? {
        guard let first = records.first else {
            guard let session = finishingSession else { return nil }
            finishingSession = nil
            return .fretRecording(session: session, recording: false)
        }
        let size = FretRecordingChunk.payloadBytes
        let end = min(offset + size, first.data.count)
        let chunk = FretRecordingChunk(session: first.session, record: first.id,
            index: UInt16(offset / size), count: UInt16((first.data.count + size - 1) / size),
            bytes: Array(first.data[offset..<end]))
        offset = end
        if offset == first.data.count {
            queuedBytes -= first.data.count
            records.removeFirst()
            offset = 0
        }
        return .fretRecordingChunk(chunk)
    }

    func reset() {
        records.removeAll()
        offset = 0
        queuedBytes = 0
        finishingSession = nil
    }
}

/// Main-thread reassembly rejects gaps, old sessions and repeated completed records.
public final class FretRecordingReceiver {
    private var session: UInt32 = 0
    private var record: UInt32?
    private var lastCompleted: UInt32?
    private var nextIndex: UInt16 = 0
    private var count: UInt16 = 0
    private var data = Data()

    public init() {}

    public func reset(session: UInt32) {
        self.session = session
        lastCompleted = nil
        clearPartial()
    }

    public func receive(_ chunk: FretRecordingChunk) -> Data? {
        guard chunk.session == session, chunk.isValid, chunk.record != lastCompleted else { return nil }
        if chunk.index == 0 {
            clearPartial()
            record = chunk.record
            count = chunk.count
        }
        guard record == chunk.record, count == chunk.count, chunk.index == nextIndex else {
            clearPartial()
            return nil
        }
        data.append(contentsOf: chunk.bytes)
        nextIndex += 1
        guard nextIndex == count else { return nil }
        let complete = data
        lastCompleted = record
        clearPartial()
        return FretRecordingCompression.decode(complete)
    }

    private func clearPartial() {
        record = nil
        nextIndex = 0
        count = 0
        data.removeAll(keepingCapacity: true)
    }
}

/// iPad capture is armed by the Mac; it never opens a file or owns a recording UI.
public final class FretRecordingPad {
    public let capture = FretGestureCapture()
    public private(set) var session: UInt32 = 0
    private var stoppedSession: UInt32 = 0
    public var onStroke: (UInt32, Data) -> Void = { _, _ in }
    public var onSessionChange: (UInt32, UInt32) -> Void = { _, _ in }

    public init() {
        capture.onStroke = { [weak self] data in
            guard let self, self.session != 0 else { return }
            self.onStroke(self.session, data)
        }
    }

    public func setSession(_ session: UInt32) {
        guard self.session != session else {
            if session == 0, stoppedSession != 0 { onSessionChange(stoppedSession, 0) }
            return
        }
        capture.setRecording(false)
        let previous = self.session
        self.session = session
        stoppedSession = session == 0 ? previous : 0
        onSessionChange(previous, session)
        capture.setRecording(session != 0)
    }

    public func stopSession(_ session: UInt32) {
        guard session != 0 else {
            let previous = self.session
            linkDropped()
            onSessionChange(previous, 0)
            return
        }
        guard self.session == 0 || self.session == session else { return }
        capture.setRecording(false)
        self.session = 0
        stoppedSession = session
        onSessionChange(session, 0)
    }

    public func linkDropped() {
        capture.setRecording(false)
        session = 0
        stoppedSession = 0
    }
}

private enum FretRecordingCompression {
    static func encode(_ data: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: data.count + 1024)
        let size = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, output.count,
                source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
        }
        guard size > 0 else { return nil }
        var header: [UInt8] = []
        header.appendLE(UInt32(data.count))
        return Data(header + output.prefix(size))
    }

    static func decode(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        let size = data.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard size > 0, size <= FretRecordingChunk.maxRecordBytes else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let decoded = data.dropFirst(4).withUnsafeBytes { source in
            compression_decode_buffer(&output, size,
                source.bindMemory(to: UInt8.self).baseAddress!, data.count - 4, nil, COMPRESSION_LZFSE)
        }
        return decoded == size ? Data(output) : nil
    }
}
