import AppKit
import Combine
import Foundation

/// A manual inventory, never a guess that old personal files are disposable.
/// Walks metadata only, skips links/packages/cloud placeholders, and retains a
/// bounded list of the largest files. It has no timer or background schedule.
final class StorageReview: ObservableObject {
    struct Item: Identifiable {
        var id: String { url.path }
        let url: URL
        let bytes: Int64
        let logicalBytes: Int64
        let modified: Date?
        let identity: UninstallerSupport.FileIdentity
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var scanning = false
    @Published private(set) var removing = false
    @Published private(set) var inspected = 0
    @Published private(set) var inaccessible = 0
    @Published private(set) var message: String?
    @Published var selected = Set<String>()
    private var cancellation: CleanerSupport.ScanCancellation?
    private var generation = UUID()
    static let limit = 200
    static let minimumBytes: Int64 = 100 * 1_024 * 1_024
    private let minimumSize: Int64
    init(minimumBytes: Int64 = StorageReview.minimumBytes) { minimumSize = max(1, minimumBytes) }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        generation = UUID()
        if scanning { scanning = false; message = "Scan stopped. Scan again to refresh the list." }
    }

    func scan(root: URL) {
        guard !removing else { return }
        guard root.isFileURL, root.standardizedFileURL.path == root.resolvingSymlinksInPath().path, !Self.isProtected(root),
              (try? root.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true else {
            message = "Choose a regular folder or disk. System and app data belong in Cleaner or Uninstaller."
            return
        }
        cancel()
        let minimumSize = minimumSize
        let token = generation
        let flag = CleanerSupport.ScanCancellation()
        cancellation = flag
        scanning = true
        items = []; selected = []; inspected = 0; inaccessible = 0; message = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
                .isPackageKey, .fileSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
                .isUbiquitousItemKey]
            var found: [Item] = []
            var count = 0, denied = 0
            let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants], errorHandler: { _, _ in denied += 1; return !flag.isCancelled })
            while !flag.isCancelled, let url = walker?.nextObject() as? URL {
                autoreleasepool {
                    count += 1
                    guard let values = try? url.resourceValues(forKeys: keys) else { denied += 1; return }
                    if values.isSymbolicLink == true || Self.isProtected(url) {
                        if values.isDirectory == true { walker?.skipDescendants() }
                        return
                    }
                    guard values.isRegularFile == true, values.isUbiquitousItem != true,
                          let size = values.fileAllocatedSize ?? values.fileSize,
                          size >= minimumSize,
                          let identity = UninstallerSupport.fileIdentity(at: url) else { return }
                    found.append(Item(url: url, bytes: Int64(size), logicalBytes: Int64(values.fileSize ?? size), modified: values.contentModificationDate, identity: identity))
                    if found.count > Self.limit * 2 {
                        found.sort { $0.bytes > $1.bytes }; found = Array(found.prefix(Self.limit))
                    }
                }
            }
            guard !flag.isCancelled else { return }
            found.sort { $0.bytes > $1.bytes }
            let result = Array(found.prefix(Self.limit))
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.items = result; self.inspected = count; self.inaccessible = denied
                self.scanning = false; self.cancellation = nil
            }
        }
    }

    static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/dev",
                     home + "/Library", home + "/.Trash", home + "/.codex", home + "/.claude"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
            || url.pathComponents.contains(".git")
    }

    /// Revalidate identity/size/time after review; replaced or changed files stay put.
    /// This explicit action affects only the selected files and always uses Trash.
    func trashSelected() {
        guard !scanning else { return }
        let chosen = items.filter { selected.contains($0.id) }
        guard !removing else { return }
        removing = true
        DispatchQueue.global(qos: .utility).async { [self] in
        var removed = Set<String>(), failed = 0
        for item in chosen {
            guard !Self.isProtected(item.url),
                  item.url == item.url.resolvingSymlinksInPath(),
                  UninstallerSupport.fileIdentity(at: item.url) == item.identity,
                  // URL resource values from an enumerator may be cached.
                  // Fresh filesystem attributes must decide whether it changed.
                  let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path),
                  (attributes[.size] as? NSNumber)?.int64Value == item.logicalBytes,
                  attributes[.modificationDate] as? Date == item.modified else { failed += 1; continue }
            do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); removed.insert(item.id) }
            catch { failed += 1 }
        }
            DispatchQueue.main.async { [self] in

        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
        message = "Moved \(removed.count) files to Trash. \(failed) could not be moved or changed since the scan."
                removing = false
            }
        }
    }
}
