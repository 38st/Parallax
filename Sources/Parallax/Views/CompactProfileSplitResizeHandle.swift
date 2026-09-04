import AppKit
import SwiftUI

enum CompactProfileSplitSizing {
    static let minimumListHeight: CGFloat = 160
    static let minimumEditorHeight: CGFloat = 220
    static let handleHeight: CGFloat = 12
    static let accessibilityStep: CGFloat = 24

    static func listHeight(
        requested: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        min(
            max(requested, minimumListHeight),
            max(
                minimumListHeight,
                availableHeight - minimumEditorHeight - handleHeight
            )
        )
    }
}

struct CompactProfileSplitResizeHandle: View {
    let listHeight: CGFloat
    let availableHeight: CGFloat
    let setListHeight: (CGFloat) -> Void

    @State private var dragStartHeight: CGFloat?
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)

            Capsule()
                .fill(
                    isDragging
                        ? Color.accentColor
                        : Color.secondary.opacity(0.65)
                )
                .frame(width: 36, height: 4)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: CompactProfileSplitSizing.handleHeight,
            maxHeight: CompactProfileSplitSizing.handleHeight
        )
        .contentShape(Rectangle())
        .background(VerticalResizeCursorArea())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = listHeight
                        isDragging = true
                    }
                    setListHeight(
                        CompactProfileSplitSizing.listHeight(
                            requested:
                                (dragStartHeight ?? listHeight)
                                + value.translation.height,
                            availableHeight: availableHeight
                        )
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    isDragging = false
                }
        )
        .help("Drag to resize the spaces list")
        .accessibilityElement()
        .accessibilityLabel("Resize spaces list")
        .accessibilityValue("\(Int(listHeight)) points high")
        .accessibilityHint(
            "Drag vertically or adjust to change the spaces list height"
        )
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = switch direction {
            case .increment:
                CompactProfileSplitSizing.accessibilityStep
            case .decrement:
                -CompactProfileSplitSizing.accessibilityStep
            @unknown default:
                0
            }
            setListHeight(
                CompactProfileSplitSizing.listHeight(
                    requested: listHeight + delta,
                    availableHeight: availableHeight
                )
            )
        }
        .accessibilityIdentifier("detail.compact-split-resize-handle")
    }
}

private struct VerticalResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    private final class CursorView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
