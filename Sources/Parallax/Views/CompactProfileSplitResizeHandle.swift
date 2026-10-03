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
    var isCompact = true

    @State private var dragStartHeight: CGFloat?
    @State private var isDragging = false

    /// Whole points for the accessibility value, typed so the localization
    /// census can infer the placeholder.
    private var listHeightPoints: Int { Int(listHeight) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.separator)
                .frame(width: isCompact ? nil : 1, height: isCompact ? 1 : nil)

            Capsule()
                .fill(
                    isDragging
                        ? Color.accentColor
                        : Color.secondary.opacity(0.65)
                )
                .frame(width: isCompact ? 36 : 4, height: isCompact ? 4 : 36)
        }
        .frame(
            minWidth: isCompact ? nil : CompactProfileSplitSizing.handleHeight,
            maxWidth: isCompact ? .infinity : CompactProfileSplitSizing.handleHeight,
            minHeight: isCompact ? CompactProfileSplitSizing.handleHeight : nil,
            maxHeight: isCompact ? CompactProfileSplitSizing.handleHeight : .infinity
        )
        .contentShape(Rectangle())
        .background(VerticalResizeCursorArea(isCompact: isCompact))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = listHeight
                        isDragging = true
                    }
                    setListHeight(
                        clampedSize(
                            (dragStartHeight ?? listHeight)
                                + (isCompact ? value.translation.height : value.translation.width)
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
        .accessibilityValue(isCompact
            ? Text("\(listHeightPoints) points high")
            : Text("\(listHeightPoints) points wide"))
        .accessibilityHint(
            isCompact
                ? Text("Drag vertically or adjust to change the spaces list height")
                : Text("Drag horizontally or adjust to change the spaces list width")
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
                clampedSize(listHeight + delta)
            )
        }
        .accessibilityIdentifier(isCompact ? "detail.compact-split-resize-handle" : "detail.wide-split-resize-handle")
    }

    private func clampedSize(_ requested: CGFloat) -> CGFloat {
        isCompact
            ? CompactProfileSplitSizing.listHeight(requested: requested, availableHeight: availableHeight)
            : min(max(requested, 220), 320)
    }
}

private struct VerticalResizeCursorArea: NSViewRepresentable {
    let isCompact: Bool

    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.isCompact = isCompact
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        var isCompact = true

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: isCompact ? .resizeUpDown : .resizeLeftRight)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
