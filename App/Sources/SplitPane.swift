import SwiftUI

/// Two panes with a draggable hairline between them. `fraction` is the first pane's share.
/// Plain SwiftUI (unlike `HSplitView`/`VSplitView`), so safe areas and scroll edge effects behave.
struct SplitPane<First: View, Second: View>: View {
    let axis: Axis
    @Binding var fraction: Double
    var minFirst: CGFloat = 160
    var minSecond: CGFloat = 160
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    private var horizontal: Bool { axis == .horizontal }

    var body: some View {
        GeometryReader { geo in
            let total = horizontal ? geo.size.width : geo.size.height
            let size = min(max(total * fraction, minFirst), max(minFirst, total - minSecond))
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: horizontal ? size : nil, height: horizontal ? nil : size)
                handle(total: total)
                second
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(.named("split"))
        }
    }

    private func handle(total: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 9 : nil, height: horizontal ? nil : 9)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                            .onChanged { value in
                                guard total > 0 else { return }
                                let position = horizontal ? value.location.x : value.location.y
                                fraction = min(max(position / total, 0.1), 0.9)
                            }
                    )
            }
            .zIndex(1)
    }
}
