import Foundation

/// 跨进程文件锁（flock）。
///
/// 多开播放器 = 多个独立进程共享同一批 JSON 文件。写入是「全量覆写整个文件」，
/// 没有锁就会「最后写的赢」，把别的实例刚写的数据抹掉。
///
/// 为什么用 `flock` 而不是 `NSFileCoordinator`：
///   - `flock` 是内核级建议锁，只阻塞在专用锁文件上，不参与 AppKit/SwiftUI 的
///     主线程回调链 —— 不会出现「持锁回调重入主线程」的死锁；
///   - `NSFileCoordinator` 在进程内会做协调回调，与 libmpv 的渲染线程 +
///     主线程 runloop 组合极易死锁（这是本项目已经踩过的坑类型）。
///
/// 锁文件是**独立的** `.lock` 文件，不锁数据文件本身 —— 数据文件用
/// `options: .atomic` 写入时会被 rename 替换 inode，锁在旧 inode 上等于没锁。
struct FileLock {
    private let fd: Int32

    /// 获取排他锁（阻塞直到拿到）。
    /// - Parameter path: 锁文件路径（建议 `<数据文件>.lock`）。
    init?(path: String) {
        // O_CREAT 保证锁文件可创建；0600 只允许本用户
        let handle = open(path, O_CREAT | O_RDWR, 0o600)
        guard handle >= 0 else { return nil }
        // LOCK_EX 排他锁：同一时刻只有一个进程在「读-合并-写」临界区里
        guard flock(handle, LOCK_EX) == 0 else {
            close(handle)
            return nil
        }
        self.fd = handle
    }

    /// 释放锁并关闭 fd。
    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// RAII：作用域结束时自动释放。
    static func withLock<T>(_ path: String, _ body: () throws -> T) rethrows -> T? {
        guard let lock = FileLock(path: path) else { return nil }
        defer { lock.release() }
        return try body()
    }
}
