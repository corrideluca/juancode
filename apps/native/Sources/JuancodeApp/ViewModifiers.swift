import SwiftUI
import AppKit

extension View {
    /// Web-like affordance for a clickable control: the pointing-hand cursor on
    /// hover **and** a subtle background highlight so the control visibly reacts
    /// (macOS gives plain buttons neither by default). The highlight is drawn as a
    /// negative-inset background, so it extends slightly beyond the label without
    /// changing the control's layout footprint — safe to drop onto any existing
    /// button. Applied app-wide via the many `.clickCursor()` call sites.
    func clickCursor() -> some View {
        modifier(ClickCursorModifier())
    }

    /// Pointing-hand cursor only (no highlight) — for larger custom hit areas where
    /// a background chip would look wrong (e.g. the terminal-drop zone).
    @ViewBuilder
    func pointerCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }
}

private struct ClickCursorModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                    .padding(-3) // extend the chip beyond the label; no layout shift
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerCursor()
            .animation(.easeOut(duration: 0.10), value: hovering)
    }
}

// MARK: - Resize handle (juancode-n9y)

/// A draggable splitter with a genuinely usable hit area and clear hover feedback —
/// the thin 1pt dividers were nearly impossible to grab. The visible line is thin
/// at rest and thickens + brightens to the accent colour while hovered or dragged,
/// but the actual draggable zone is `hit` points wide regardless.
///
/// `axis: .vertical` is a vertical bar resized horizontally; `.horizontal` is a
/// horizontal bar resized vertically. The clamped size is written through `value`.
/// `invert` (default true) flips the drag direction for a handle sitting on the
/// near edge of the pane it resizes (drag toward the pane shrinks it).
struct DragResizeHandle: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    @Binding var value: Double
    let min: Double
    let max: Double
    var invert: Bool = true

    /// Width/height of the invisible grab zone.
    private let hit: CGFloat = 14
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let active = hovering || dragging
        let lineColor = active ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.22)
        let thickness: CGFloat = active ? 3 : 1
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: thickness / 2)
                .fill(lineColor)
                .frame(
                    width: axis == .vertical ? thickness : nil,
                    height: axis == .horizontal ? thickness : nil)
        }
        .frame(width: axis == .vertical ? hit : nil,
               height: axis == .horizontal ? hit : nil)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h {
                (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else if !dragging {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { v in
                    dragging = true
                    let delta = axis == .vertical ? v.translation.width : v.translation.height
                    let signed = invert ? -delta : delta
                    value = Swift.min(max, Swift.max(min, value + signed))
                }
                .onEnded { _ in
                    dragging = false
                    if !hovering { NSCursor.pop() }
                }
        )
        .animation(.easeOut(duration: 0.10), value: active)
    }
}
