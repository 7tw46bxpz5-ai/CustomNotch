import SwiftUI

// MARK: - Model

enum IslandState: Equatable {
    case resting    // just the black notch
    case compact    // black pill, notch height, grows to the sides
    case peek       // small bubble under the notch for a few seconds
    case expanded   // the tiles
    case permission // Claude Code asks: stays open until answered
    case prompter   // the teleprompter: stays open until you stop it
    case chess      // the chess board: stays open until you close it or click outside

    var isOpen: Bool { self == .peek || self == .expanded || self == .permission || self == .prompter || self == .chess }
}

struct PeekContent: Equatable {
    enum Tint { case accent, neutral, caution, warning, critical }

    let id = UUID()
    var symbol: String
    var title: String
    var subtitle: String?
    var tint: Tint = .accent
    var duration: TimeInterval = 3
    /// Peeks of the same group replace each other instead of queueing (e.g. several apps opening).
    var group: String? = nil
}

/// What the black pill shows on its two wings.
struct CompactContent: Equatable {
    enum Leading: Equatable {
        case symbol(String)
        case artwork(NSImage?)      // music: the cover, or a note while it loads
    }

    enum Trailing: Equatable { case none, activity, equalizer }

    var leading: Leading
    var trailing: Trailing
}

/// Sizes measured from the reference screenshots (1 pt ≈ 1.55 px there).
enum Metrics {
    static let ear: CGFloat = 6                 // concave fillet where the notch meets the screen edge
    static let notchRadius: CGFloat = 9
    static let compactWing: CGFloat = 40
    static let compactRadius: CGFloat = 12
    static let peekWing: CGFloat = 72
    static let peekHeight: CGFloat = 44
    static let peekEar: CGFloat = 8
    static let islandRadius: CGFloat = 24       // concentric with the tiles: tile radius 14 + side padding 10
    static let sidePadding: CGFloat = 10
    static let topGap: CGFloat = 6              // between the notch and the tiles (kept small: less screen covered)
    static let bottomPadding: CGFloat = 10
    static let cell: CGFloat = 77
    static let gap: CGFloat = 8
    static let tileHeight: CGFloat = 80
    static let tileRadius: CGFloat = 14
    static let shadowMargin: CGFloat = 28
    static let screenMargin: CGFloat = 24       // keeps a wide island off the screen edges

    static func tileWidth(cells: Int) -> CGFloat {
        CGFloat(cells) * cell + CGFloat(max(cells - 1, 0)) * gap
    }

    static func rowWidth(_ cells: [Int]) -> CGFloat {
        cells.map(tileWidth).reduce(0, +) + CGFloat(max(cells.count - 1, 0)) * gap
    }
}

@MainActor @Observable
final class IslandModel {
    var geometry: NotchGeometry
    var state: IslandState = .resting
    var pinned = false
    var peek: PeekContent?
    var compact: CompactContent?
    /// Tiles that are switched on but have nothing to show right now (music while no player is open).
    var unavailableTiles: Set<TileKind> = []

    @ObservationIgnored let settings: Settings
    @ObservationIgnored var claude: ClaudeBridge?
    @ObservationIgnored var prompter: Teleprompter?
    @ObservationIgnored var chess: ChessGame?
    /// Closes the chess board (its close button).
    @ObservationIgnored var closeChess: () -> Void = {}
    /// Applies a new tile layout; the controller resizes the window before the change animates.
    @ObservationIgnored var applyTiles: ([TileConfig]) -> Void = { _ in }

    init(geometry: NotchGeometry, settings: Settings) {
        self.geometry = geometry
        self.settings = settings
    }

    /// Visible tiles split into rows that fit on the screen (one row on most Macs).
    func rows(for tiles: [TileConfig]) -> [[TileConfig]] {
        let maxWidth = geometry.screenFrame.width - 2 * (Metrics.screenMargin + Metrics.sidePadding)
        var rows: [[TileConfig]] = []
        var current: [TileConfig] = []
        for tile in tiles where tile.visible && !unavailableTiles.contains(tile.kind) {
            let candidate = current + [tile]
            if !current.isEmpty && Metrics.rowWidth(candidate.map(\.cells)) > maxWidth {
                rows.append(current)
                current = [tile]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func expandedSize(for tiles: [TileConfig]) -> CGSize {
        let notch = geometry.notch.size
        let rows = rows(for: tiles)
        let contentWidth = rows.map { Metrics.rowWidth($0.map(\.cells)) }.max() ?? 0
        let rowCount = CGFloat(max(rows.count, 1))
        return CGSize(width: max(contentWidth + 2 * Metrics.sidePadding, notch.width + 160),
                      height: notch.height + Metrics.topGap + rowCount * Metrics.tileHeight
                              + (rowCount - 1) * Metrics.gap + Metrics.bottomPadding)
    }

    /// Full size of the island shape, ears included.
    func size(for state: IslandState) -> CGSize {
        let notch = geometry.notch.size
        switch state {
        case .resting:
            return notch     // no ears, so the window never covers the menu bar next to the notch
        case .compact:
            return CGSize(width: notch.width + 2 * (Metrics.compactWing + Metrics.ear), height: notch.height)
        case .peek:
            return CGSize(width: notch.width + 2 * (Metrics.peekWing + Metrics.peekEar),
                          height: notch.height + Metrics.peekHeight)
        case .expanded:
            return expandedSize(for: settings.tiles)
        case .permission:
            let request = claude?.requests.first
            return CGSize(width: PermissionLayout.width,
                          height: notch.height + PermissionLayout.height(detail: request?.detail ?? "", hasNote: request?.note != nil))
        case .prompter:
            let layout = PrompterLayout(settings: settings)
            return CGSize(width: max(layout.width, notch.width + 160), height: notch.height + layout.areaHeight)
        case .chess:
            return CGSize(width: max(ChessLayout.width, notch.width + 160), height: notch.height + ChessLayout.areaHeight)
        }
    }

    func ear(for state: IslandState) -> CGFloat {
        switch state {
        case .resting: return 0
        case .compact: return Metrics.ear
        case .peek: return Metrics.peekEar
        case .expanded, .permission, .prompter, .chess: return 0     // square top corners, as in the screenshots
        }
    }

    func radius(for state: IslandState) -> CGFloat {
        switch state {
        case .resting: return Metrics.notchRadius
        case .compact: return Metrics.compactRadius
        case .peek, .expanded, .permission, .chess: return Metrics.islandRadius
        case .prompter: return PrompterLayout.radius
        }
    }
}

// MARK: - Shape

/// Flat top flush with the screen edge, concave ears at the top corners, rounded bottom corners.
struct IslandShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let k: CGFloat = 0.5523           // cubic approximation of a quarter circle
        let w = rect.width, h = rect.height
        let e = max(0, min(ear, w / 4, h / 2))
        let r = max(0, min(radius, (w - 2 * e) / 2, h - e))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addCurve(to: CGPoint(x: w - e, y: e),
                   control1: CGPoint(x: w - k * e, y: 0), control2: CGPoint(x: w - e, y: e - k * e))
        p.addLine(to: CGPoint(x: w - e, y: h - r))
        p.addCurve(to: CGPoint(x: w - e - r, y: h),
                   control1: CGPoint(x: w - e, y: h - r + k * r), control2: CGPoint(x: w - e - r + k * r, y: h))
        p.addLine(to: CGPoint(x: e + r, y: h))
        p.addCurve(to: CGPoint(x: e, y: h - r),
                   control1: CGPoint(x: e + r - k * r, y: h), control2: CGPoint(x: e, y: h - r + k * r))
        p.addLine(to: CGPoint(x: e, y: e))
        p.addCurve(to: CGPoint(x: 0, y: 0),
                   control1: CGPoint(x: e, y: e - k * e), control2: CGPoint(x: k * e, y: 0))
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

// MARK: - Views

struct IslandRootView: View {
    let model: IslandModel
    let settings: Settings
    let services: Services

    var body: some View {
        let state = model.state
        // The theme colours tiles and buttons; the island and the teleprompter on it stay white on black.
        let palette = state == .prompter ? Palette.darkMatte : settings.palette
        let size = model.size(for: state)
        let shape = IslandShape(ear: model.ear(for: state), radius: model.radius(for: state))
        let notch = model.geometry.notch.size

        ZStack(alignment: .top) {
            IslandBackground(open: state.isOpen, shape: shape, size: size)

            // The real notch is always black; this also draws the fake notch on Macs without one.
            // Its ears fade in only while the island is out, so resting covers nothing but the notch.
            let notchEar = state == .resting ? 0 : Metrics.ear
            IslandShape(ear: notchEar, radius: Metrics.notchRadius)
                .fill(Color.black)
                .frame(width: notch.width + 2 * notchEar, height: notch.height)

            content(palette: palette)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // System colours on the island are dark; tiles and buttons switch to the theme's scheme themselves.
        .environment(\.colorScheme, .dark)
    }

    /// Open content shrinks into the notch with the island (and grows out of it), like the Dynamic Island.
    private func collapse(from size: CGSize) -> AnyTransition {
        let notch = model.geometry.notch.size
        return .collapse(to: min(notch.width / max(size.width, 1), notch.height / max(size.height, 1)))
    }

    @ViewBuilder
    private func content(palette: Palette) -> some View {
        switch model.state {
        case .resting:
            Color.clear.frame(width: 0, height: 0)
        case .compact:
            if let compact = model.compact {
                CompactView(content: compact, notch: model.geometry.notch.size)
                    .frame(width: model.size(for: .compact).width, height: model.geometry.notch.height)
                    .transition(.opacity)
            }
        case .peek:
            if let peek = model.peek {
                PeekView(peek: peek, palette: .darkMatte, notchHeight: model.geometry.notch.height)
                    .frame(width: model.size(for: .peek).width, height: model.size(for: .peek).height, alignment: .top)
                    .transition(collapse(from: model.size(for: .peek)))
            }
        case .expanded:
            ExpandedView(model: model, services: services, palette: palette)
                .frame(width: model.size(for: .expanded).width, height: model.size(for: .expanded).height, alignment: .top)
                .transition(collapse(from: model.size(for: .expanded)))
        case .permission:
            if let claude = model.claude {
                PermissionView(claude: claude, palette: palette, notchHeight: model.geometry.notch.height)
                    .frame(width: model.size(for: .permission).width, height: model.size(for: .permission).height, alignment: .top)
                    .transition(collapse(from: model.size(for: .permission)))
            }
        case .prompter:
            if let prompter = model.prompter {
                PrompterView(prompter: prompter, settings: settings, notch: model.geometry.notch.size)
                    .frame(width: model.size(for: .prompter).width, height: model.size(for: .prompter).height, alignment: .top)
                    .transition(collapse(from: model.size(for: .prompter)))
            }
        case .chess:
            if let chess = model.chess {
                ChessView(game: chess, palette: palette, notchHeight: model.geometry.notch.height, close: model.closeChess)
                    .frame(width: model.size(for: .chess).width, height: model.size(for: .chess).height, alignment: .top)
                    .transition(collapse(from: model.size(for: .chess)))
            }
        }
    }
}

/// One black shape that is the island, with a soft shadow while it is open (the theme only colours the tiles).
struct IslandBackground: View {
    let open: Bool
    let shape: IslandShape
    let size: CGSize

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 14, y: 6)
            .frame(width: size.width, height: size.height)
    }
}

/// Scales content toward the notch (anchored at the top centre) as `progress` goes from 1 to 0. The content
/// stays solid while it shrinks and only blurs and fades in the last part, so it reads as closing, not fading.
struct CollapseEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let smallest: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let tail = max(0, 0.4 - p) / 0.4          // 0 until the last 40 %, then up to 1
        content
            .scaleEffect(smallest + (1 - smallest) * p, anchor: .top)
            .blur(radius: tail * 5)
            .opacity(Double(min(1, p * 2.5)))
    }
}

extension AnyTransition {
    static func collapse(to smallest: CGFloat) -> AnyTransition {
        .modifier(active: CollapseEffect(progress: 0, smallest: smallest),
                  identity: CollapseEffect(progress: 1, smallest: smallest))
    }
}

/// Black pill: an icon on the left wing, live activity on the right wing.
struct CompactView: View {
    let content: CompactContent
    let notch: CGSize
    // The pill is always black, so it uses the dark palette whatever the theme.
    private let palette = Palette.darkMatte
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: Metrics.compactWing)
            Color.clear.frame(width: notch.width)
            trailing.frame(width: Metrics.compactWing)
        }
        .padding(.horizontal, Metrics.ear)
    }

    @ViewBuilder
    private var leading: some View {
        switch content.leading {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
        case .artwork(let image?):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .artwork(nil):
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch content.trailing {
        case .none:
            Color.clear
        case .activity:
            if staticRendering {
                StaticGrid(color: palette.accent).frame(width: 16, height: 16)
            } else {
                ActivityGrid(color: palette.accent).frame(width: 16, height: 16)
            }
        case .equalizer:
            if staticRendering {
                StaticEqualizer(color: palette.accent).frame(width: 16, height: 14)
            } else {
                Equalizer(color: palette.accent).frame(width: 16, height: 14)
            }
        }
    }
}

/// Four bars bouncing while music plays, run by Core Animation at 15 fps like the grid.
struct Equalizer: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> EqualizerView { EqualizerView(color: NSColor(color)) }
    func updateNSView(_ view: EqualizerView, context: Context) {}
}

final class EqualizerView: NSView {
    init(color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 14))
        wantsLayer = true
        let width: CGFloat = 2.4, spacing: CGFloat = 1.8, height: CGFloat = 14
        let origin = (16 - (4 * width + 3 * spacing)) / 2
        let patterns: [[Double]] = [[0.35, 0.9, 0.5, 1, 0.35], [0.8, 0.4, 1, 0.55, 0.8], [0.5, 1, 0.3, 0.75, 0.5], [0.9, 0.55, 0.8, 0.35, 0.9]]
        for (index, values) in patterns.enumerated() {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.frame = CGRect(x: origin + CGFloat(index) * (width + spacing), y: 0, width: width, height: height)
            bar.cornerRadius = width / 2
            bar.backgroundColor = color.cgColor
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
            bounce.values = values
            bounce.duration = 1.1 + Double(index) * 0.17
            bounce.repeatCount = .infinity
            bounce.calculationMode = .cubic
            bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
            bar.add(bounce, forKey: "bounce")
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Still frame of the equalizer, for snapshots.
struct StaticEqualizer: View {
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.8) {
            ForEach([0.5, 1, 0.7, 0.85], id: \.self) { level in
                Capsule().fill(color).frame(width: 2.4, height: 14 * level)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// Small 3×3 grid that ripples while something is working. Core Animation plays it outside the
/// app at 15 fps, so SwiftUI never redraws the island for it; it stops when the view goes away.
struct ActivityGrid: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> ActivityGridView { ActivityGridView(color: NSColor(color)) }
    func updateNSView(_ view: ActivityGridView, context: Context) { view.color = NSColor(color) }
}

final class ActivityGridView: NSView {
    private static let side: CGFloat = 16
    private var dots: [CALayer] = []

    var color: NSColor {
        didSet { dots.forEach { $0.backgroundColor = color.cgColor } }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        let dot: CGFloat = 3, spacing: CGFloat = 1.75, period = 1.25
        let origin = (Self.side - (3 * dot + 2 * spacing)) / 2
        for row in 0..<3 {
            for col in 0..<3 {
                let layer = CALayer()
                layer.frame = CGRect(x: origin + CGFloat(col) * (dot + spacing),
                                     y: origin + CGFloat(2 - row) * (dot + spacing), width: dot, height: dot)
                layer.cornerRadius = 0.8
                layer.backgroundColor = color.cgColor
                layer.opacity = 0.25

                let ripple = CAKeyframeAnimation(keyPath: "opacity")
                ripple.values = [0.25, 1, 0.25, 0.25]
                ripple.keyTimes = [0, 0.25, 0.5, 1]
                ripple.duration = period
                ripple.repeatCount = .infinity
                ripple.timeOffset = period - Double(row + col) * 0.14     // diagonal wave
                ripple.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
                layer.add(ripple, forKey: "ripple")

                self.layer?.addSublayer(layer)
                dots.append(layer)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
}

/// Still frame of the grid, for snapshots (ImageRenderer cannot draw AppKit views).
struct StaticGrid: View {
    let color: Color

    var body: some View {
        Canvas { gc, size in
            let dot: CGFloat = 3, spacing: CGFloat = 1.75
            let origin = (size.width - (3 * dot + 2 * spacing)) / 2
            for row in 0..<3 {
                for col in 0..<3 {
                    let rect = CGRect(x: origin + CGFloat(col) * (dot + spacing),
                                      y: origin + CGFloat(row) * (dot + spacing), width: dot, height: dot)
                    let opacity = row + col == 2 ? 1 : 0.35
                    gc.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(color.opacity(opacity)))
                }
            }
        }
    }
}

// (SwiftUI's @Entry macro needs Xcode, so this uses a classic EnvironmentKey.)
private struct StaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering snapshots: views avoid live animations and AppKit-backed content.
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}

struct PeekView: View {
    let peek: PeekContent
    let palette: Palette
    let notchHeight: CGFloat

    private var tint: Color {
        switch peek.tint {
        case .accent: return palette.accent
        case .neutral: return palette.secondary
        case .caution: return palette.caution
        case .warning: return palette.warning
        case .critical: return palette.critical
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peek.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                if let subtitle = peek.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.peekEar + 20)
        .frame(height: Metrics.peekHeight)
        .padding(.top, notchHeight)
    }
}

// MARK: - Claude Code permission

/// Sizes for the permission panel; the window is sized from the command text before it is shown.
enum PermissionLayout {
    static let width: CGFloat = 640
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let maxBox: CGFloat = 260
    // Measured a little narrower than the box, in case scroll bars are set to always show.
    private static let textWidth = width - 2 * 16 - 2 * 10 - 16

    /// AppKit counts the lines; SwiftUI draws each line slightly taller (14 pt vs 13 pt for this font),
    /// so the height uses SwiftUI's line height. A short command then fits without scrolling.
    static func boxHeight(for text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: font])
        let appKitLine = NSLayoutManager().defaultLineHeight(for: font)
        let lines = max(1, (bounds.height / appKitLine).rounded())
        let swiftUILine = (font.ascender - font.descender + font.leading).rounded(.up)
        return min(lines * swiftUILine + 22, maxBox)
    }

    /// Everything below the notch: header, optional note, command box, buttons, margins.
    static func height(detail: String, hasNote: Bool) -> CGFloat {
        12 + 18 + 8 + (hasNote ? 22 : 0) + boxHeight(for: detail) + 10 + 26 + 14
    }
}

private struct CommandBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The whole command (scrollable, never shortened), with Deny / Allow. Allow is available only once the
/// end of the command has been on screen; "Answer in Terminal" hands it back without deciding.
struct PermissionView: View {
    let claude: ClaudeBridge
    let palette: Palette                        // the command box and the buttons
    let notchHeight: CGFloat
    private let island = Palette.darkMatte      // text straight on the black island
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        if let request = claude.requests.first {
            let box = PermissionLayout.boxHeight(for: request.detail)
            let seen = claude.fullySeen.contains(request.id)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: ClaudeBridge.Step.of(tool: request.tool).symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(island.accent)
                    Text("Claude Code wants to \(request.title.prefix(1).lowercased() + request.title.dropFirst())")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(island.text)
                    Spacer(minLength: 8)
                    if claude.requests.count > 1 {
                        Text("+\(claude.requests.count - 1) more").font(.system(size: 11)).foregroundStyle(island.accent)
                    }
                    if !request.project.isEmpty {
                        Text(request.project).font(.system(size: 11)).foregroundStyle(island.secondary).lineLimit(1)
                    }
                }
                .frame(height: 18)
                if let note = request.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(island.secondary).lineLimit(1).frame(height: 14)
                }
                if staticRendering {
                    // Snapshots can't draw a scroll view (an AppKit view): show the text directly.
                    commandText(request.detail)
                        .frame(maxWidth: .infinity, maxHeight: box, alignment: .topLeading)
                        .clipped()
                        .background(palette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ScrollView(.vertical) {
                        commandText(request.detail)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: CommandBottomKey.self,
                                                       value: geometry.frame(in: .named("command")).maxY)
                            })
                    }
                    .coordinateSpace(name: "command")
                    .frame(height: box)
                    .background(palette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .environment(\.colorScheme, palette.colorScheme)
                    .onPreferenceChange(CommandBottomKey.self) { bottom in
                        if bottom <= box + 1 { claude.fullySeen.insert(request.id) }
                    }
                }
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(ClaudeBridge.fallbackDelay - context.date.timeIntervalSince(request.received)))
                        Text("Goes to the terminal in \(left / 60):\(String(format: "%02d", left % 60))")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(island.secondary)
                    }
                    Button { claude.answer(request.id, allow: nil) } label: {
                        Text("Answer in Terminal").font(.system(size: 10.5, weight: .medium)).foregroundStyle(island.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    if !seen {
                        Text("Scroll to the end to allow").font(.system(size: 10.5)).foregroundStyle(island.secondary)
                    }
                    choice("Deny", shortcut: "⌃⌥N", primary: false) { claude.answer(request.id, allow: false) }
                    choice("Allow", shortcut: "⌃⌥Y", primary: true, enabled: seen) { claude.answer(request.id, allow: true) }
                }
                .frame(height: 26)
            }
            .padding(.horizontal, 16)
            .padding(.top, notchHeight + 12)
            .padding(.bottom, 14)
            .id(request.id)
        }
    }

    private func commandText(_ text: String) -> some View {
        Text(text)
            .font(Font(PermissionLayout.font))
            .foregroundStyle(palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    /// A disabled button keeps its solid capsule and dims only its label (a faded light capsule turns muddy on black).
    private func choice(_ title: String, shortcut: String, primary: Bool, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(shortcut).font(.system(size: 10)).opacity(0.7)
            }
            .foregroundStyle(primary ? palette.accent : palette.text)
            .opacity(enabled ? 1 : 0.4)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(primary && enabled ? palette.controlActive : palette.control, in: Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(enabled)         // not .disabled: that would fade the capsule too
        .environment(\.colorScheme, palette.colorScheme)
    }
}
