import Foundation
import Network

/// طابور الفواتير اللي اتصوّرت من غير نت. بتتخزّن على الجهاز وتتقرأ أول ما النت يرجع.
enum PendingScanStore {
    struct Entry: Identifiable {
        let id: String
        let url: URL
        let mimeType: String
        let date: Date
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PendingScans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func enqueue(data: Data, mimeType: String) -> Bool {
        let ext = mimeType == "application/pdf" ? "pdf" : "jpg"
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url -> Entry? in
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "pdf" else { return nil }
            let date = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? Date.distantPast
            return Entry(
                id: url.lastPathComponent,
                url: url,
                mimeType: ext == "pdf" ? "application/pdf" : "image/jpeg",
                date: date
            )
        }
        .sorted { $0.date < $1.date }
    }

    static var count: Int { entries().count }

    static func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
    }

    static func removeAll() {
        entries().forEach(remove)
    }
}

/// بيراقب الاتصال بالنت (بدون ما يوقّف حاجة). isOnline بيتحدّث على الـ main thread.
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = (path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "oasis.network.monitor"))
    }

    deinit {
        monitor.cancel()
    }
}
