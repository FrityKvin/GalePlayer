import CryptoKit
import Foundation

/// 媒体稳定标识。
///
/// 关键帧需要一个跨会话稳定的文件标识；
/// 因此用「绝对路径 + 文件大小 + 修改时间」的摘要代替：
/// 视频被替换或重新压制后摘要变化，关键帧不会错误地套用到新文件上。
public enum MediaKey {
    public static func make(for url: URL, fileManager: FileManager = .default) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(url.standardizedFileURL.path.utf8))

        if let attrs = try? fileManager.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? NSNumber {
                hasher.update(data: Data(String(size.int64Value).utf8))
            }
            if let modified = attrs[.modificationDate] as? Date {
                hasher.update(data: Data(String(Int(modified.timeIntervalSince1970)).utf8))
            }
        }

        return hasher.finalize()
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
