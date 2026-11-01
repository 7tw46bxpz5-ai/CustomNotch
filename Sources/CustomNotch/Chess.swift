import AppKit
import SwiftUI

// MARK: - Rules

enum ChessSide: String, Codable {
    case white, black

    var opposite: ChessSide { self == .white ? .black : .white }
    var name: String { self == .white ? "White" : "Black" }
}

enum ChessPieceKind: Character, CaseIterable {
    case pawn = "p", knight = "n", bishop = "b", rook = "r", queen = "q", king = "k"

    /// The letter in algebraic notation (none for pawns).
    var sanLetter: String { self == .pawn ? "" : String(rawValue).uppercased() }
}

struct ChessPiece: Equatable {
    var kind: ChessPieceKind
    var side: ChessSide

    init(_ kind: ChessPieceKind, _ side: ChessSide) {
        self.kind = kind
        self.side = side
    }

    init?(fen character: Character) {
        guard let kind = ChessPieceKind(rawValue: Character(character.lowercased())) else { return nil }
        self.init(kind, character.isUppercase ? .white : .black)
    }

    var fenCharacter: Character {
        side == .white ? Character(String(kind.rawValue).uppercased()) : kind.rawValue
    }
}

/// Squares are 0…63: a1 = 0, h1 = 7, a8 = 56, h8 = 63.
struct ChessMove: Hashable {
    var from: Int
    var to: Int
    var promotion: ChessPieceKind? = nil

    var uci: String { Chess.name(from) + Chess.name(to) + (promotion.map { String($0.rawValue) } ?? "") }

    init(from: Int, to: Int, promotion: ChessPieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    init?(uci: String) {
        let text = uci.lowercased()
        guard text.count == 4 || text.count == 5,
              let from = Chess.square(named: String(text.prefix(2))),
              let to = Chess.square(named: String(text.dropFirst(2).prefix(2))) else { return nil }
        var promotion: ChessPieceKind?
        if text.count == 5 {
            guard let kind = ChessPieceKind(rawValue: text.last!), kind != .pawn, kind != .king else { return nil }
            promotion = kind
        }
        self.init(from: from, to: to, promotion: promotion)
    }
}

enum Chess {
    static func name(_ square: Int) -> String {
        let files = Array("abcdefgh")
        return "\(files[square % 8])\(square / 8 + 1)"
    }

    static func square(named name: String) -> Int? {
        let chars = Array(name)
        guard chars.count == 2, let file = "abcdefgh".firstIndex(of: chars[0]),
              let rank = chars[1].wholeNumberValue, (1...8).contains(rank) else { return nil }
        return (rank - 1) * 8 + "abcdefgh".distance(from: "abcdefgh".startIndex, to: file)
    }
}

/// A full chess position, with legal move generation (castling, en passant, promotion, pins and checks).
struct ChessPosition: Equatable {
    var board: [ChessPiece?] = Array(repeating: nil, count: 64)
    var turn: ChessSide = .white
    var castling: Set<Character> = []       // K Q k q
    var enPassant: Int?
    var halfmove = 0
    var fullmove = 1

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let start = ChessPosition(fen: startFEN)!

    init() {}

    init?(fen: String) {
        let parts = fen.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let rows = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { return nil }
        for (index, row) in rows.enumerated() {
            let rank = 7 - index
            var file = 0
            for character in row {
                if let empty = character.wholeNumberValue {
                    file += empty
                } else {
                    guard file < 8, let piece = ChessPiece(fen: character) else { return nil }
                    board[rank * 8 + file] = piece
                    file += 1
                }
            }
            guard file == 8 else { return nil }
        }
        turn = parts[1] == "b" ? .black : .white
        castling = parts[2] == "-" ? [] : Set(parts[2])
        enPassant = parts[3] == "-" ? nil : Chess.square(named: String(parts[3]))
        halfmove = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        fullmove = parts.count > 5 ? Int(parts[5]) ?? 1 : 1
    }

    var fen: String {
        var rows: [String] = []
        for rank in (0..<8).reversed() {
            var row = "", empty = 0
            for file in 0..<8 {
                if let piece = board[rank * 8 + file] {
                    if empty > 0 { row += "\(empty)"; empty = 0 }
                    row.append(piece.fenCharacter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += "\(empty)" }
            rows.append(row)
        }
        let rights = "KQkq".filter { castling.contains($0) }
        return "\(rows.joined(separator: "/")) \(turn == .white ? "w" : "b") \(rights.isEmpty ? "-" : rights) "
            + "\(enPassant.map(Chess.name) ?? "-") \(halfmove) \(fullmove)"
    }

    /// Pieces, side to move, castling and en passant: what counts for a repeated position.
    var repetitionKey: String { fen.split(separator: " ").prefix(4).joined(separator: " ") }

    /// The board as text for the prompt: rank 8 at the top, uppercase = White.
    var diagram: String {
        var lines: [String] = []
        for rank in (0..<8).reversed() {
            let squares = (0..<8).map { file in board[rank * 8 + file].map { String($0.fenCharacter) } ?? "." }
            lines.append("\(rank + 1)  " + squares.joined(separator: " "))
        }
        lines.append("   a b c d e f g h")
        return lines.joined(separator: "\n")
    }

    // MARK: Moves

    private static let knightSteps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingSteps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let straight = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let diagonal = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    private static func offset(_ square: Int, _ df: Int, _ dr: Int) -> Int? {
        let file = square % 8 + df, rank = square / 8 + dr
        return (0..<8).contains(file) && (0..<8).contains(rank) ? rank * 8 + file : nil
    }

    func legalMoves() -> [ChessMove] {
        pseudoMoves().filter { move in
            let next = applying(move)
            guard let king = next.kingSquare(of: turn) else { return false }
            return !next.isAttacked(king, by: turn.opposite)
        }
    }

    private func pseudoMoves() -> [ChessMove] {
        var moves: [ChessMove] = []
        for square in 0..<64 {
            guard let piece = board[square], piece.side == turn else { continue }
            switch piece.kind {
            case .pawn: pawnMoves(from: square, into: &moves)
            case .knight: steps(from: square, Self.knightSteps, into: &moves)
            case .bishop: slides(from: square, Self.diagonal, into: &moves)
            case .rook: slides(from: square, Self.straight, into: &moves)
            case .queen: slides(from: square, Self.straight + Self.diagonal, into: &moves)
            case .king:
                steps(from: square, Self.kingSteps, into: &moves)
                castlingMoves(from: square, into: &moves)
            }
        }
        return moves
    }

    private func pawnMoves(from square: Int, into moves: inout [ChessMove]) {
        let dir = turn == .white ? 1 : -1
        let startRank = turn == .white ? 1 : 6
        let lastRank = turn == .white ? 7 : 0
        func add(_ to: Int) {
            if to / 8 == lastRank {
                for kind in [ChessPieceKind.queen, .rook, .bishop, .knight] {
                    moves.append(ChessMove(from: square, to: to, promotion: kind))
                }
            } else {
                moves.append(ChessMove(from: square, to: to))
            }
        }
        if let one = Self.offset(square, 0, dir), board[one] == nil {
            add(one)
            if square / 8 == startRank, let two = Self.offset(square, 0, 2 * dir), board[two] == nil {
                moves.append(ChessMove(from: square, to: two))
            }
        }
        for df in [-1, 1] {
            guard let target = Self.offset(square, df, dir) else { continue }
            if let piece = board[target] {
                if piece.side != turn { add(target) }
            } else if target == enPassant {
                moves.append(ChessMove(from: square, to: target))
            }
        }
    }

    private func steps(from square: Int, _ deltas: [(Int, Int)], into moves: inout [ChessMove]) {
        for (df, dr) in deltas {
            if let target = Self.offset(square, df, dr), board[target]?.side != turn {
                moves.append(ChessMove(from: square, to: target))
            }
        }
    }

    private func slides(from square: Int, _ directions: [(Int, Int)], into moves: inout [ChessMove]) {
        for (df, dr) in directions {
            var current = square
            while let target = Self.offset(current, df, dr) {
                if let piece = board[target] {
                    if piece.side != turn { moves.append(ChessMove(from: square, to: target)) }
                    break
                }
                moves.append(ChessMove(from: square, to: target))
                current = target
            }
        }
    }

    /// Not out of, through or into check; the squares between king and rook must be empty.
    private func castlingMoves(from square: Int, into moves: inout [ChessMove]) {
        let base = turn == .white ? 0 : 56
        guard square == base + 4 else { return }
        let (kingSide, queenSide): (Character, Character) = turn == .white ? ("K", "Q") : ("k", "q")
        guard castling.contains(kingSide) || castling.contains(queenSide) else { return }
        let enemy = turn.opposite
        guard !isAttacked(square, by: enemy) else { return }
        let rook = ChessPiece(.rook, turn)
        if castling.contains(kingSide), board[base + 5] == nil, board[base + 6] == nil, board[base + 7] == rook,
           !isAttacked(base + 5, by: enemy), !isAttacked(base + 6, by: enemy) {
            moves.append(ChessMove(from: square, to: base + 6))
        }
        if castling.contains(queenSide), board[base + 3] == nil, board[base + 2] == nil, board[base + 1] == nil,
           board[base] == rook, !isAttacked(base + 3, by: enemy), !isAttacked(base + 2, by: enemy) {
            moves.append(ChessMove(from: square, to: base + 2))
        }
    }

    func isAttacked(_ square: Int, by side: ChessSide) -> Bool {
        // A pawn of `side` attacks diagonally forward, so look one rank back from its point of view.
        let back = side == .white ? -1 : 1
        for df in [-1, 1] {
            if let from = Self.offset(square, df, back), board[from] == ChessPiece(.pawn, side) { return true }
        }
        for (df, dr) in Self.knightSteps {
            if let from = Self.offset(square, df, dr), board[from] == ChessPiece(.knight, side) { return true }
        }
        for (df, dr) in Self.kingSteps {
            if let from = Self.offset(square, df, dr), board[from] == ChessPiece(.king, side) { return true }
        }
        for (directions, slider) in [(Self.straight, ChessPieceKind.rook), (Self.diagonal, .bishop)] {
            for (df, dr) in directions {
                var current = square
                while let from = Self.offset(current, df, dr) {
                    if let piece = board[from] {
                        if piece.side == side && (piece.kind == slider || piece.kind == .queen) { return true }
                        break
                    }
                    current = from
                }
            }
        }
        return false
    }

    func kingSquare(of side: ChessSide) -> Int? { board.firstIndex(of: ChessPiece(.king, side)) }

    var inCheck: Bool { kingSquare(of: turn).map { isAttacked($0, by: turn.opposite) } ?? false }

    func applying(_ move: ChessMove) -> ChessPosition {
        guard let piece = board[move.from] else { return self }
        var next = self
        let captured = board[move.to]
        let enPassantCapture = piece.kind == .pawn && move.to == enPassant && captured == nil && move.from % 8 != move.to % 8
        next.board[move.from] = nil
        next.board[move.to] = move.promotion.map { ChessPiece($0, piece.side) } ?? piece
        if enPassantCapture {
            next.board[move.to + (piece.side == .white ? -8 : 8)] = nil
        }
        if piece.kind == .king, abs(move.to - move.from) == 2 {
            let base = move.from - move.from % 8
            let (rookFrom, rookTo) = move.to % 8 == 6 ? (base + 7, base + 5) : (base, base + 3)
            next.board[rookTo] = next.board[rookFrom]
            next.board[rookFrom] = nil
        }
        if piece.kind == .king {
            next.castling.subtract(piece.side == .white ? ["K", "Q"] : ["k", "q"])
        }
        for square in [move.from, move.to] {
            switch square {
            case 0: next.castling.remove("Q")
            case 7: next.castling.remove("K")
            case 56: next.castling.remove("q")
            case 63: next.castling.remove("k")
            default: break
            }
        }
        next.enPassant = piece.kind == .pawn && abs(move.to - move.from) == 16 ? (move.from + move.to) / 2 : nil
        next.halfmove = piece.kind == .pawn || captured != nil ? 0 : halfmove + 1
        if turn == .black { next.fullmove += 1 }
        next.turn = turn.opposite
        return next
    }

    /// Standard algebraic notation (Nf3, exd5, O-O, e8=Q+), read from the position before the move.
    func san(_ move: ChessMove) -> String {
        guard let piece = board[move.from] else { return move.uci }
        var text: String
        if piece.kind == .king, abs(move.to - move.from) == 2 {
            text = move.to % 8 == 6 ? "O-O" : "O-O-O"
        } else {
            let capture = board[move.to] != nil || (piece.kind == .pawn && move.from % 8 != move.to % 8)
            let fromName = Chess.name(move.from)
            if piece.kind == .pawn {
                text = capture ? "\(fromName.first!)x" : ""
            } else {
                text = piece.kind.sanLetter
                let rivals = legalMoves().filter { $0.to == move.to && $0.from != move.from && board[$0.from] == piece }
                if !rivals.isEmpty {
                    let sameFile = rivals.contains { $0.from % 8 == move.from % 8 }
                    let sameRank = rivals.contains { $0.from / 8 == move.from / 8 }
                    if !sameFile { text += String(fromName.first!) }
                    else if !sameRank { text += String(fromName.last!) }
                    else { text += fromName }
                }
                if capture { text += "x" }
            }
            text += Chess.name(move.to)
            if let promotion = move.promotion { text += "=" + promotion.sanLetter }
        }
        let next = applying(move)
        if next.inCheck { text += next.legalMoves().isEmpty ? "#" : "+" }
        return text
    }

    /// King against king, or king and one bishop or knight against a bare king.
    var insufficientMaterial: Bool {
        let others = board.compactMap { $0 }.filter { $0.kind != .king }
        return others.isEmpty || (others.count == 1 && (others[0].kind == .bishop || others[0].kind == .knight))
    }

    /// Counts the leaf positions `depth` moves deep (for testing the move generator).
    func perft(_ depth: Int) -> Int {
        let moves = legalMoves()
        if depth <= 1 { return depth == 1 ? moves.count : 1 }
        return moves.reduce(0) { $0 + applying($1).perft(depth - 1) }
    }
}

enum ChessOutcome: Equatable {
    case checkmate(winner: ChessSide)
    case resigned(winner: ChessSide)
    case stalemate, repetition, fiftyMoves, material

    func text(player: ChessSide) -> String {
        switch self {
        case .checkmate(let winner): return winner == player ? "Checkmate. You win!" : "Checkmate. Claude wins."
        case .resigned(let winner): return winner == player ? "Claude resigned. You win!" : "You resigned. Claude wins."
        case .stalemate: return "Stalemate. It's a draw."
        case .repetition: return "Draw by repetition."
        case .fiftyMoves: return "Draw: 50 moves without a capture or pawn move."
        case .material: return "Draw: not enough material to mate."
        }
    }
}

// MARK: - Opponent

/// Which Claude model plays against you, through your own Claude Code login.
enum ChessOpponent: String, CaseIterable {
    case haiku, sonnet, opus

    var model: String { rawValue }
    var name: String { "Claude \(rawValue.capitalized)" }

    var menuTitle: String {
        switch self {
        case .haiku: return "Claude Haiku (fastest)"
        case .sonnet: return "Claude Sonnet"
        case .opus: return "Claude Opus (strongest)"
        }
    }
}

/// Asks Claude for a move with the `claude` command of Claude Code (print mode), so it uses your own login and
/// plan. Safe mode keeps your hooks, MCP servers and CLAUDE.md out, and no tools are allowed: Claude only answers
/// with a move. The answer is always checked against the legal moves.
enum ClaudeChessPlayer {
    struct Choice {
        var move: ChessMove
        var note: String?
    }

    struct Failure: Error {
        var message: String
    }

    static func chooseMove(position: ChessPosition, history: [String], model: String) async -> Result<Choice, Failure> {
        let legal = position.legalMoves()
        guard !legal.isEmpty else { return .failure(Failure(message: "There is no legal move.")) }
        let side = position.turn
        let system = """
            You are playing a casual game of chess as \(side.name) against the user, inside a small Mac app. \
            Play good, sound chess. Answer with your move only, in UCI notation (from-square, to-square, and a \
            promotion letter if any, e.g. e7e5, g8f6, e7e8q). It must be one of the legal moves you are given. \
            No other text.
            """
        var prompt = Self.prompt(position: position, history: history, legal: legal)
        for _ in 0..<2 {
            let output: String
            do {
                output = try await run(prompt: prompt, system: system, model: model)
            } catch let failure as Failure {
                return .failure(failure)
            } catch {
                return .failure(Failure(message: error.localizedDescription))
            }
            if let move = parse(output, legal: legal, position: position) {
                return .success(Choice(move: move))
            }
            let answer = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
            prompt += "\n\nYour previous answer \"\(answer)\" is not one of the legal moves. "
                + "Reply with exactly one move from the list above, nothing else."
        }
        return .success(Choice(move: legal.randomElement()!,
                               note: "Claude's answer wasn't a legal move, so it played a random one."))
    }

    static func prompt(position: ChessPosition, history: [String], legal: [ChessMove]) -> String {
        var moves: [String] = []
        for (index, san) in history.enumerated() {
            moves.append(index % 2 == 0 ? "\(index / 2 + 1). \(san)" : san)
        }
        return """
            You are \(position.turn.name). It is your move.

            Position (FEN): \(position.fen)

            Board (uppercase = White, lowercase = Black):
            \(position.diagram)

            Moves so far: \(moves.isEmpty ? "none, this is the first move" : moves.joined(separator: " "))
            \(position.inCheck ? "You are in check.\n" : "")
            Your legal moves (UCI): \(legal.map(\.uci).joined(separator: " "))
            """
    }

    /// The last word of the answer that is a legal move, in UCI ("e7e5", "e7e8q") or algebraic notation ("Nf6").
    static func parse(_ text: String, legal: [ChessMove], position: ChessPosition) -> ChessMove? {
        func normalized(_ san: String) -> String {
            san.replacingOccurrences(of: "0-0", with: "O-O").filter { !"+#!?=".contains($0) }
        }
        var bySAN: [String: ChessMove] = [:]
        for move in legal where bySAN[normalized(position.san(move))] == nil {
            bySAN[normalized(position.san(move))] = move
        }
        let words = text.split { $0.isWhitespace || ",;:()[]{}\"'`*".contains($0) }
        for word in words.reversed() {
            var token = String(word)
            // "12." or "12...e5": drop the move number.
            if let range = token.range(of: #"^\d+\.+"#, options: .regularExpression) { token.removeSubrange(range) }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            guard !token.isEmpty else { continue }
            let lower = token.lowercased().replacingOccurrences(of: "-", with: "")
            if let move = legal.first(where: { $0.uci == lower }) { return move }
            if lower.count == 4, let move = legal.first(where: { $0.uci == lower + "q" }) { return move }
            if let move = bySAN[normalized(token)] { return move }
        }
        return nil
    }

    /// Where Claude Code is installed. Apps opened from the Finder don't get your shell's PATH, so look in the
    /// usual places (the native installer's ~/.local/bin first).
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The working folder for the `claude` process, so it never starts inside one of your projects.
    private static var workingFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Custom Notch/Chess", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private final class Run: @unchecked Sendable {
        let process = Process()
        let lock = NSLock()
        var timedOut = false

        func stop(timedOut: Bool = false) {
            lock.lock()
            if timedOut { self.timedOut = true }
            lock.unlock()
            if process.isRunning { process.terminate() }
        }
    }

    static func run(prompt: String, system: String, model: String, timeout: TimeInterval = 90) async throws -> String {
        guard let executable = executable() else {
            throw Failure(message: "Claude Code isn't installed: no claude command in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.")
        }
        let run = Run()
        let process = run.process
        process.executableURL = executable
        // The prompt goes in on stdin: --tools takes a list, so it would swallow an argument after it.
        process.arguments = ["-p", "--safe-mode", "--model", model, "--effort", "low", "--no-session-persistence",
                             "--system-prompt", system, "--tools", ""]
        process.currentDirectoryURL = workingFolder
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        let paths = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (paths + [environment["PATH"]].compactMap { $0 }).joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: Failure(message: "Couldn't start Claude Code: \(error.localizedDescription)"))
                        return
                    }
                    input.fileHandleForWriting.write(Data(prompt.utf8))
                    try? input.fileHandleForWriting.close()
                    let deadline = DispatchWorkItem { run.stop(timedOut: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                    // Read both pipes at once, so neither can fill up and block the process.
                    var errorData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errorData = errors.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outputData = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    deadline.cancel()

                    let text = String(decoding: outputData, as: UTF8.self)
                    run.lock.lock()
                    let timedOut = run.timedOut
                    run.lock.unlock()
                    if timedOut {
                        continuation.resume(throwing: Failure(message: "Claude took too long to answer."))
                    } else if process.terminationStatus != 0 {
                        let detail = (String(decoding: errorData, as: UTF8.self) + "\n" + text)
                            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                            .first { !$0.isEmpty } ?? "exit code \(process.terminationStatus)"
                        continuation.resume(throwing: Failure(message: "Claude Code: \(detail)"))
                    } else {
                        continuation.resume(returning: text)
                    }
                }
            }
        } onCancel: {
            run.stop()
        }
    }
}

// MARK: - Game

/// The game against Claude. It lives outside the island, so it carries on while the island is closed, and it is
/// saved (as its moves) so it survives a restart.
@MainActor @Observable
final class ChessGame {
    private(set) var position = ChessPosition.start
    private(set) var moves: [ChessMove] = []
    private(set) var sans: [String] = []
    private(set) var player: ChessSide = .white
    private(set) var outcome: ChessOutcome?
    private(set) var selected: Int?
    private(set) var thinking = false
    /// Claude couldn't answer (not logged in, not installed, timed out): shown with a Retry button.
    private(set) var problem: String?
    /// Something worth knowing about Claude's last move.
    private(set) var note: String?

    /// Claude made a move: its notation. The app shows a bubble if the board isn't open.
    @ObservationIgnored var onClaudeMoved: ((String) -> Void)?
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var resigned = false

    private static let savedKey = "chessGame"

    private struct Saved: Codable {
        var player: ChessSide
        var moves: [String]
        var resigned: Bool
    }

    init(settings: Settings) {
        self.settings = settings
        persists = true
        if let string = UserDefaults.standard.string(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: Data(string.utf8)) {
            player = saved.player
            replay(saved.moves.compactMap(ChessMove.init(uci:)))
            if saved.resigned, outcome == nil {
                resigned = true
                outcome = .resigned(winner: player.opposite)
            }
        }
    }

    /// For the snapshots: a game after these moves, nothing saved and Claude never asked.
    init(settings: Settings, preview moves: [String], player: ChessSide = .white, selected: String? = nil,
         thinking: Bool = false) {
        self.settings = settings
        persists = false
        self.player = player
        replay(moves.compactMap(ChessMove.init(uci:)))
        self.selected = selected.flatMap(Chess.square(named:))
        self.thinking = thinking
    }

    var opponent: ChessOpponent { settings.chessOpponent }
    var legalMoves: [ChessMove] { position.legalMoves() }
    var lastMove: ChessMove? { moves.last }
    var isPlayersTurn: Bool { outcome == nil && position.turn == player }
    var targets: [ChessMove] {
        guard let selected else { return [] }
        return legalMoves.filter { $0.from == selected }
    }
    /// Claude's last move, if it made the last one.
    var claudesLastMove: String? { position.turn == player ? sans.last : nil }
    var canUndo: Bool { moves.count >= (player == .white ? 1 : 2) }

    // MARK: Playing

    func tap(_ square: Int) {
        guard isPlayersTurn, !thinking else { return }
        let legal = legalMoves
        if let from = selected {
            // Promotion always makes a queen.
            if let move = legal.first(where: { $0.from == from && $0.to == square && ($0.promotion ?? .queen) == .queen }) {
                selected = nil
                play(move)
                askClaudeIfNeeded()
                return
            }
            if from == square {
                selected = nil
                return
            }
        }
        if position.board[square]?.side == player, legal.contains(where: { $0.from == square }) {
            selected = square
        } else {
            selected = nil
        }
    }

    func newGame(as side: ChessSide) {
        cancelRequest()
        player = side
        resigned = false
        replay([])
        save()
        askClaudeIfNeeded()
    }

    /// Takes back your last move (and Claude's answer to it).
    func undo() {
        guard canUndo else { return }
        cancelRequest()
        var remaining = moves
        remaining.removeLast()
        while !remaining.isEmpty, remaining.count % 2 == (player == .white ? 1 : 0) {
            remaining.removeLast()          // until it's your move again
        }
        resigned = false
        replay(remaining)
        save()
        askClaudeIfNeeded()
    }

    func resign() {
        guard outcome == nil else { return }
        cancelRequest()
        resigned = true
        outcome = .resigned(winner: player.opposite)
        selected = nil
        save()
    }

    func retry() {
        problem = nil
        askClaudeIfNeeded()
    }

    /// The board was opened: if Claude still owes a move (say, after a restart), ask now.
    func resume() {
        guard problem == nil else { return }
        askClaudeIfNeeded()
    }

    private func play(_ move: ChessMove) {
        sans.append(position.san(move))
        position = position.applying(move)
        moves.append(move)
        updateOutcome()
        save()
    }

    private func replay(_ list: [ChessMove]) {
        position = .start
        moves = []
        sans = []
        outcome = nil
        selected = nil
        problem = nil
        note = nil
        for move in list {
            guard position.legalMoves().contains(move) else { break }
            sans.append(position.san(move))
            position = position.applying(move)
            moves.append(move)
        }
        updateOutcome()
    }

    private func updateOutcome() {
        if resigned { outcome = .resigned(winner: player.opposite); return }
        if position.legalMoves().isEmpty {
            outcome = position.inCheck ? .checkmate(winner: position.turn.opposite) : .stalemate
        } else if position.halfmove >= 100 {
            outcome = .fiftyMoves
        } else if position.insufficientMaterial {
            outcome = .material
        } else if repetitions() >= 3 {
            outcome = .repetition
        } else {
            outcome = nil
        }
    }

    private func repetitions() -> Int {
        var current = ChessPosition.start
        var keys = [current.repetitionKey]
        for move in moves {
            current = current.applying(move)
            keys.append(current.repetitionKey)
        }
        return keys.filter { $0 == position.repetitionKey }.count
    }

    private func askClaudeIfNeeded() {
        guard outcome == nil, position.turn != player, !thinking, persists else { return }
        thinking = true
        problem = nil
        note = nil
        let asked = position
        let history = sans
        let model = opponent.model
        request = Task { [weak self] in
            let result = await ClaudeChessPlayer.chooseMove(position: asked, history: history, model: model)
            guard let self, !Task.isCancelled, self.position == asked else { return }
            self.thinking = false
            self.request = nil
            switch result {
            case .success(let choice):
                self.play(choice.move)
                self.note = choice.note
                if let san = self.sans.last { self.onClaudeMoved?(san) }
            case .failure(let failure):
                self.problem = failure.message
            }
        }
    }

    private func cancelRequest() {
        request?.cancel()
        request = nil
        thinking = false
    }

    private func save() {
        guard persists else { return }
        let saved = Saved(player: player, moves: moves.map(\.uci), resigned: resigned)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.savedKey)
        }
    }
}

// MARK: - Views

enum ChessLayout {
    static let square: CGFloat = 30
    static let sideWidth: CGFloat = 156
    static let spacing: CGFloat = 14
    static var board: CGFloat { square * 8 }
    static var width: CGFloat { 2 * Metrics.sidePadding + board + spacing + sideWidth }
    static var areaHeight: CGFloat { Metrics.topGap + board + Metrics.bottomPadding }
}

/// Wooden squares that go with the accent; the same in both themes.
private enum BoardColors {
    static let light = Color(hex: 0xEAD8C0)
    static let dark = Color(hex: 0xB3845A)
    static let lastMove = Color(hex: 0xE3C35A).opacity(0.55)
    static let selected = Color(hex: 0x935B29).opacity(0.6)
    static let check = Color(hex: 0xD9534F)
}

struct ChessPieceGlyph: View {
    let piece: ChessPiece
    let size: CGFloat

    private static let solid: [ChessPieceKind: String] = [.king: "♚", .queen: "♛", .rook: "♜", .bishop: "♝",
                                                          .knight: "♞", .pawn: "♟"]
    private static let outline: [ChessPieceKind: String] = [.king: "♔", .queen: "♕", .rook: "♖", .bishop: "♗",
                                                            .knight: "♘", .pawn: "♙"]

    var body: some View {
        // U+FE0E asks for the text glyph (♟ would otherwise be an emoji). White pieces: a white filled glyph
        // under the outlined one.
        let white = piece.side == .white
        ZStack {
            Text(Self.solid[piece.kind]! + "\u{FE0E}")
                .foregroundStyle(white ? Color.white : Color(hex: 0x1A1A1A))
            Text(Self.outline[piece.kind]! + "\u{FE0E}")
                .foregroundStyle(Color(hex: 0x1A1A1A))
        }
        .font(.system(size: size))
        .shadow(color: .black.opacity(0.22), radius: 0.6, y: 0.6)
    }
}

struct ChessBoardView: View {
    let game: ChessGame
    let square: CGFloat
    var interactive = true

    var body: some View {
        let flipped = game.player == .black
        let targets = interactive ? Set(game.targets.map(\.to)) : []
        let last = game.lastMove
        let position = game.position
        let check = position.inCheck ? position.kingSquare(of: position.turn) : nil
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { column in
                        let file = flipped ? 7 - column : column
                        let rank = flipped ? row : 7 - row
                        let index = rank * 8 + file
                        cell(index, light: (file + rank) % 2 == 1, piece: position.board[index],
                             highlighted: last.map { $0.from == index || $0.to == index } ?? false,
                             target: targets.contains(index), check: check == index,
                             rankLabel: column == 0 ? "\(rank + 1)" : nil,
                             fileLabel: row == 7 ? String(Array("abcdefgh")[file]) : nil)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: interactive ? 6 : 4, style: .continuous))
    }

    @ViewBuilder
    private func cell(_ index: Int, light: Bool, piece: ChessPiece?, highlighted: Bool, target: Bool, check: Bool,
                      rankLabel: String?, fileLabel: String?) -> some View {
        let content = ZStack {
            light ? BoardColors.light : BoardColors.dark
            if highlighted { BoardColors.lastMove }
            if game.selected == index && interactive { BoardColors.selected }
            if check {
                RadialGradient(colors: [BoardColors.check, BoardColors.check.opacity(0)], center: .center,
                               startRadius: 0, endRadius: square * 0.62)
            }
            if interactive {
                let labelColor = light ? BoardColors.dark : BoardColors.light
                if let rankLabel {
                    Text(rankLabel).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(labelColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(1.5)
                }
                if let fileLabel {
                    Text(fileLabel).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(labelColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 2)
                }
            }
            if let piece {
                ChessPieceGlyph(piece: piece, size: square * 0.84)
            }
            if target {
                if piece != nil {
                    Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: square * 0.09)
                } else {
                    Circle().fill(Color.black.opacity(0.24)).frame(width: square * 0.3, height: square * 0.3)
                }
            }
        }
        .frame(width: square, height: square)

        if interactive {
            Button { game.tap(index) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// The open board: the board on the left, the game on the right.
struct ChessView: View {
    let game: ChessGame
    let palette: Palette
    let notchHeight: CGFloat
    let close: () -> Void

    private let onBlack = Palette.darkMatte     // headings straight on the black island

    var body: some View {
        HStack(alignment: .top, spacing: ChessLayout.spacing) {
            ChessBoardView(game: game, square: ChessLayout.square)
            side
                .frame(width: ChessLayout.sideWidth, height: ChessLayout.board, alignment: .topLeading)
        }
        .padding(.horizontal, Metrics.sidePadding)
        .padding(.top, notchHeight + Metrics.topGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chess").font(.system(size: 13, weight: .semibold)).foregroundStyle(onBlack.text)
                    Text("You: \(game.player.name) · vs \(game.opponent.name)")
                        .font(.system(size: 10)).foregroundStyle(onBlack.secondary)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.secondary)
                        .frame(width: 20, height: 20)
                        .background(palette.control, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close (the game stays as it is)")
            }
            status
            moveList
            controls
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let outcome = game.outcome {
                label(symbol: "crown.fill", outcome.text(player: game.player), tint: palette.accent)
            } else if let problem = game.problem {
                Text(problem)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.critical)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                pill("Retry", symbol: "arrow.clockwise") { game.retry() }
            } else if game.thinking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Claude is thinking…").font(.system(size: 11.5, weight: .medium)).foregroundStyle(onBlack.text)
                }
            } else {
                label(symbol: "circle.fill", game.position.inCheck ? "Your move · Check!" : "Your move",
                      tint: game.position.inCheck ? palette.critical : palette.accent, small: true)
            }
            if game.outcome == nil, game.problem == nil, let san = game.claudesLastMove {
                Text("Claude played \(san)").font(.system(size: 10)).foregroundStyle(onBlack.secondary)
            }
            if let note = game.note {
                Text(note).font(.system(size: 9.5)).foregroundStyle(onBlack.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(symbol: String, _ text: String, tint: Color, small: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: small ? 6 : 10, weight: .bold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(onBlack.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var moveList: some View {
        let rows = stride(from: 0, to: game.sans.count, by: 2).map { index in
            (number: index / 2 + 1, white: game.sans[index], black: index + 1 < game.sans.count ? game.sans[index + 1] : "")
        }
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text(game.player == .white ? "You start. Pick a piece." : "Claude starts.")
                            .font(.system(size: 10.5)).foregroundStyle(palette.secondary)
                    }
                    ForEach(rows, id: \.number) { row in
                        HStack(spacing: 0) {
                            Text("\(row.number).").foregroundStyle(palette.secondary).frame(width: 24, alignment: .leading)
                            Text(row.white).foregroundStyle(palette.text).frame(width: 52, alignment: .leading)
                            Text(row.black).foregroundStyle(palette.text)
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .id(row.number)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: game.sans.count) {
                if let last = rows.last { proxy.scrollTo(last.number, anchor: .bottom) }
            }
            .onAppear {
                if let last = rows.last { proxy.scrollTo(last.number, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, palette.colorScheme)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                pill("Undo", symbol: "arrow.uturn.backward") { game.undo() }
                    .disabled(!game.canUndo)
                    .opacity(game.canUndo ? 1 : 0.45)
                pill("Resign", symbol: "flag.fill") { game.resign() }
                    .disabled(game.outcome != nil)
                    .opacity(game.outcome == nil ? 1 : 0.45)
            }
            HStack(spacing: 6) {
                Text("New:").font(.system(size: 10.5)).foregroundStyle(onBlack.secondary)
                pill("White", symbol: nil) { game.newGame(as: .white) }
                pill("Black", symbol: nil) { game.newGame(as: .black) }
            }
        }
    }

    private func pill(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(palette.control, in: Capsule())
            .environment(\.colorScheme, palette.colorScheme)
        }
        .buttonStyle(.plain)
    }
}

/// The tile: a small board with the state of the game; a click opens the big board.
struct ChessTile: View {
    let game: ChessGame
    let cells: Int
    let palette: Palette
    let open: () -> Void

    private var statusText: String {
        if let outcome = game.outcome { return outcome.text(player: game.player) }
        if game.problem != nil { return "Claude couldn't move" }
        if game.thinking { return "Claude is thinking…" }
        if game.moves.isEmpty { return "Play against Claude" }
        if let san = game.claudesLastMove { return "Claude played \(san). Your move" }
        return "Your move"
    }

    var body: some View {
        Button(action: open) {
            Group {
                if cells == 1 {
                    VStack(spacing: 4) {
                        ChessBoardView(game: game, square: 7, interactive: false)
                        Text("Chess").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ChessBoardView(game: game, square: 8.5, interactive: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chess").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                            Text(statusText).font(.system(size: 10.5)).foregroundStyle(palette.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(game.moves.isEmpty || game.outcome != nil ? "Play" : "Continue")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
