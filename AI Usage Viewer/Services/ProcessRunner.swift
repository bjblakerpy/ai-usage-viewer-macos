// ProcessRunner.swift
// AI Usage Viewer

import Foundation

nonisolated enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    // Runs a command off the main thread and kills it if it overruns.
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    timeout: TimeInterval = 5) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                let stdin = input.map { _ in Pipe() }
                p.standardInput = stdin ?? FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if let stdin, let input {
                    stdin.fileHandleForWriting.write(input)
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Output(status: p.terminationStatus, stdout: data))
            }
        }
    }
}
