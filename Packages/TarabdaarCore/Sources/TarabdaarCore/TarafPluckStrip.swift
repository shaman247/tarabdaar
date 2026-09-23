import Foundation
import SwiftUI

/// A presentation snapshot of the running kernel bank, never an editable tuning.
public struct TarafBank: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UInt8
        public let frequency: Float
        public let flags: UInt8
        public var isDual: Bool { flags & 1 != 0 }
        public var isFollower: Bool { flags & 2 != 0 }
        public init(id: UInt8, frequency: Float, flags: UInt8 = 0) {
            self.id = id; self.frequency = frequency; self.flags = flags
        }
    }
    public let revision: UInt32
    public let tonic: Float
    public let rows: [Row]
    public static let empty = TarafBank(revision: 0, tonic: 261.63, rows: [])
    public init(revision: UInt32, tonic: Float, rows: [Row]) {
        self.revision = revision; self.tonic = tonic; self.rows = rows
    }
    public var orderedRows: [Row] {
        rows.sorted { $0.frequency == $1.frequency ? $0.id < $1.id : $0.frequency < $1.frequency }
    }
    public func contains(revision: UInt32, row: UInt8) -> Bool {
        self.revision == revision && rows.contains { $0.id == row }
    }
}

/// Cross every intervening cell once, including coalesced fast drags and reversals.
public struct TarafStrumGesture {
    private var last: Int?
    public init() {}
    public mutating func reset() { last = nil }
    public mutating func move(x: Double, count: Int) -> [Int] {
        guard x.isFinite, count > 0 else { reset(); return [] }
        let outside = x < 0 || x > 1
        guard !outside || last != nil else { return [] }
        let next = min(count - 1, Int(min(1, max(0, x)) * Double(count)))
        defer { last = outside ? nil : next }
        guard let old = last else { return [next] }
        guard old != next else { return [] }
        let step = next > old ? 1 : -1
        return Array(stride(from: old + step, through: next, by: step))
    }
}

/// Direct plucks above the pad; melody touches remain owned by the pad below.
public struct TarafPluckStrip: View {
    public let bank: TarafBank
    public let scale: PitchScale
    public let pluck: (UInt32, UInt8) -> Void
    @State private var stroke = TarafStrumGesture()
    @State private var dragging = false
    @State private var strokeRevision: UInt32?
    @State private var active: UInt8?

    public init(bank: TarafBank, scale: PitchScale,
                pluck: @escaping (UInt32, UInt8) -> Void) {
        self.bank = bank; self.scale = scale; self.pluck = pluck
    }
    public var body: some View {
        let rows = bank.orderedRows
        if !rows.isEmpty {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(rows) { row in
                        let label = row.isFollower ? "↗" : scaleLabel(
                            forRatio: Double(row.frequency / bank.tonic), degrees: scaleDegrees(from: scale))
                        VStack(spacing: 3) {
                            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Rectangle().fill(row.isDual ? Color.orange : Color.cyan.opacity(0.65))
                                .frame(width: row.isDual ? 2 : 1, height: 21)
                            Text(String(Int(row.id) + 1)).font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(active == row.id ? Color.cyan.opacity(0.3) : Color.white.opacity(0.035))
                        .overlay(alignment: .trailing) { Color.white.opacity(0.12).frame(width: 1) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Taraf \(Int(row.id) + 1), \(label)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { pluck(bank.revision, row.id) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            strokeRevision = bank.revision
                            visit(value.startLocation, size: geometry.size, rows: rows)
                        }
                        guard strokeRevision == bank.revision else { return }
                        visit(value.location, size: geometry.size, rows: rows)
                    }
                    .onEnded { value in
                        if strokeRevision == bank.revision {
                            visit(value.location, size: geometry.size, rows: rows)
                        }
                        reset()
                    })
            }
            .frame(height: 64)
            .onChange(of: bank) { _ in stroke.reset(); active = nil }
            .onDisappear { reset() }
        }
    }
    private func reset() { stroke.reset(); dragging = false; strokeRevision = nil; active = nil }
    private func visit(_ point: CGPoint, size: CGSize, rows: [TarafBank.Row]) {
        guard size.width > 0, point.y >= 0, point.y <= size.height else {
            stroke.reset(); active = nil; return
        }
        let crossed = stroke.move(x: point.x / size.width, count: rows.count)
        for index in crossed { pluck(bank.revision, rows[index].id) }
        if let index = crossed.last { active = rows[index].id }
        if point.x < 0 || point.x > size.width { active = nil }
    }
}
