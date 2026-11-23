import CoreGraphics
import Foundation

/// Fallback decoders for WBMP, XBM, and XPM.
enum LegacyBitmaps {
    static func decode(_ url: URL) -> CGImage? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 << 20,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        switch url.pathExtension.lowercased() {
        case "wbmp": return wbmp(data)
        case "xbm": return xbm(String(decoding: data, as: UTF8.self))
        case "xpm": return xpm(String(decoding: data, as: UTF8.self))
        default: return nil
        }
    }

    private static func wbmp(_ data: Data) -> CGImage? {
        var offset = 0
        func integer() -> Int? {
            var value = 0
            for _ in 0..<5 where offset < data.count {
                let byte = data[offset]
                offset += 1
                value = (value << 7) | Int(byte & 0x7f)
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        guard integer() == 0, integer() == 0, let width = integer(), let height = integer(),
              valid(width, height), let bits = data.part(offset, (width + 7) / 8 * height) else { return nil }
        return monochrome(bits, width: width, height: height, lsbFirst: false)
    }

    private static func xbm(_ text: String) -> CGImage? {
        var width = 0, height = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 3, parts[0] == "#define" {
                if parts[1].hasSuffix("_width") { width = Int(parts[2]) ?? 0 }
                if parts[1].hasSuffix("_height") { height = Int(parts[2]) ?? 0 }
            }
            if line.contains("{") { break }
        }
        guard valid(width, height), let start = text.firstIndex(of: "{"), let end = text[start...].firstIndex(of: "}")
        else { return nil }
        let words = text[text.index(after: start)..<end].split { $0 == "," || $0.isWhitespace }
        let stride = (width + 7) / 8
        let isShort = text[..<start].split(whereSeparator: \.isWhitespace).contains("short")
        let paddedStride = isShort ? (width + 15) / 16 * 2 : stride
        var bytes = Data()
        for word in words {
            guard word.hasPrefix("0x") || word.hasPrefix("0X"), let value = UInt16(word.dropFirst(2), radix: 16)
            else { continue }
            bytes.append(UInt8(truncatingIfNeeded: value))
            if isShort { bytes.append(UInt8(value >> 8)) }
            if bytes.count >= paddedStride * height { break }
        }
        guard bytes.count >= paddedStride * height else { return nil }
        if stride != paddedStride {
            var compact = Data()
            for row in 0..<height { compact.append(bytes[row * paddedStride..<(row * paddedStride + stride)]) }
            bytes = compact
        }
        return monochrome(bytes, width: width, height: height, lsbFirst: true)
    }

    private static func monochrome(_ bits: Data, width: Int, height: Int, lsbFirst: Bool) -> CGImage? {
        let stride = (width + 7) / 8
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for row in 0..<height {
                for column in 0..<width {
                    let shift = lsbFirst ? column % 8 : 7 - column % 8
                    let bit = bits[row * stride + column / 8] >> shift & 1
                    output[row * width + column] = (lsbFirst ? bit == 1 : bit == 0) ? 0 : 255
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func xpm(_ text: String) -> CGImage? {
        let lines: [String]
        if text.hasPrefix("! XPM2") {
            lines = text.components(separatedBy: .newlines).dropFirst()
                .filter { !$0.isEmpty && !$0.hasPrefix("!") }
        } else {
            lines = quotedStrings(text)
        }
        guard let header = lines.first else { return nil }
        let dimensions = header.split(whereSeparator: \.isWhitespace).prefix(4).compactMap { Int($0) }
        guard dimensions.count == 4 else { return nil }
        let (width, height, colors, characters) = (dimensions[0], dimensions[1], dimensions[2], dimensions[3])
        guard valid(width, height), (1...65_536).contains(colors), (1...16).contains(characters),
              lines.count >= 1 + colors + height else { return nil }

        var palette: [String: UInt32] = [:]
        for line in lines[1...colors] {
            let bytes = line.utf8
            guard bytes.count > characters else { return nil }
            let key = String(decoding: bytes.prefix(characters), as: UTF8.self)
            let spec = String(decoding: bytes.dropFirst(characters), as: UTF8.self).split(whereSeparator: \.isWhitespace)
            var variants: [Substring: String] = [:]
            var kind: Substring?
            for token in spec {
                if ["s", "m", "g4", "g", "c"].contains(token) { kind = token }
                else if let kind { variants[kind, default: ""] += token }
            }
            guard let name = ["c", "g", "g4", "m"].compactMap({ variants[$0] }).first,
                  let color = color(name) else { return nil }
            palette[key] = color.bigEndian
        }

        var pixels = [UInt32]()
        pixels.reserveCapacity(width * height)
        for line in lines[(1 + colors)..<(1 + colors + height)] {
            let row = Array(line.utf8)
            guard row.count >= width * characters else { return nil }
            for start in stride(from: 0, to: width * characters, by: characters) {
                let id = String(decoding: row[start..<(start + characters)], as: UTF8.self)
                guard let pixel = palette[id] else { return nil }
                pixels.append(pixel)
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func quotedStrings(_ text: String) -> [String] {
        guard let body = text.firstIndex(of: "{") else { return [] }
        var lines: [String] = []
        var current: [UInt8]?
        var escaped = false
        for byte in text[body...].utf8 {
            if escaped {
                current?.append(byte == 110 ? 10 : byte == 116 ? 9 : byte)
                escaped = false
            } else if byte == 92, current != nil {
                escaped = true
            } else if byte == 34 {
                if let current { lines.append(String(decoding: current, as: UTF8.self)) }
                current = current == nil ? [] : nil
            } else if current != nil {
                current?.append(byte)
            }
        }
        return lines
    }

    private static func color(_ name: String) -> UInt32? {
        let name = name.lowercased()
        if name == "none" { return 0 }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            guard [3, 6, 9, 12].contains(digits.count) else { return nil }
            let componentSize = digits.count / 3
            let maxValue = UInt32((1 << (4 * componentSize)) - 1)
            var value: UInt32 = 0
            for index in 0..<3 {
                let part = digits.dropFirst(index * componentSize).prefix(componentSize)
                guard let component = UInt32(part, radix: 16) else { return nil }
                value = (value << 8) | (component * 255 + maxValue / 2) / maxValue
            }
            return value << 8 | 255
        }
        if let value = X11Colors.names[name] { return value << 8 | 255 }
        return nil
    }

    private static func valid(_ width: Int, _ height: Int) -> Bool {
        (1...32_768).contains(width) && (1...32_768).contains(height) && width * height <= 16_777_216
    }
}
