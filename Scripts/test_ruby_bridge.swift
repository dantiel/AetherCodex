#!/usr/bin/env swift
import Foundation

let rubyPath = "/Users/d/.rvm/rubies/ruby-3.1.7/bin/ruby"
let scriptPath = FileManager.default.currentDirectoryPath + "/AetherOracle/ruby/standalone_daemon.rb"

print("[TEST] Ruby path: \(rubyPath)")
print("[TEST] Script path: \(scriptPath)")

// Check if files exist
let fileManager = FileManager.default
print("[TEST] Ruby exists: \(fileManager.isExecutableFile(atPath: rubyPath))")
print("[TEST] Script exists: \(fileManager.fileExists(atPath: scriptPath))")

let process = Process()
process.executableURL = URL(fileURLWithPath: rubyPath)
process.arguments = [scriptPath]

let stdinPipe = Pipe()
let stdoutPipe = Pipe()
let stderrPipe = Pipe()

process.standardInput = stdinPipe
process.standardOutput = stdoutPipe
process.standardError = stderrPipe

print("[TEST] Launching process...")

do {
    try process.run()
    print("[TEST] Process launched successfully!")
    print("[TEST] Process is running: \(process.isRunning)")
    
    // Send ping command
    let pingCommand = "{\"command\":\"ping\"}\n"
    let pingData = pingCommand.data(using: .utf8)!
    stdinPipe.fileHandleForWriting.write(pingData)
    
    // Read response
    Thread.sleep(forTimeInterval: 1.0)
    
    let outputData = stdoutPipe.fileHandleForReading.availableData
    if !outputData.isEmpty {
        let output = String(data: outputData, encoding: .utf8)
        print("[TEST] Output: \(output ?? "nil")")
    }
    
    // Read stderr
    let errorData = stderrPipe.fileHandleForReading.availableData
    if !errorData.isEmpty {
        let error = String(data: errorData, encoding: .utf8)
        print("[TEST] Error: \(error ?? "nil")")
    }
    
    process.terminate()
    print("[TEST] Done!")
} catch {
    print("[TEST] Failed: \(error)")
}
