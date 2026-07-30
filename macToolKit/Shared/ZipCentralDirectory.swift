import Foundation

/// One entry as recorded in a zip file's central directory.
///
/// `path` is archive-relative and always uses "/" separators, exactly as the
/// archive stores it. Sizes are the values from the directory record, so they
/// are known without touching the compressed payload.
struct ZipEntry: Sendable, Equatable {
    var path: String
    var uncompressedSize: Int64
    var compressedSize: Int64
    var modified: Date?
    var isDirectory: Bool

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

struct ZipListing: Sendable, Equatable {
    var entries: [ZipEntry]
    /// True when the archive holds more entries than `ZipCentralDirectory`
    /// is willing to read; the panel shows its "more items" row.
    var hasMoreEntries: Bool
}

enum ZipReadError: Error {
    /// No end-of-central-directory record — not a zip, or truncated past use.
    case notAnArchive
    /// A length or offset points outside the file.
    case malformed
}

/// Reads a zip file's table of contents without decompressing anything.
///
/// Only two regions are ever read: the tail that holds the end-of-central-
/// directory record, and the central directory itself. A multi-gigabyte
/// archive therefore costs the same as a small one.
enum ZipCentralDirectory {
    /// Entries read before the listing is reported as truncated. Mirrors
    /// `FolderScanner.listCap`'s intent: a pathological archive must not be
    /// able to make Quick Look chew through a million records.
    static let entryCap = 20_000
    /// Central directories larger than this are read only up to the cap.
    private static let directoryByteCap = 64 << 20

    // EOCD is 22 bytes plus a comment of at most 65535.
    private static let maxEOCDSearch = 22 + 0xFFFF
    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EOCDSignature: UInt32 = 0x0606_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50

    static func read(_ url: URL) throws -> ZipListing {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = Int64(try handle.seekToEnd())
        guard fileSize >= 22 else { throw ZipReadError.notAnArchive }

        let tailLength = Int(min(fileSize, Int64(maxEOCDSearch)))
        let tail = try bytes(handle, at: fileSize - Int64(tailLength), count: tailLength)
        guard let eocd = lastIndex(of: eocdSignature, in: tail) else {
            throw ZipReadError.notAnArchive
        }

        var reader = ByteReader(tail)
        try reader.seek(to: eocd + 10)
        var entryCount = Int64(try reader.u16())
        var directorySize = Int64(try reader.u32())
        var directoryOffset = Int64(try reader.u32())

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF
            || directoryOffset == 0xFFFF_FFFF {
            (entryCount, directorySize, directoryOffset) = try zip64Values(
                handle: handle, tail: tail, eocdIndex: eocd,
                tailStart: fileSize - Int64(tailLength))
        }

        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + directorySize <= fileSize else {
            throw ZipReadError.malformed
        }

        let readSize = Int(min(directorySize, Int64(directoryByteCap)))
        let directory = try bytes(handle, at: directoryOffset, count: readSize)
        return parse(directory, declaredCount: entryCount)
    }

    // MARK: Central directory

    private static func parse(_ directory: [UInt8], declaredCount: Int64) -> ZipListing {
        var reader = ByteReader(directory)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(min(max(Int(declaredCount), 0), entryCap))
        var records = 0

        while records < entryCap {
            // A short or damaged tail just ends the listing: everything read
            // so far is still valid and worth showing. A nil entry is a record
            // that parsed but isn't worth a row, so the walk continues.
            let entry: ZipEntry?
            do { entry = try next(&reader) } catch { break }
            records += 1
            if let entry { entries.append(entry) }
        }

        // Either the cap stopped us, or the directory ran out — a capped read
        // or a damaged record — before the count the archive promised.
        let hasMore = records >= entryCap || Int64(records) < declaredCount
        return ZipListing(entries: entries, hasMoreEntries: hasMore)
    }

    /// Reads one central-directory header. Returns nil for a record that is
    /// well-formed but not worth showing (an empty or path-traversing name).
    private static func next(_ reader: inout ByteReader) throws -> ZipEntry? {
        guard try reader.u32() == centralHeaderSignature else {
            throw ZipReadError.malformed
        }
        let versionMadeBy = try reader.u16()
        _ = try reader.u16()                       // version needed
        _ = try reader.u16()                       // general purpose flags
        _ = try reader.u16()                       // compression method
        let modTime = try reader.u16()
        let modDate = try reader.u16()
        _ = try reader.u32()                       // crc32
        var compressed = Int64(try reader.u32())
        var uncompressed = Int64(try reader.u32())
        let nameLength = Int(try reader.u16())
        let extraLength = Int(try reader.u16())
        let commentLength = Int(try reader.u16())
        _ = try reader.u16()                       // disk number start
        _ = try reader.u16()                       // internal attributes
        let externalAttributes = try reader.u32()
        _ = try reader.u32()                       // local header offset

        let nameBytes = try reader.bytes(nameLength)
        let extra = try reader.bytes(extraLength)
        _ = try reader.bytes(commentLength)

        if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF {
            let zip64 = zip64Sizes(
                in: extra,
                uncompressedSaturated: uncompressed == 0xFFFF_FFFF,
                compressedSaturated: compressed == 0xFFFF_FFFF)
            uncompressed = zip64.uncompressed ?? uncompressed
            compressed = zip64.compressed ?? compressed
        }

        // Flag bit 11 promises UTF-8; without it the name is nominally CP437.
        // Trying UTF-8 first covers both, and Latin-1 never fails to decode,
        // so a legacy name degrades to something readable instead of nothing.
        let rawName = String(bytes: nameBytes, encoding: .utf8)
            ?? String(bytes: nameBytes, encoding: .isoLatin1)
            ?? ""

        guard let path = sanitize(rawName) else { return nil }

        let isDirectory = rawName.hasSuffix("/")
            || isDirectory(externalAttributes: externalAttributes,
                           versionMadeBy: versionMadeBy)

        return ZipEntry(
            path: path,
            uncompressedSize: isDirectory ? 0 : max(0, uncompressed),
            compressedSize: isDirectory ? 0 : max(0, compressed),
            modified: date(dosDate: modDate, dosTime: modTime),
            isDirectory: isDirectory)
    }

    /// Drops leading slashes and any "." / ".." components. Nothing is ever
    /// extracted, but a traversing path would still build a nonsense tree.
    private static func sanitize(_ name: String) -> String? {
        let components = name.split(separator: "/").filter { $0 != "." && $0 != ".." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    private static func isDirectory(externalAttributes: UInt32,
                                    versionMadeBy: UInt16) -> Bool {
        let hostSystem = versionMadeBy >> 8
        // 3 = Unix: the high half carries st_mode.
        if hostSystem == 3 {
            let mode = mode_t((externalAttributes >> 16) & 0xFFFF)
            if mode & S_IFMT != 0 { return mode & S_IFMT == S_IFDIR }
        }
        // MS-DOS attribute byte, bit 4.
        return externalAttributes & 0x10 != 0
    }

    private static func date(dosDate: UInt16, dosTime: UInt16) -> Date? {
        guard dosDate != 0 else { return nil }
        var components = DateComponents()
        components.year = Int(dosDate >> 9) + 1980
        components.month = Int((dosDate >> 5) & 0x0F)
        components.day = Int(dosDate & 0x1F)
        components.hour = Int(dosTime >> 11)
        components.minute = Int((dosTime >> 5) & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: Zip64

    private static func zip64Values(
        handle: FileHandle, tail: [UInt8], eocdIndex: Int, tailStart: Int64
    ) throws -> (count: Int64, size: Int64, offset: Int64) {
        // The locator sits immediately before the EOCD record.
        guard eocdIndex >= 20 else { throw ZipReadError.malformed }
        var locator = ByteReader(tail)
        try locator.seek(to: eocdIndex - 20)
        guard try locator.u32() == zip64LocatorSignature else {
            throw ZipReadError.malformed
        }
        _ = try locator.u32()                      // disk with zip64 EOCD
        let zip64Offset = Int64(bitPattern: try locator.u64())
        guard zip64Offset >= 0, zip64Offset < tailStart + Int64(tail.count) else {
            throw ZipReadError.malformed
        }

        var record = ByteReader(try bytes(handle, at: zip64Offset, count: 56))
        guard try record.u32() == zip64EOCDSignature else {
            throw ZipReadError.malformed
        }
        try record.seek(to: 32)
        let count = Int64(bitPattern: try record.u64())
        let size = Int64(bitPattern: try record.u64())
        let offset = Int64(bitPattern: try record.u64())
        return (count, size, offset)
    }

    /// Walks the extra-field blocks looking for the zip64 record (id 0x0001).
    /// Its payload carries only the fields that were saturated, in a fixed
    /// order: uncompressed size, compressed size, local header offset.
    private static func zip64Sizes(
        in extra: [UInt8], uncompressedSaturated: Bool, compressedSaturated: Bool
    ) -> (uncompressed: Int64?, compressed: Int64?) {
        var reader = ByteReader(extra)
        while reader.remaining >= 4 {
            guard let id = try? reader.u16(), let size = try? reader.u16() else { return (nil, nil) }
            guard id == 0x0001 else {
                guard (try? reader.bytes(Int(size))) != nil else { return (nil, nil) }
                continue
            }
            var uncompressed: Int64?
            var compressed: Int64?
            if uncompressedSaturated, let value = try? reader.u64() {
                uncompressed = Int64(bitPattern: value)
            }
            if compressedSaturated, let value = try? reader.u64() {
                compressed = Int64(bitPattern: value)
            }
            return (uncompressed, compressed)
        }
        return (nil, nil)
    }

    // MARK: Raw reads

    private static func bytes(_ handle: FileHandle, at offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0 else { throw ZipReadError.malformed }
        // An archive with no entries has a zero-length central directory, and
        // `read(upToCount: 0)` reports nothing rather than empty data.
        guard count > 0 else { return [] }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZipReadError.malformed
        }
        return [UInt8](data)
    }

    private static func lastIndex(of signature: UInt32, in buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let bytes = withUnsafeBytes(of: signature.littleEndian) { Array($0) }
        var index = buffer.count - 4
        while index >= 0 {
            if buffer[index] == bytes[0], buffer[index + 1] == bytes[1],
               buffer[index + 2] == bytes[2], buffer[index + 3] == bytes[3] {
                return index
            }
            index -= 1
        }
        return nil
    }
}

/// Bounds-checked little-endian cursor. Every overrun throws rather than
/// trapping, so a corrupt archive degrades to a short listing.
private struct ByteReader {
    private let buffer: [UInt8]
    private var index = 0

    init(_ buffer: [UInt8]) { self.buffer = buffer }

    var remaining: Int { buffer.count - index }

    mutating func seek(to offset: Int) throws {
        guard offset >= 0, offset <= buffer.count else { throw ZipReadError.malformed }
        index = offset
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw ZipReadError.malformed }
        defer { index += count }
        return Array(buffer[index..<(index + count)])
    }

    mutating func u16() throws -> UInt16 {
        let raw = try bytes(2)
        return UInt16(raw[0]) | UInt16(raw[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let raw = try bytes(4)
        return raw.enumerated().reduce(UInt32.zero) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    mutating func u64() throws -> UInt64 {
        let raw = try bytes(8)
        return raw.enumerated().reduce(UInt64.zero) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
}
