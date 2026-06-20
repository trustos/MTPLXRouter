import Foundation

func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

enum RouterError: Error, CustomStringConvertible {
    case unknownModel(String)
    case mtplxMissing(String)
    case modelPathMissing(String)
    case backendPortBusy(Int, Int32)
    case daemonExited(String)
    case healthTimeout
    case badRequest(String)
    var description: String {
        switch self {
        case .unknownModel(let m):    return "unknown model '\(m)' — not in the configured models"
        case .mtplxMissing(let p):    return "mtplx CLI not found or not executable at '\(p)' — install MTPLX or fix the path in Settings"
        case .modelPathMissing(let p): return "model folder not found at '\(p)' — fix the path in Settings ▸ Models"
        case .backendPortBusy(let port, let pid): return "backend port \(port) is in use by pid \(pid) — change the backend port in Settings or use ‘Free backend port’ in the menu"
        case .daemonExited(let why):  return "the model daemon exited during startup: \(why)"
        case .healthTimeout:          return "the model daemon didn’t become healthy in time (see daemon.log)"
        case .badRequest(let m):      return "bad request: \(m)"
        }
    }
}

/// Simple append-only logger that mirrors to stderr and a rotating-ish file.
final class LogStore {
    static let shared = LogStore()
    let dir: URL
    let appLogURL: URL
    let daemonLogURL: URL
    private let q = DispatchQueue(label: "mtplx.router.log")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MTPLX Router/logs", isDirectory: true)
        dir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        appLogURL = base.appendingPathComponent("router.log")
        daemonLogURL = base.appendingPathComponent("daemon.log")
        for u in [appLogURL, daemonLogURL] where !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: nil)
        }
    }

    func log(_ msg: String) {
        let line = "[\(Self.ts())] \(msg)\n"
        q.sync {
            if let d = line.data(using: .utf8) {
                FileHandle.standardError.write(d)
                if let fh = try? FileHandle(forWritingTo: appLogURL) {
                    fh.seekToEndOfFile(); fh.write(d); try? fh.close()
                }
            }
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    static func ts() -> String { fmt.string(from: Date()) }
}

/// PID of the first process LISTENing on a TCP port, via lsof. nil if none.
func pidListening(onPort port: Int) -> Int32? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let first = String(data: data, encoding: .utf8)?
        .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    return first.flatMap { Int32($0) }
}

/// Resident set size (bytes) for a pid. nil if the process is gone.
func rssBytes(pid: Int32) -> Int64? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "rss=", "-p", String(pid)]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let kb = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), let v = Int64(kb) else { return nil }
    return v * 1024  // ps reports KiB
}

func humanBytes(_ b: Int64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(b) / 1_048_576
    return String(format: "%.0f MB", mb)
}
