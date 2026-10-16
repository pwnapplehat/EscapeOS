import Foundation

func runSpaceCheckTests() {
    T.section("SpaceCheck")
    let mb: Int64 = 1024 * 1024
    let reserve = SpaceCheck.reserve(for: 100 * mb)

    // the reserve scales with the job, within limits
    T.equal(SpaceCheck.reserve(for: 1_000), SpaceCheck.minReserveBytes, "a tiny job keeps the minimum reserve")
    T.equal(SpaceCheck.reserve(for: 100 * mb), 25 * mb, "a mid-size job reserves a quarter of itself")
    T.equal(SpaceCheck.reserve(for: 10_000 * mb), SpaceCheck.maxReserveBytes, "a huge job is capped at the maximum")
    T.equal(SpaceCheck.verdict(needed: 1_000, available: 20 * mb), .enough, "a 1 KB job fits with 20 MB free")
    T.equal(
        SpaceCheck.verdict(needed: 1_000, available: 500_000),
        .notEnough(needed: 1_000, available: 500_000),
        "but not when less than the minimum reserve is free"
    )

    // verdict
    T.equal(SpaceCheck.verdict(needed: 0, available: 0), .enough, "nothing needed is always fine, even on a full disk")
    T.equal(SpaceCheck.verdict(needed: -5, available: 0), .enough, "a negative estimate is treated as nothing")
    T.equal(SpaceCheck.verdict(needed: 100 * mb, available: 100 * mb + reserve), .enough, "exactly needed plus reserve fits")
    T.equal(
        SpaceCheck.verdict(needed: 100 * mb, available: 100 * mb + reserve - 1),
        .notEnough(needed: 100 * mb, available: 100 * mb + reserve - 1),
        "one byte under needed plus reserve does not fit"
    )
    T.equal(
        SpaceCheck.verdict(needed: 2_000 * mb, available: 500 * mb),
        .notEnough(needed: 2_000 * mb, available: 500 * mb),
        "a big operation on little space is refused"
    )
    T.equal(SpaceCheck.verdict(needed: 10 * mb, available: nil), .unknown, "unreadable free space does not block")
    T.equal(
        SpaceCheck.verdict(needed: Int64.max, available: Int64.max - 1),
        .notEnough(needed: Int64.max, available: Int64.max - 1),
        "an overflowing request is refused, not wrapped"
    )

    // message
    let text = SpaceCheck.message(for: "compress these items", needed: 3_000 * mb, available: 100 * mb)
    T.check(text.contains("compress these items"), "message names the operation")
    T.check(text.contains("free"), "message says how much is free")
    T.check(text.hasPrefix("Not enough free space"), "message leads with the problem")

    // real file system
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("escapeos-space-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(_ rel: String, _ n: Int) { fm.createFile(atPath: root.appendingPathComponent(rel).path, contents: Data(count: n)) }
    put("top.bin", 1000)
    put("a/mid.bin", 2000)
    put("a/b/deep.bin", 4000)
    try? fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.appendingPathComponent("a").path)

    let files = FileService()
    T.equal(files.treeBytes(at: root.path), 7000, "tree size sums regular files, not the symlink's target")
    T.equal(files.treeBytes(at: root.appendingPathComponent("a").path), 6000, "a subfolder sums its own files")
    T.equal(files.treeBytes(at: root.appendingPathComponent("top.bin").path), 1000, "a single file is its own size")
    T.equal(files.treeBytes(at: root.appendingPathComponent("missing").path), 0, "a missing path is zero")
    T.check(files.treeBytes(at: root.path, maxNodes: 2) < 7000, "a node limit stops the walk early (a lower bound)")
    T.equal(files.treeBytes(at: root.path, maxNodes: 1_000), 7000, "a generous limit gives the full size")

    let listed = (try? files.list(directory: root.path)) ?? []
    let folder = listed.first { $0.name == "a" }
    let file = listed.first { $0.name == "top.bin" }
    T.check(folder != nil && file != nil, "listing finds the test items")
    if let folder, let file {
        T.equal(files.totalBytes(of: [folder, file]), 7000, "totalBytes mixes folders and files")
    }

    T.check((files.availableCapacity(at: root.path) ?? 0) > 0, "free space is readable for a real folder")
    T.check(files.availableCapacity(at: root.appendingPathComponent("missing/x").path) == nil, "free space of a missing path is nil")

    // require()
    var threw = false
    do {
        try SpaceCheck.require(Int64.max / 2, at: root.path, for: "hold everything", files: files)
    } catch let error as FileServiceError {
        threw = true
        T.check(error.localizedDescription.hasPrefix("Not enough free space"), "require throws the readable message with no prefix")
    } catch {}
    T.check(threw, "require refuses an impossible size")
    var accepted = true
    do { try SpaceCheck.require(1, at: root.path, for: "tiny", files: files) } catch { accepted = false }
    T.check(accepted, "require accepts a tiny request")
}
