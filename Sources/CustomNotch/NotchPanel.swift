import AppKit
import SwiftUI

// MARK: - Notch geometry

/// Where the notch is, in global screen coordinates (origin bottom-left).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notch: CGRect
    var hasNotch: Bool

    /// The screen with a notch, or the main screen with a fake notch at the top centre.
    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        let screen = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
        guard let screen else {
            return NotchGeometry(screenFrame: .zero, notch: CGRect(x: 0, y: 0, width: 185, height: 32), hasNotch: false)
        }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // Use the widths only, so it works whether the areas are screen-local or global.
            let height = screen.safeAreaInsets.top
            let width = frame.width - left.width - right.width
            let notch = CGRect(x: frame.minX + left.width, y: frame.maxY - height, width: width, height: height)
            return NotchGeometry(screenFrame: frame, notch: notch, hasNotch: true)
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 12 ? menuBar : NSStatusBar.system.thickness
        let width: CGFloat = 185
        let notch = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        return NotchGeometry(screenFrame: frame, notch: notch, hasNotch: false)
    }
}

// MARK: - Window

/// Borderless, transparent, non-activating panel above the menu bar, on every Space and in full screen.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false          // the island draws its own soft shadow
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Never let AppKit push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the hover tracking area. It covers only the visible island, not the whole window.
final class IslandContainerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    func setTrackingRect(_ rect: NSRect) {
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Buttons work on the first click even though the panel is never key.
final class IslandHostingView: NSHostingView<IslandRootView> {
    /// Takes scroll events first (the teleprompter); returns false to let SwiftUI have them.
    var onScroll: ((NSEvent) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) != true { super.scrollWheel(with: event) }
    }
}

// MARK: - Controller

/// Drives the island's states and keeps the window exactly around what is visible,
/// so the menu bar next to the notch stays clickable.
@MainActor
final class IslandController {
    let model: IslandModel
    private let panel = IslandPanel()
    private let container = IslandContainerView()

    private var hoverWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var leaveCheck: Timer?
    private var localClicks: Any?
    private var outsideClicks: Any?
    private var peekActive = false
    private var peekQueue: [PeekContent] = []
    private var peekShown = false

    private static let openDelay: TimeInterval = 0.25
    private static let settleTime: TimeInterval = 0.5

    /// Called each time the island opens, so tiles can refresh what they show.
    var onExpand: (() -> Void)?
    /// Called when the open island closes, so live updates can stop.
    var onCollapse: (() -> Void)?

    init(settings: Settings, services: Services) {
        model = IslandModel(geometry: .detect(), settings: settings)
        model.claude = services.claude
        model.prompter = services.prompter
        model.chess = services.chess
        let hosting = IslandHostingView(rootView: IslandRootView(model: model, settings: settings, services: services))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        hosting.frame = container.bounds

        container.onEnter = { [weak self] in self?.mouseEntered() }
        container.onExit = { [weak self] in self?.mouseExited() }
        model.applyTiles = { [weak self] tiles in self?.apply(tiles: tiles) }
        model.closeChess = { [weak self] in self?.collapse() }
        hosting.onScroll = { [weak self] event in self?.scrolled(event) ?? false }

        // Right clicks pin too, so the island stays open while a tile's menu is shown.
        localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window === self.panel { self.clickedInside(event.locationInWindow) }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        panel.setFrame(windowRect(for: .resting), display: true)
        updateTracking()
        panel.orderFrontRegardless()
    }

    // MARK: Public API

    /// Shows a small bubble under the notch for `peek.duration` seconds. Peeks arriving meanwhile wait
    /// their turn (at most three); one of the same group replaces the bubble that is showing.
    func showPeek(_ peek: PeekContent) {
        if peekActive, let group = peek.group, model.peek?.group == group {
            present(peek)
        } else if peekActive {
            peekQueue.removeAll { $0.group != nil && $0.group == peek.group }
            peekQueue.append(peek)
            if peekQueue.count > 3 { peekQueue.removeFirst() }
        } else {
            present(peek)
        }
    }

    private func present(_ peek: PeekContent) {
        peekWork?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { model.peek = peek }
        peekActive = true
        // While the island is open the bubble waits, and shows when it closes (after the teleprompter too,
        // so nothing distracts you while you read).
        guard ![.expanded, .permission, .prompter, .chess].contains(model.state) else {
            peekShown = false
            return
        }
        peekShown = true
        transition(to: .peek)
        scheduleEnd(of: peek)
    }

    private func scheduleEnd(of peek: PeekContent) {
        let work = DispatchWorkItem { [weak self] in self?.endPeek(peek.id) }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peek.duration, execute: work)
    }

    /// Content of the black pill; nil returns the island to resting.
    func setCompact(_ content: CompactContent?) {
        model.compact = content
        if model.state == .resting || model.state == .compact { transition(to: idleState) }
    }

    func expandPinned() {
        hoverWork?.cancel()
        setPinned(true)
        transition(to: .expanded)
    }

    /// Claude Code's permission requests changed: open, resize, or close the panel.
    func claudeRequestsChanged() {
        guard model.state != .prompter else { return }     // they go to the terminal meanwhile
        let hasRequest = !(model.claude?.requests.isEmpty ?? true)
        if hasRequest && model.state != .permission {
            hoverWork?.cancel()
            setPinned(false)
            transition(to: .permission)
        } else if hasRequest {
            let target = windowRect(for: .permission)       // the next request may need another size
            shrinkWork?.cancel()
            panel.setFrame(panel.frame.union(target), display: true)
            updateTracking()
            scheduleShrink(to: target, keeping: .permission)
        } else if model.state == .permission {
            collapse()
        }
    }

    func collapse() {
        guard model.state != .permission || (model.claude?.requests.isEmpty ?? true) else { return }
        guard model.state != .prompter else { return }      // only Stop closes the teleprompter
        close()
    }

    // MARK: Chess

    /// Opens the chess board. It stays open until you close it, click the notch, or click outside it.
    func showChess() {
        guard model.state != .prompter, model.state != .permission else { return }
        hoverWork?.cancel()
        setPinned(true)
        transition(to: .chess)
    }

    // MARK: Teleprompter

    /// Opens the teleprompter under the camera. It stays out until you stop it, and asks macOS to leave it
    /// out of screen recordings and screen sharing (not every app honours that since macOS 15).
    func showPrompter() {
        hoverWork?.cancel()
        setPinned(false)
        panel.sharingType = .none
        transition(to: .prompter)
    }

    func hidePrompter() {
        panel.sharingType = .readOnly
        guard model.state == .prompter else { return }
        close()
    }

    /// Text size or width changed while it is out: grow the window first, then animate to the new size.
    func changePrompterLayout(_ change: () -> Void) {
        guard model.state == .prompter else { change(); return }
        shrinkWork?.cancel()
        let before = panel.frame
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { change() }
        let target = windowRect(for: .prompter)
        panel.setFrame(before.union(target), display: false)
        updateTracking()
        scheduleShrink(to: target, keeping: .prompter)
    }

    /// Two-finger scrolling over the teleprompter moves the script by hand.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard model.state == .prompter, let prompter = model.prompter else { return false }
        let lineHeight = PrompterLayout(settings: model.settings).lineHeight
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        prompter.scroll(byLines: -Double(delta))
        return true
    }

    /// Back to the waiting bubble, the pill or the notch.
    private func close() {
        setPinned(false)
        if peekActive, let peek = model.peek, !peekShown {
            peekShown = true
            transition(to: .peek)
            scheduleEnd(of: peek)
        } else {
            transition(to: peekActive ? .peek : idleState)
        }
    }

    /// Applies a new tile layout, growing the window before the size change animates.
    func apply(tiles: [TileConfig]) {
        guard model.state == .expanded else { model.settings.tiles = tiles; return }
        shrinkWork?.cancel()
        let target = windowRect(island: islandRect(size: model.expandedSize(for: tiles)), open: true)
        panel.setFrame(panel.frame.union(target), display: false)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { model.settings.tiles = tiles }
        updateTracking()
        scheduleShrink(to: target, keeping: .expanded)
    }

    /// Hides or shows tiles that have nothing to show (music when no player is open), resizing like `apply`.
    func setUnavailable(_ kinds: Set<TileKind>) {
        guard kinds != model.unavailableTiles else { return }
        guard model.state == .expanded else { model.unavailableTiles = kinds; return }
        shrinkWork?.cancel()
        let saved = model.unavailableTiles
        model.unavailableTiles = kinds
        let target = windowRect(island: islandRect(size: model.expandedSize(for: model.settings.tiles)), open: true)
        model.unavailableTiles = saved
        panel.setFrame(panel.frame.union(target), display: false)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { model.unavailableTiles = kinds }
        updateTracking()
        scheduleShrink(to: target, keeping: .expanded)
    }

    // MARK: State machine

    private var idleState: IslandState { model.compact != nil ? .compact : .resting }

    private func transition(to state: IslandState) {
        let old = model.state
        guard state != old else { return }
        shrinkWork?.cancel()

        // Grow the window first; shrink it only after the animation has settled.
        let target = windowRect(for: state)
        panel.setFrame(panel.frame.union(target), display: false)
        let opening = model.size(for: state).height > model.size(for: old).height
        // Quick and lively like the Dynamic Island: a little bounce when opening, none when closing.
        let spring: Animation = opening ? .spring(response: 0.34, dampingFraction: 0.72)
                                        : .spring(response: 0.28, dampingFraction: 0.9)
        withAnimation(spring) { model.state = state }
        updateTracking()
        scheduleShrink(to: target, keeping: state)

        if state == .expanded {
            startLeaveCheck()
            onExpand?()
        } else {
            stopLeaveCheck()
            if old == .expanded { onCollapse?() }
        }
    }

    private func scheduleShrink(to target: CGRect, keeping state: IslandState) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == state else { return }
            self.panel.setFrame(target, display: true)
            self.updateTracking()
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime, execute: work)
    }

    private func endPeek(_ id: UUID) {
        guard model.peek?.id == id else { return }
        if !peekQueue.isEmpty {
            present(peekQueue.removeFirst())
            return
        }
        peekActive = false
        if model.state == .peek { transition(to: idleState) }
    }

    // MARK: Mouse

    private func mouseEntered() {
        guard ![.expanded, .permission, .prompter, .chess].contains(model.state) else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mouseIsOverIsland else { return }
            self.transition(to: .expanded)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: work)
    }

    private func mouseExited() {
        guard !mouseIsOverIsland else { return }   // ignore exits caused by resizing
        hoverWork?.cancel()
        if model.state == .expanded && !model.pinned { collapse() }
    }

    private func clickedInside(_ pointInWindow: NSPoint) {
        guard model.state != .permission && model.state != .prompter else { return }       // only their buttons act
        let point = NSPoint(x: pointInWindow.x + panel.frame.minX, y: pointInWindow.y + panel.frame.minY)
        guard isOverIsland(point) else { return }     // shadow margin or a window that is still shrinking
        if model.state == .chess {
            // The board's own buttons act; a click on the notch closes it.
            if Self.containsIncludingTopEdge(model.geometry.notch, point) { collapse() }
            return
        }
        guard model.state == .expanded else { expandPinned(); return }
        if model.pinned && Self.containsIncludingTopEdge(model.geometry.notch, point) {
            collapse()          // a click on the notch closes a pinned island
        } else {
            setPinned(true)
        }
    }

    private func setPinned(_ pinned: Bool) {
        model.pinned = pinned
        if pinned, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.collapse() }
            }
        } else if !pinned, let monitor = outsideClicks {
            NSEvent.removeMonitor(monitor)
            outsideClicks = nil
        }
    }

    /// Safety net for missed exit events, only while expanded and not pinned.
    private func startLeaveCheck() {
        guard leaveCheck == nil else { return }
        leaveCheck = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.pinned, !self.mouseIsOverIsland else { return }
                self.collapse()
            }
        }
    }

    private func stopLeaveCheck() {
        leaveCheck?.invalidate()
        leaveCheck = nil
    }

    private var mouseIsOverIsland: Bool { isOverIsland(NSEvent.mouseLocation) }

    private func isOverIsland(_ point: NSPoint) -> Bool {
        Self.containsIncludingTopEdge(islandRect(for: model.state), point)
    }

    /// With the pointer pushed against the top of the screen its y equals the screen's maxY,
    /// which CGRect.contains treats as outside.
    private static func containsIncludingTopEdge(_ rect: CGRect, _ point: NSPoint) -> Bool {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2).contains(point)
    }

    // MARK: Geometry

    /// The visible island (ears included), in global coordinates. Resting is exactly the notch.
    private func islandRect(for state: IslandState) -> CGRect {
        islandRect(size: model.size(for: state))
    }

    private func islandRect(size: CGSize) -> CGRect {
        let geometry = model.geometry
        return CGRect(x: geometry.notch.midX - size.width / 2, y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func windowRect(for state: IslandState) -> CGRect {
        windowRect(island: islandRect(for: state), open: state.isOpen)
    }

    private func windowRect(island: CGRect, open: Bool) -> CGRect {
        let margin = open ? Metrics.shadowMargin : 0
        return CGRect(x: island.minX - margin, y: island.minY - margin,
                      width: island.width + 2 * margin, height: island.height + margin)
    }

    private func updateTracking() {
        let rect = islandRect(for: model.state).offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        container.setTrackingRect(rect)
    }

    private func screensChanged() {
        model.geometry = .detect()
        shrinkWork?.cancel()
        panel.setFrame(windowRect(for: model.state), display: true)
        updateTracking()
        panel.orderFrontRegardless()
    }
}
