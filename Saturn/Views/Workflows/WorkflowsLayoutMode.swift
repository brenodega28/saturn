import CoreGraphics

enum WorkflowsLayoutMode: Equatable, CaseIterable {
    case wide
    case medium
    case narrow

    static let sidebarWidth: CGFloat = 230
    static let inspectorWidth: CGFloat = 300
    static let columnSpacing: CGFloat = 20
    static let minimumStepsWidth: CGFloat = 340

    init(width: CGFloat) {
        self = [Self.wide, .medium].first { $0.canvasWidth(in: width) >= Self.minimumStepsWidth } ?? .narrow
    }

    var reservedWidth: CGFloat {
        switch self {
        case .wide: Self.sidebarWidth + Self.inspectorWidth + 2 * Self.columnSpacing
        case .medium: Self.inspectorWidth + Self.columnSpacing
        case .narrow: 0
        }
    }

    func canvasWidth(in width: CGFloat) -> CGFloat {
        max(0, width - reservedWidth)
    }

    var showsSidebar: Bool { self == .wide }
    var showsInspectorColumn: Bool { self != .narrow }
}
