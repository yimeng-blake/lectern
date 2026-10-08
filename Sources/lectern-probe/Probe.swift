import Foundation
import LecternCore

// Headless harness for exercising LecternCore without the GUI.
// Usage: lectern-probe <command> [options]
// Each backend file registers its commands in `probeCommands` via the extensions below.

struct ProbeCommand {
    let name: String
    let help: String
    let run: @MainActor ([String]) async -> Int32
}

@MainActor
func allProbeCommands() -> [ProbeCommand] {
    claudeProbeCommands() + codexProbeCommands() + grokProbeCommands() + contextProbeCommands() + e2eProbeCommands() + localProbeCommands()
}

/// `--key value` style option lookup.
func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func flag(_ name: String, in args: [String]) -> Bool { args.contains("--\(name)") }

/// First argument that is not an option or an option's value.
func positional(_ args: [String], valueOptions: Set<String>) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            if valueOptions.contains(String(a.dropFirst(2))) { i += 2 } else { i += 1 }
            continue
        }
        out.append(a)
        i += 1
    }
    return out
}

@main
struct Probe {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let commands = allProbeCommands()
        guard let name = args.first, let cmd = commands.first(where: { $0.name == name }) else {
            print("usage: lectern-probe <command> [options]\n")
            for c in commands { print("  \(c.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(c.help)") }
            exit(2)
        }
        let status = await cmd.run(Array(args.dropFirst()))
        exit(status)
    }
}
