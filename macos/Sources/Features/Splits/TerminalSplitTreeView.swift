import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    @EnvironmentObject private var ghostty: Ghostty.App

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
            // Establish a coordinate space so nested leaves can publish their
            // bounding rect in a stable frame of reference.
            .coordinateSpace(name: TerminalSplitTreeView.coordinateSpaceName)
            // Draw the focused-split border on top of the entire tree (above
            // every divider, regardless of nesting depth). The rect comes from
            // the deepest focused leaf via FocusedLeafBoundsKey.
            .overlayPreferenceValue(FocusedLeafBoundsKey.self) { rect in
                // Only render the focus border when the tree actually has
                // splits (not a single leaf). Mirrors the original `isSplit`
                // guard from SurfaceView.
                if case .split = node,
                   let rect,
                   let color = ghostty.config.focusedSplitBorderColor {
                    FocusedSplitBorder(
                        rect: rect,
                        color: color,
                        width: CGFloat(ghostty.config.focusedSplitBorderWidth),
                        opacity: ghostty.config.focusedSplitBorderOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    static let coordinateSpaceName: String = "TerminalSplitTreeView"
}

/// Carries the bounding rect of the focused split leaf (if any) up to the
/// TerminalSplitTreeView so it can render the focus border on top of the
/// entire tree — above every divider, regardless of split nesting depth.
private struct FocusedLeafBoundsKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Renders a rectangular border at the given rect using four edge-anchored
/// filled bars. Positioned absolutely in the parent's coordinate space via
/// .offset, so it sits on top of all dividers and avoids the subpixel
/// fade-out that .strokeBorder suffers on fractional-point bounds.
private struct FocusedSplitBorder: View {
    let rect: CGRect
    let color: Color
    let width: CGFloat
    let opacity: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color)
                .frame(width: rect.width, height: width)
                .offset(x: rect.minX, y: rect.minY)
            Rectangle().fill(color)
                .frame(width: rect.width, height: width)
                .offset(x: rect.minX, y: rect.maxY - width)
            Rectangle().fill(color)
                .frame(width: width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            Rectangle().fill(color)
                .frame(width: width, height: rect.height)
                .offset(x: rect.maxX - width, y: rect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(opacity)
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    @Environment(\.ghosttyLastFocusedSurface) private var lastFocusedSurface

    private var isFocused: Bool {
        lastFocusedSurface?.value === surfaceView
    }

    var body: some View {
        GeometryReader { geometry in
            Ghostty.InspectableSurface(
                surfaceView: surfaceView,
                isSplit: isSplit)
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .allowsHitTesting(false)
                }
            }
            // Publish our bounding rect (in the TerminalSplitTreeView's
            // coordinate space) when our surface is the focused one, so the
            // root can draw a border around us on top of every divider.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FocusedLeafBoundsKey.self,
                        value: isFocused
                            ? proxy.frame(in: .named(TerminalSplitTreeView.coordinateSpaceName))
                            : nil)
                }
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
}
