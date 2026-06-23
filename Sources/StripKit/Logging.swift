import Foundation

/// Strip runs as a LaunchServices-launched agent (the only launch context macOS will trust with
/// Accessibility), which means `stdout` is detached. So we mirror log output to a file that any
/// terminal — or the agent driving this spike — can `tail`.
public enum Log {
    /// Override with the `STRIP_LOG` environment variable; defaults to `/tmp/strip.log`.
    public static let path: String = ProcessInfo.processInfo.environment["STRIP_LOG"] ?? "/tmp/strip.log"

    private static let queue = DispatchQueue(label: "com.spike.strip.log")
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    public static func line(_ message: String) {
        let stamp = Self.timestamp()
        let text = "\(stamp) \(message)\n"
        print(text, terminator: "")
        queue.async {
            handle?.write(Data(text.utf8))
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
