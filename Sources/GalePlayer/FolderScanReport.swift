import Foundation
import GaleCore

/// 播放列表扫描自检：把某个文件夹按 app 的真实逻辑扫一遍并打印结果。
///
/// 用途：
///   - 验证「拖入文件夹 = 单个 toggle，其下为递归扫出的扁平媒体列表」
///   - 排查某目录为什么没被导入（扩展名不支持 / 权限 / 符号链接）
///
/// 用法：GalePlayer --list-folder <目录路径>
enum FolderScanReport {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--list-folder")
    }

    static func run() -> Never {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--list-folder"), arguments.count > index + 1 else {
            FileHandle.standardError.write(Data("用法: --list-folder <目录路径>\n".utf8))
            exit(64)
        }
        let path = arguments[index + 1]
        let root = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            FileHandle.standardError.write(Data("不是目录: \(path)\n".utf8))
            exit(66)
        }

        let node = Playlist.folderNode(for: root)
        let children = node.children ?? []

        var lines: [String] = []
        lines.append("文件夹扫描自检")
        lines.append("  根目录: \(root.path)")
        lines.append("  toggle 名称: \(node.name)（isFolder=\(node.isFolder)）")
        lines.append("  子项数量: \(children.count)（全部为媒体文件，不再产生子文件夹节点）")
        lines.append("  含文件夹子节点: \(children.contains { $0.isFolder } ? "是 ✗" : "否 ✓")")

        let normalizedRoot = root.resolvingSymlinksInPath().path + "/"
        lines.append("  扫描结果（相对路径，播放顺序）：")
        for (offset, child) in children.enumerated() {
            let relative = child.url.resolvingSymlinksInPath().path
                .replacingOccurrences(of: normalizedRoot, with: "")
            lines.append("    \(offset + 1). \(relative)")
        }

        lines.append("  展开后的播放队列长度: \(node.flattenedMedia.count)")
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        exit(0)
    }
}
