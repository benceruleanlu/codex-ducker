import Foundation

private let logDateFormatter = ISO8601DateFormatter()

func duckerLog(_ message: String) {
    let line = "[Ducker] \(logDateFormatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
