//
//  vibecoder — interactive CLI (C1).
//  Does not replace eval-runner.
//

import Foundation
import AgentCore
import VibeCoderCLILib

@main
struct VibeCoderCLI {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.contains(where: { $0 == "-h" || $0 == "--help" || $0 == "help" }) {
            fputs(CLIArgs.usage() + "\n", stdout)
            return
        }
        let args: CLIArgs
        do {
            args = try CLIArgs.parse(argv)
        } catch CLIArgsError.badValue("help") {
            fputs(CLIArgs.usage() + "\n", stdout)
            return
        } catch {
            fputs("vibecoder: \(error)\n\(CLIArgs.usage())\n", stderr)
            exit(2)
        }
        var settings = await SettingsStore.shared.current()
        if let backend = args.backend {
            settings.backend = backend
        }
        do {
            try await REPL(store: .shared, settings: settings, args: args).run()
        } catch {
            fputs("vibecoder: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
