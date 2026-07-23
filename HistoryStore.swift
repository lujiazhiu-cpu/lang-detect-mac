//
// HistoryStore.swift — 识别历史记录存储
//
// 每次识别完成后写入一条记录（主体语种/是否混语/各语种占比/文本块数/标注图快照），
// 元数据持久化到 UserDefaults，标注图快照存到 Application Support 目录，供「历史记录窗口」展示。
//

import Foundation

struct HistoryEntry: Codable {
    let date: Date
    let mainLang: String
    let mixed: Bool
    let blockCount: Int
    let breakdown: [String: Int]   // 语种 code -> 字符计数
    let imagePath: String
}

final class HistoryStore {
    static let shared = HistoryStore()
    private let d = UserDefaults.standard
    private let key = "detectHistory"
    let maxEntries = 50

    private(set) var entries: [HistoryEntry] = []

    private init() { load() }

    // 历史标注图快照目录
    var imageDir: String {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let p = base + "/LangDetect/history"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func load() {
        guard let data = d.data(forKey: key),
              let arr = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = arr
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { d.set(data, forKey: key) }
    }

    // 追加一条记录（会把标注图复制一份到历史目录长期保存）
    func add(mainLang: String, mixed: Bool, blockCount: Int,
             breakdown: [(String, Int)], annotatedPath: String) {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dst = imageDir + "/anno_\(stamp).png"
        try? FileManager.default.copyItem(atPath: annotatedPath, toPath: dst)
        let finalPath = FileManager.default.fileExists(atPath: dst) ? dst : annotatedPath

        var dict: [String: Int] = [:]
        for (k, v) in breakdown { dict[k] = v }

        let e = HistoryEntry(date: Date(), mainLang: mainLang, mixed: mixed,
                             blockCount: blockCount, breakdown: dict, imagePath: finalPath)
        entries.insert(e, at: 0)

        if entries.count > maxEntries {
            for r in entries[maxEntries...] { try? FileManager.default.removeItem(atPath: r.imagePath) }
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func clear() {
        for e in entries { try? FileManager.default.removeItem(atPath: e.imagePath) }
        entries = []
        save()
    }
}
