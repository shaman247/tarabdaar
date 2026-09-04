import TarabdaarCore
import SwiftUI
import UIKit

struct TouchInfo: Identifiable {
    let id: Int  // touch hash for identification
    let location: CGPoint
    let phase: UITouch.Phase
    let timestamp: TimeInterval
}

struct TouchEvent {
    let touchId: Int
    let xFraction: Double  // 0-1 across view width
    let yFraction: Double  // 0-1 across view height (0 = top)
    let timestamp: TimeInterval
    /// `UITouch.majorRadius` in POINTS — the fingertip-size signal behind
    /// the flatten detector. Coarse by construction (Apple quantises it
    /// hard); used as a BINARY "flattened" state, never a continuous axis.
    let radius: Double
}

struct TouchOverlayView: UIViewRepresentable {
    @Binding var touches: [TouchInfo]
    var onTouchBegan: ((TouchEvent) -> Void)?
    var onTouchMoved: ((TouchEvent) -> Void)?
    var onTouchEnded: ((Int) -> Void)?

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.isMultipleTouchEnabled = true
        view.isExclusiveTouch = false
        view.gestureRecognizers?.forEach { $0.isEnabled = false }

        view.onTouchesChanged = { touchInfos in
            DispatchQueue.main.async {
                self.touches = touchInfos
            }
        }
        view.onTouchBegan = onTouchBegan
        view.onTouchMoved = onTouchMoved
        view.onTouchEnded = onTouchEnded
        return view
    }

    func updateUIView(_ uiView: TouchCaptureView, context: Context) {
        uiView.onTouchBegan = onTouchBegan
        uiView.onTouchMoved = onTouchMoved
        uiView.onTouchEnded = onTouchEnded
    }
}

class TouchCaptureView: UIView {
    var onTouchesChanged: (([TouchInfo]) -> Void)?
    var onTouchBegan: ((TouchEvent) -> Void)?
    var onTouchMoved: ((TouchEvent) -> Void)?
    var onTouchEnded: ((Int) -> Void)?
    private var activeTouches: Set<UITouch> = []
    // UIKit recycles UITouch instances, so `touch.hash` repeats across
    // consecutive taps — a reused id collides with the per-touch state the
    // surface keys off it (snap offsets, drag assist, MPE channel), so a new
    // tap can inherit or orphan the previous one's. Mint a unique id per
    // touch lifetime instead.
    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var nextTouchId: Int = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        for touch in touches {
            nextTouchId &+= 1
            touchIds[ObjectIdentifier(touch)] = nextTouchId
            let loc = touch.location(in: self)
            let xFrac = Double(loc.x / bounds.width)
            let yFrac = Double(loc.y / bounds.height)
            onTouchBegan?(TouchEvent(
                touchId: nextTouchId,
                xFraction: xFrac,
                yFraction: yFrac,
                timestamp: touch.timestamp,
                radius: Double(touch.majorRadius)
            ))
        }
        reportTouches()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIds[ObjectIdentifier(touch)] else { continue }
            let loc = touch.location(in: self)
            let xFrac = Double(loc.x / bounds.width)
            let yFrac = Double(loc.y / bounds.height)
            onTouchMoved?(TouchEvent(
                touchId: id,
                xFraction: xFrac,
                yFraction: yFrac,
                timestamp: touch.timestamp,
                radius: Double(touch.majorRadius)
            ))
        }
        reportTouches()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let id = touchIds.removeValue(forKey: ObjectIdentifier(touch)) {
                onTouchEnded?(id)
            }
        }
        activeTouches.subtract(touches)
        reportTouches()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let id = touchIds.removeValue(forKey: ObjectIdentifier(touch)) {
                onTouchEnded?(id)
            }
        }
        activeTouches.subtract(touches)
        reportTouches()
    }

    private func reportTouches() {
        let infos = activeTouches.map { touch in
            TouchInfo(
                id: touchIds[ObjectIdentifier(touch)] ?? touch.hash,
                location: touch.location(in: self),
                phase: touch.phase,
                timestamp: touch.timestamp
            )
        }
        onTouchesChanged?(infos)
    }
}
