import Foundation
import MCP

// Entry point
let server = await NtucoolMCPServer()
try await server.run()
