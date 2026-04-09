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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        for touch in touches {
            let loc = touch.location(in: self)
            let xFrac = Double(loc.x / bounds.width)
            let yFrac = Double(loc.y / bounds.height)
            onTouchBegan?(TouchEvent(
                touchId: touch.hash,
                xFraction: xFrac,
                yFraction: yFrac,
                timestamp: touch.timestamp
            ))
        }
        reportTouches()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let loc = touch.location(in: self)
            let xFrac = Double(loc.x / bounds.width)
            let yFrac = Double(loc.y / bounds.height)
            onTouchMoved?(TouchEvent(
                touchId: touch.hash,
                xFraction: xFrac,
                yFraction: yFrac,
                timestamp: touch.timestamp
            ))
        }
        reportTouches()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            onTouchEnded?(touch.hash)
        }
        activeTouches.subtract(touches)
        reportTouches()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            onTouchEnded?(touch.hash)
        }
        activeTouches.subtract(touches)
        reportTouches()
    }

    private func reportTouches() {
        let infos = activeTouches.map { touch in
            TouchInfo(
                id: touch.hash,
                location: touch.location(in: self),
                phase: touch.phase,
                timestamp: touch.timestamp
            )
        }
        onTouchesChanged?(infos)
    }
}
