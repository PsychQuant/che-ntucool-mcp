import ArgumentParser
import CheNtucoolCore

/// `che-ntucool` — command-line front end to NTU COOL (Canvas LMS).
///
/// Placeholder for the first slice of PsychQuant/che-ntucool-mcp#1: the
/// package structure and the transport ladder land first, the subcommands
/// (`state`, `module`, `quiz`, `assignment`, `announce`, `enroll`) follow in
/// the second slice. Until then the binary only prints its usage.
struct CheNtucool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "che-ntucool",
        abstract: "Command-line client for NTU COOL (Canvas LMS) at cool.ntu.edu.tw.",
        discussion: "Subcommands are not implemented yet; see PsychQuant/che-ntucool-mcp#1."
    )

    func run() throws {
        print(Self.helpMessage())
    }
}

CheNtucool.main()
