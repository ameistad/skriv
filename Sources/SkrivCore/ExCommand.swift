import Foundation

/// Only whole-document lifecycle commands are supported. Never interpret a
/// filename, range, shell command, or command chain as a partial match.
enum ExCommand: Equatable {
    case write
    case quit(force: Bool)
    case writeQuit
    case exit

    init?(_ input: String) {
        switch input.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "w", "write": self = .write
        case "q", "quit": self = .quit(force: false)
        case "q!", "quit!": self = .quit(force: true)
        case "wq": self = .writeQuit
        case "x", "xit", "exit": self = .exit
        default: return nil
        }
    }
}
