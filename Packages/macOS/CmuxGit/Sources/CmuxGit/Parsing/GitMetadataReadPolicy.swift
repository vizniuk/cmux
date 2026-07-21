import Foundation

/// Bounded parsing policy for Git metadata used to derive branch display state.
struct GitMetadataReadPolicy: Sendable {
    static let maximumFileBytes = 1 * 1024 * 1024
    static let maximumSymbolicRefBytes = 4_096
    static let maximumDisplayBranchBytes = 1_024

    private static let readChunkBytes = 64 * 1024
    private static let forbiddenRefCharacters = CharacterSet(charactersIn: " ~^:?*[\\")

    /// Reads one metadata file without allocating or examining more than the policy ceiling.
    static func readFile(at url: URL) -> Data? {
        let fileManager = FileManager.default
        let initialSize: Int?
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            guard let number = attributes[.size] as? NSNumber,
                  number.int64Value >= 0,
                  number.uint64Value <= UInt64(Int.max) else {
                return nil
            }
            initialSize = Int(number.uint64Value)
            guard initialSize! <= maximumFileBytes else { return nil }
        } else {
            initialSize = nil
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        if let initialSize {
            data.reserveCapacity(initialSize)
        }
        while true {
            let remaining = maximumFileBytes - data.count
            let requestedBytes = remaining == 0 ? 1 : min(readChunkBytes, remaining)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: requestedBytes) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }
            let (newCount, overflow) = data.count.addingReportingOverflow(chunk.count)
            guard !overflow, newCount <= maximumFileBytes else { return nil }
            data.append(chunk)
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            guard let number = attributes[.size] as? NSNumber,
                  number.int64Value >= 0,
                  number.uint64Value <= UInt64(Int.max) else {
                return nil
            }
            let finalSize = Int(number.uint64Value)
            guard finalSize <= maximumFileBytes,
                  finalSize == data.count,
                  initialSize == nil || initialSize == finalSize else {
                return nil
            }
        } else if initialSize != nil {
            return nil
        }
        return data
    }

    /// Reads one strict UTF-8 metadata file under the shared byte ceiling.
    static func readString(at url: URL) -> String? {
        guard let data = readFile(at: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Accepts one metadata line with at most one terminal LF and no controls.
    static func metadataLine(_ contents: String) -> String? {
        var value = contents
        if value.hasSuffix("\n") {
            value.removeLast()
        }
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    /// Validates a complete symbolic ref without truncating it.
    static func symbolicRef(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= maximumSymbolicRefBytes,
              value.hasPrefix("refs/"),
              value != "@",
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.hasSuffix("."),
              !value.contains("//"),
              !value.contains(".."),
              !value.contains("@{"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.newlines.contains($0)
                      || forbiddenRefCharacters.contains($0)
              }) else {
            return nil
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && !component.hasPrefix(".")
                      && !component.hasSuffix(".")
                      && !component.hasSuffix(".lock")
              }) else {
            return nil
        }
        return value
    }

    /// Validates the exact user-visible suffix of a `refs/heads/` ref.
    static func displayBranch(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= maximumDisplayBranchBytes,
              !value.hasPrefix("-"),
              symbolicRef("refs/heads/\(value)") != nil else {
            return nil
        }
        return value
    }

    /// Accepts full SHA-1 and SHA-256 object IDs only.
    static func objectID(_ value: String) -> String? {
        guard value.utf8.count == 40 || value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...70).contains(byte)
                      || (97...102).contains(byte)
              }) else {
            return nil
        }
        return value.lowercased()
    }

    /// Parses a complete bounded `packed-refs` file and returns one validated target.
    static func packedRefValue(in contents: String, matching refName: String) -> String? {
        guard symbolicRef(refName) != nil,
              !contents.unicodeScalars.contains(where: { scalar in
                  scalar.value != 0x0A && CharacterSet.controlCharacters.contains(scalar)
              }) else {
            return nil
        }

        var matchedValue: String?
        var sawPackedRef = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("^") {
                guard sawPackedRef, objectID(String(line.dropFirst())) != nil else { return nil }
                continue
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let objectID = objectID(String(parts[0])),
                  symbolicRef(String(parts[1])) != nil else {
                return nil
            }
            sawPackedRef = true
            if parts[1] == refName {
                guard matchedValue == nil else { return nil }
                matchedValue = objectID
            }
        }
        return matchedValue
    }
}
