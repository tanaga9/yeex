import CZlib
import Foundation

extension Data {
    func number(at offset: Int, count: Int, littleEndian: Bool = false) -> Int? {
        guard offset >= 0, count <= self.count - offset else { return nil }
        var value = 0
        for index in 0..<count {
            let byte = self[offset + (littleEndian ? count - index - 1 : index)]
            value = (value << 8) | Int(byte)
        }
        return value
    }

    func part(_ offset: Int, _ count: Int) -> Data? {
        guard offset >= 0, count >= 0, count <= self.count - offset else { return nil }
        return subdata(in: offset..<(offset + count))
    }

    func inflated(raw: Bool = false, gzip: Bool = false, limit: Int) -> Data? {
        guard count <= Int(UInt32.max), !isEmpty else { return nil }
        return withUnsafeBytes { input in
            var stream = z_stream()
            guard inflateInit2_(&stream, raw ? -15 : (gzip ? 31 : 15), ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32_768)
            repeat {
                let status = buffer.withUnsafeMutableBufferPointer { bytes in
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = UInt32(bytes.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = buffer.count - Int(stream.avail_out)
                guard written <= limit - output.count else { return nil }
                output.append(contentsOf: buffer.prefix(written))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK else { return nil }
            } while true
        }
    }
}

enum PixelmatorPreview {
    static let paths = ["QuickLook/Thumbnail.webp", "QuickLook/Thumbnail.tiff"]
    static let limit = 128 * 1024 * 1024

    static func read(_ url: URL) -> Data? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for path in paths {
                let candidate = url.appendingPathComponent(path)
                if let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size <= limit, let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) {
                    return data
                }
            }
            return nil
        }

        // Read only the central directory and the selected member from the archive.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let tailSize = Int(min(end, 65_557))
            guard tailSize >= 22 else { return nil }
            try handle.seek(toOffset: end - UInt64(tailSize))
            guard let tail = try handle.read(upToCount: tailSize) else { return nil }
            var footer: Int?
            for offset in stride(from: tail.count - 22, through: 0, by: -1) {
                if tail.number(at: offset, count: 4) == 0x504b0506,
                   let comment = tail.number(at: offset + 20, count: 2, littleEndian: true),
                   offset + 22 + comment == tail.count {
                    footer = offset
                    break
                }
            }
            guard let footer, tail.number(at: footer + 4, count: 4) == 0,
                  let directorySize = tail.number(at: footer + 12, count: 4, littleEndian: true),
                  let directoryOffset = tail.number(at: footer + 16, count: 4, littleEndian: true),
                  directorySize <= limit, UInt64(directoryOffset + directorySize) <= end else { return nil }
            try handle.seek(toOffset: UInt64(directoryOffset))
            guard let directory = try handle.read(upToCount: directorySize) else { return nil }
            var matches: [String: Int] = [:]
            var cursor = 0
            while directory.number(at: cursor, count: 4) == 0x504b0102 {
                guard let nameSize = directory.number(at: cursor + 28, count: 2, littleEndian: true),
                      let extra = directory.number(at: cursor + 30, count: 2, littleEndian: true),
                      let comment = directory.number(at: cursor + 32, count: 2, littleEndian: true),
                      let bytes = directory.part(cursor + 46, nameSize) else { break }
                let name = String(decoding: bytes, as: UTF8.self)
                if paths.contains(name) { matches[name] = cursor }
                cursor += 46 + nameSize + extra + comment
            }
            for path in paths {
                guard let entry = matches[path],
                      let method = directory.number(at: entry + 10, count: 2, littleEndian: true),
                      let compressed = directory.number(at: entry + 20, count: 4, littleEndian: true),
                      let expanded = directory.number(at: entry + 24, count: 4, littleEndian: true),
                      let offset = directory.number(at: entry + 42, count: 4, littleEndian: true),
                      compressed <= limit, expanded <= limit, UInt64(offset) < end,
                      (directory.number(at: entry + 8, count: 2, littleEndian: true) ?? 1) & 1 == 0
                else { continue }
                try handle.seek(toOffset: UInt64(offset))
                guard let header = try handle.read(upToCount: 30), header.number(at: 0, count: 4) == 0x504b0304,
                      let name = header.number(at: 26, count: 2, littleEndian: true),
                      let extra = header.number(at: 28, count: 2, littleEndian: true) else { continue }
                try handle.seek(toOffset: UInt64(offset + 30 + name + extra))
                guard let payload = try handle.read(upToCount: compressed), payload.count == compressed else { continue }
                let preview = method == 0 ? payload : (method == 8 ? payload.inflated(raw: true, limit: expanded) : nil)
                if let preview, preview.count == expanded { return preview }
            }
        } catch { return nil }
        return nil
    }
}
