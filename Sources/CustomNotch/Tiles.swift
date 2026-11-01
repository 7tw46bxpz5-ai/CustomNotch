import SwiftUI

// MARK: - Grid

/// The tiles of the open island, in rows. Each tile is clipped to its own rounded rectangle.
struct ExpandedView: View {
    let model: IslandModel
    let services: Services
    let palette: Palette

    var body: some View {
        let rows = model.rows(for: model.settings.tiles)
        VStack(spacing: Metrics.gap) {
            if rows.isEmpty {
                Text("All tiles are hidden. Turn them on from the menu bar icon → Tiles.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.darkMatte.secondary)      // straight on the black island
                    .frame(height: Metrics.tileHeight)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Metrics.gap) {
                    ForEach(row) { tile in
                        TileContainer(tile: tile, model: model, palette: palette) {
                            TileContent(tile: tile, services: services, palette: palette)
                        }
                        .frame(width: Metrics.tileWidth(cells: tile.cells), height: Metrics.tileHeight)
                    }
                }
            }
        }
        .padding(.top, model.geometry.notch.height + Metrics.topGap)
    }
}

struct TileContainer<Content: View>: View {
    let tile: TileConfig
    let model: IslandModel
    let palette: Palette
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
        // Exact cell size: content that is too big gets clipped instead of stretching the tile.
        content
            .frame(width: Metrics.tileWidth(cells: tile.cells), height: Metrics.tileHeight, alignment: .topLeading)
            .background(palette.tile)
            .environment(\.colorScheme, palette.colorScheme)
            .clipShape(shape)
            .contentShape(shape)
            .contextMenu { TileMenu(tile: tile, model: model) }
    }
}

/// Right-click menu on a tile: size, position, hide.
struct TileMenu: View {
    let tile: TileConfig
    let model: IslandModel

    var body: some View {
        let tiles = model.settings.tiles
        ForEach(1...3, id: \.self) { cells in
            Toggle(cells == 1 ? "1 Cell" : "\(cells) Cells", isOn: Binding(
                get: { tile.cells == cells },
                set: { if $0 { model.applyTiles(tiles.setting(tile.kind, cells: cells)) } }))
        }
        Divider()
        Button("Move Left") { model.applyTiles(tiles.moving(tile.kind, by: -1)) }
            .disabled(!tiles.canMove(tile.kind, by: -1))
        Button("Move Right") { model.applyTiles(tiles.moving(tile.kind, by: 1)) }
            .disabled(!tiles.canMove(tile.kind, by: 1))
        Divider()
        Button("Hide \(tile.kind.title)") { model.applyTiles(tiles.setting(tile.kind, visible: false)) }
    }
}

struct TileContent: View {
    let tile: TileConfig
    let services: Services
    let palette: Palette

    var body: some View {
        switch tile.kind {
        case .weather:
            WeatherTile(weather: services.weather, cells: tile.cells, palette: palette, chooseCity: services.chooseCity)
        case .controls:
            ControlsTile(controls: services.controls, cells: tile.cells, palette: palette)
        case .music:
            MusicTile(music: services.music, cells: tile.cells, palette: palette)
        case .cards:
            CardsTile(services: services, cells: tile.cells, palette: palette)
        case .calendar:
            CalendarTile(calendar: services.calendar, cells: tile.cells, palette: palette)
        case .timer:
            FocusTimerTile(timer: services.timer, cells: tile.cells, palette: palette)
        case .chess:
            ChessTile(game: services.chess, cells: tile.cells, palette: palette, open: services.openChess)
        }
    }
}

/// Stand-in for tiles built in later steps.
struct PlaceholderTile: View {
    let title: String
    let note: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
            Text(note).font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared

/// A short explanation shown inside a tile, with an optional link to System Settings.
struct TileNotice: Equatable {
    var text: String
    var settings: URL?
}

struct NoticeView: View {
    let notice: TileNotice
    let palette: Palette
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(notice.text)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let url = notice.settings {
                Button { open(url) } label: {
                    Text("Open Settings")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
