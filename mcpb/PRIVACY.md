# Privacy Policy

## Data Collection

This MCP server:
- Runs entirely locally on your Mac
- Does not collect or transmit any personal data to the developer or any third party
- Connects only to the NTU COOL (Canvas LMS) API endpoint you configure — no other network destination
- Does not connect to any other external server

## Credential Storage

The Canvas Personal Access Token used to authenticate with NTU COOL is stored
exclusively in the macOS login keychain (service `ntu-cool-canvas`). It is never
read from an environment variable, written to a config file, or logged.

## Data Storage

No course, assignment, submission, or roster data is cached or persisted by this
server beyond the lifetime of a single tool call — every query re-fetches live
data from NTU COOL.

## Scope

v0.1.0 is read-only. It cannot post grades, create announcements, or make any
other write to your NTU COOL account.

## Third-Party Services

This extension communicates only with the NTU COOL Canvas API
(`cool.ntu.edu.tw`) using the token you supply. It does not use any other
third-party service.

## Contact

For questions about this privacy policy, please open an issue at:
https://github.com/kiki830621/che-ntucool-mcp/issues
