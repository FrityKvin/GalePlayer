import Foundation

/// 播放路径：显式指定播放列表要播的条目顺序。
public struct PlaybackQueue: Sendable {
    public private(set) var items: [PlaylistNode] = []
    public private(set) var index: Int = 0

    public init() {}

    public init(items: [PlaylistNode], startAt: Int = 0) {
        self.items = items
        self.index = items.isEmpty ? 0 : min(max(0, startAt), items.count - 1)
    }

    public var isEmpty: Bool { items.isEmpty }
    public var current: PlaylistNode? { items.indices.contains(index) ? items[index] : nil }
    public var hasNext: Bool { index + 1 < items.count }
    public var hasPrevious: Bool { index > 0 }

    public mutating func next() -> PlaylistNode? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    public mutating func previous() -> PlaylistNode? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }

    /// 跳到某条目（按播放列表内的顺序播放时用）。
    public mutating func select(id: UUID) -> PlaylistNode? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        index = idx
        return current
    }

    public mutating func remove(_ ids: Set<UUID>) {
        let currentID = current?.id
        items.removeAll { ids.contains($0.id) }
        if let currentID, let idx = items.firstIndex(where: { $0.id == currentID }) {
            index = idx
        } else {
            index = min(index, max(0, items.count - 1))
        }
    }
}
