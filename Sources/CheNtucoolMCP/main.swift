import Foundation
import MCP
import CheNtucoolCore

// Entry point
let server = await NtucoolMCPServer()
try await server.run()
