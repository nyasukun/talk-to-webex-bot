import Foundation

enum OfflineProcess {
    static let sandboxProfile = "(version 1) (allow default) (deny network*)"

    /// Inherit only runtime essentials; credentials and injection variables never cross the boundary.
    static func environment(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = source.filter { ["HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"].contains($0.key) }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["HF_HUB_OFFLINE"] = "1"
        result["TRANSFORMERS_OFFLINE"] = "1"
        result["HF_HUB_DISABLE_TELEMETRY"] = "1"
        result["DO_NOT_TRACK"] = "1"
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["PYTHONNOUSERSITE"] = "1"
        result["TOKENIZERS_PARALLELISM"] = "false"
        result["NUMBA_CACHE_DIR"] = PrivateStorage.directory.appendingPathComponent("runtime/cache/numba").path
        return result
    }
}
