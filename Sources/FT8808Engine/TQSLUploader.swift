import Foundation

/// Signs and uploads ADIF logs to ARRL Logbook of The World (LoTW) by shelling
/// out to the locally-installed TrustedQSL (`tqsl`) command-line tool.
///
/// We deliberately do **not** reimplement the X.509 / tQSL signing crypto:
/// `tqsl` already holds the operator's certificate, private key, and station
/// locations, and is the same path WSJT-X and N1MM use for LoTW upload. Shelling
/// out keeps FT8-808 MIT-clean (no linked GPL/crypto code) and reuses the
/// operator's existing, trusted setup. TQSL also keeps its own `uploaded.db`, so
/// with `-a compliant` it skips QSOs it has already sent — making per-QSO uploads
/// and retries idempotent (no double-submission).
public enum TQSLUploader {
    /// Where to look for the `tqsl` executable, in order. The macOS app bundle
    /// ships the CLI inside `Contents/MacOS`; Homebrew/MacPorts put it on PATH.
    public static let knownPaths = [
        "/Applications/TrustedQSL/tqsl.app/Contents/MacOS/tqsl",
        "/opt/homebrew/bin/tqsl",
        "/usr/local/bin/tqsl",
        "/usr/bin/tqsl",
    ]

    public enum Outcome: Sendable, Equatable {
        case uploaded(records: Int)   // QSOs signed and accepted by LoTW
        case nothingNew               // all QSOs were already uploaded (TQSL dedup)
        case failure(String)          // human-readable reason (surfaced to the user)
    }

    /// Resolve the `tqsl` executable: an explicit override first, then the
    /// well-known install locations, then `PATH`. Returns nil if not found.
    public static func resolveBinary(override: String? = nil) -> String? {
        let fm = FileManager.default
        if let o = override, !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }
        for p in knownPaths where fm.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/tqsl"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Where TrustedQSL keeps its data (`station_data`, certs, `uploaded.db`),
    /// in the order TQSL itself prefers on macOS.
    public static func dataDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".tqsl"),
            home.appendingPathComponent("Library/Preferences/tqslapp Preferences"),
            home.appendingPathComponent(".config/trustedqsl"),
        ]
    }

    /// The "Station Location" names the operator has configured in TrustedQSL,
    /// read from the local `station_data`. Empty if TQSL isn't set up. Used to
    /// offer a pick-list in Settings instead of making the user type the exact
    /// name (`tqsl -l` requires an exact match).
    public static func stationLocations() -> [String] {
        let fm = FileManager.default
        for dir in dataDirectories() {
            let url = dir.appendingPathComponent("station_data")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return parseStationLocations(from: text)
            }
            _ = fm  // keep dependency explicit; contentsOf already handles existence
        }
        return []
    }

    /// Extract `name="..."` values from a TQSL `station_data` XML document. Pure,
    /// so it can be unit-tested without a TQSL install.
    public static func parseStationLocations(from xml: String) -> [String] {
        var names: [String] = []
        let marker = "<StationData name=\""
        var idx = xml.startIndex
        while let r = xml.range(of: marker, range: idx..<xml.endIndex) {
            let valStart = r.upperBound
            guard let q = xml[valStart...].firstIndex(of: "\"") else { break }
            let name = String(xml[valStart..<q])
            if !name.isEmpty, !names.contains(name) { names.append(name) }
            idx = q
        }
        return names
    }

    /// Build the `tqsl` argument list. Pure, so it can be unit-tested without
    /// running the tool. `testSign` produces a `.tq8` without uploading.
    public static func arguments(location: String, adifPath: String,
                                 password: String? = nil,
                                 testSign: Bool = false,
                                 outputPath: String? = nil) -> [String] {
        var a = ["-x",                 // batch: no GUI dialogs, exit when done
                 "-d",                 // suppress the date-range dialog
                 "-a", "compliant",    // process only non-duplicate QSOs (skip already-sent)
                 "-l", location]       // station location (callsign / grid / zones)
        if testSign {
            a.append("-z")             // test-sign only — never contacts LoTW
        } else {
            a.append("-u")             // upload after signing (don't just save a .tq8)
        }
        if let p = password, !p.isEmpty { a += ["-p", p] }
        if let o = outputPath, !o.isEmpty { a += ["-o", o] }
        a.append(adifPath)
        return a
    }

    /// Interpret `tqsl`'s exit code and console output into an `Outcome`. Pure,
    /// so it can be unit-tested. TQSL prints a `Final Status: Name(code)` line
    /// and a `wrote N records` line, which we parse for an accurate count and
    /// message; the exit code is the backstop.
    public static func interpret(exitCode: Int32, output: String) -> Outcome {
        let lower = output.lowercased()
        let status = finalStatusLine(in: output)

        if exitCode == 0 {
            if let n = recordCount(in: output) {
                return n > 0 ? .uploaded(records: n) : .nothingNew
            }
            return .uploaded(records: 0)
        }
        // All QSOs were duplicates / outside the date range — nothing to do,
        // not an error. (TQSL_EXIT_NO_QSOS / QSOS_SUPPRESSED.)
        if exitCode == 8 || exitCode == 9
            || lower.contains("duplicate") || lower.contains("already been uploaded")
            || lower.contains("no qsos") {
            return .nothingNew
        }
        return .failure(status ?? lastMeaningfulLine(in: output) ?? "tqsl exited with code \(exitCode)")
    }

    /// Sign and upload an ADIF file already on disk. **Blocking** — run this off
    /// the main actor. Returns `.failure` if `tqsl` can't be found or launched.
    public static func upload(adifPath: String, location: String,
                              binary: String? = nil, password: String? = nil,
                              testSign: Bool = false, outputPath: String? = nil) -> Outcome {
        guard let bin = resolveBinary(override: binary) else {
            return .failure("tqsl not found — install TrustedQSL or set its path")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = arguments(location: location, adifPath: adifPath,
                                   password: password, testSign: testSign,
                                   outputPath: outputPath)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // tqsl is interactive by nature; close stdin so a stray prompt can't hang us.
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return .failure("could not launch tqsl: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return interpret(exitCode: proc.terminationStatus, output: out)
    }

    /// Convenience: write `adifBody` (one or more serialized records, no header)
    /// to a temp `.adi`, then sign+upload it. The temp file is removed afterward.
    /// **Blocking** — run off the main actor.
    public static func uploadRecords(_ adifBody: String, location: String,
                                     binary: String? = nil, password: String? = nil) -> Outcome {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft8-808-lotw-\(ProcessInfo.processInfo.processIdentifier)-\(abs(adifBody.hashValue)).adi")
        do {
            try (ADIFLog.header() + adifBody).write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return .failure("could not stage ADIF for upload: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return upload(adifPath: tmp.path, location: location, binary: binary, password: password)
    }

    // MARK: - Output parsing helpers

    private static func finalStatusLine(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.contains("Final Status:") }?
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pull the QSO count out of a `wrote N records` / `N QSOs` style line —
    /// the integer immediately *preceding* the word "record(s)"/"qso(s)", so a
    /// digit-bearing path on the same line (e.g. `.../ft8808-it.tq8`) can't be
    /// mistaken for the count.
    private static func recordCount(in output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            for (i, w) in words.enumerated() where i > 0 {
                let isCountWord = w.hasPrefix("record") || w.hasPrefix("qso")
                if isCountWord, let n = Int(words[i - 1]) { return n }
            }
        }
        return nil
    }

    private static func lastMeaningfulLine(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
