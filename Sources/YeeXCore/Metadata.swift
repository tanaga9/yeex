import Foundation

public struct ImageMetadata: Sendable {
    public let format: String
    public let raw: [String: String]
    public let fields: [String: String]
    public let promptJSON: String?
    public let workflowJSON: String?

    public static func supports(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
    }

    public static func read(_ url: URL) throws -> ImageMetadata {
        parse(try Data(contentsOf: url, options: .mappedIfSafe), fallback: url.pathExtension)
    }

    public static func parse(_ data: Data, fallback: String = "") -> ImageMetadata {
        let data = Data(data)
        let signature: String?
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { signature = "png" }
        else if data.starts(with: [255, 216]) { signature = "jpeg" }
        else if data.starts(with: Data("RIFF".utf8)), data.part(8, 4) == Data("WEBP".utf8) { signature = "webp" }
        else { signature = nil }

        let raw: [String: String]
        switch signature {
        case "png": raw = png(data)
        case "jpeg": raw = jpeg(data)
        case "webp": raw = webp(data)
        default: raw = [:]
        }

        var fields = raw
        fields["parameters_raw"] = raw["parameters"]
        fields["prompt"] = raw["Prompt"] ?? raw["prompt"]
        fields["negative_prompt"] = raw["Negative prompt"] ?? raw["negative_prompt"]
        let json = raw.compactMapValues { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        var graphs = [json["prompt"] as? [String: Any], workflowGraph(json["workflow"])]
        for key in json.keys.sorted() {
            if let value = json[key] as? [String: Any] {
                graphs.append(value["prompt"] as? [String: Any])
                graphs.append(workflowGraph(value["workflow"]))
            }
        }
        for graph in graphs.compactMap({ $0 }) {
            if let extracted = comfyFields(graph) {
                fields.merge(extracted) { _, extracted in extracted }
                break
            }
        }
        if let parameters = raw["parameters"] {
            for (key, value) in automaticFields(parameters) where fields[key] == nil { fields[key] = value }
        }
        let ext = fallback.lowercased()
        return ImageMetadata(format: signature ?? (ext == "jpg" ? "jpeg" : (ext.isEmpty ? "unknown" : ext)),
                             raw: raw, fields: fields, promptJSON: pretty(json["prompt"]),
                             workflowJSON: pretty(json["workflow"]))
    }

    private static func pretty(_ object: Any?) -> String? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func png(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = 8
        while let length = data.number(at: cursor, count: 4),
              let type = data.number(at: cursor + 4, count: 4),
              length <= data.count - cursor - 12 {
            if type == 0x49454e44 { break }  // IEND
            if [0x74455874, 0x7a545874, 0x69545874].contains(type),
               let chunk = data.part(cursor + 8, length), let zero = chunk.firstIndex(of: 0), zero > 0 {
                let key = latin1(chunk.prefix(zero))
                let rest = Data(chunk.dropFirst(zero + 1))
                switch type {
                case 0x74455874: result[key] = latin1(rest)
                case 0x7a545874:
                    result[key] = rest.first == 0
                        ? rest.part(1, rest.count - 1)?.inflated(limit: 32 << 20).map(latin1) ?? "" : ""
                default:
                    result[key] = ""
                    if rest.count >= 2, let languageEnd = rest.dropFirst(2).firstIndex(of: 0),
                       let translationEnd = rest.dropFirst(languageEnd + 1).firstIndex(of: 0) {
                        let payload = Data(rest.dropFirst(translationEnd + 1))
                        let decoded = rest[0] == 0 ? payload : payload.inflated(limit: 32 << 20)
                        result[key] = decoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    }
                }
            }
            cursor += 12 + length
        }
        return result
    }

    private static func jpeg(_ data: Data) -> [String: String] {
        var tags: [String: String] = [:]
        var xmp = ""
        var comments: [String] = []
        let xmpHeader = Data("http://ns.adobe.com/xap/1.0\0".utf8)
        var cursor = 2
        while cursor < data.count {
            guard data[cursor] == 255 else { cursor += 1; continue }
            while cursor < data.count && data[cursor] == 255 { cursor += 1 }
            guard cursor < data.count else { break }
            let marker = data[cursor]
            cursor += 1
            if marker == 0xd9 || marker == 0xda { break }
            if (0xd0...0xd7).contains(marker) || marker == 0x01 { continue }
            guard let length = data.number(at: cursor, count: 2),
                  let payload = data.part(cursor + 2, length - 2) else { break }
            cursor += length
            if marker == 0xe1 && payload.starts(with: Data("Exif\0\0".utf8)) {
                tags.merge(exif(Data(payload.dropFirst(6)))) { first, _ in first }
            } else if marker == 0xe1 && payload.starts(with: xmpHeader) {
                xmp += decodeBest(Data(payload.dropFirst(xmpHeader.count)))
            } else if marker == 0xfe {
                let text = decodeBest(payload)
                if !text.isEmpty { comments.append(text) }
            }
        }
        var result = normalizedExif(tags, webp: false)
        mergeXMP(xmp, into: &result)
        if !comments.isEmpty { result["Comment"] = comments.joined(separator: "\n") }
        return result
    }

    private static func webp(_ data: Data) -> [String: String] {
        var tags: [String: String] = [:]
        var xmp = ""
        var cursor = 12
        while let type = data.number(at: cursor, count: 4),
              let length = data.number(at: cursor + 4, count: 4, littleEndian: true),
              length <= data.count - cursor - 8 {
            if type == 0x45584946, let payload = data.part(cursor + 8, length) {
                let tiff = payload.starts(with: Data("Exif\0\0".utf8)) ? Data(payload.dropFirst(6)) : payload
                tags.merge(exif(tiff)) { first, _ in first }
            } else if type == 0x584d5020, let payload = data.part(cursor + 8, length) {
                xmp += decodeBest(payload)
            }
            cursor += 8 + length + (length & 1)
        }
        var result = normalizedExif(tags, webp: true)
        mergeXMP(xmp, into: &result)
        return result
    }

    private static func normalizedExif(_ tags: [String: String], webp: Bool) -> [String: String] {
        var result = tags
        result["Make"] = nil
        result["Model"] = nil
        if webp {
            for (tag, prefix, key) in [("Make", "workflow:", "workflow"), ("Model", "prompt:", "prompt")] {
                if let value = tags[tag]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   value.lowercased().hasPrefix(prefix) {
                    let text = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { result[key] = text }
                }
            }
        }
        for key in ["UserComment", "XPComment", "ImageDescription", "XPTitle", "XPAuthor", "XPKeywords", "XPSubject"] {
            if let text = result[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result["parameters"] = text
                break
            }
        }
        return result
    }

    private static func mergeXMP(_ xmp: String, into result: inout [String: String]) {
        guard !xmp.isEmpty else { return }
        result["XMP"] = xmp
        let delegate = XMPFields()
        let parser = XMLParser(data: Data(xmp.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        for (key, value) in delegate.values where result[key] == nil { result[key] = value }
        if result["parameters"] == nil {
            result["parameters"] = ["parameters", "Parameters", "sd-metadata", "sd_metadata"]
                .compactMap { delegate.values[$0] }.first ?? xmp
        }
    }

    private static func exif(_ data: Data) -> [String: String] {
        let little = data.starts(with: [73, 73])
        guard little || data.starts(with: [77, 77]) else { return [:] }
        func read(_ offset: Int, _ size: Int) -> Int? { data.number(at: offset, count: size, littleEndian: little) }
        guard read(2, 2) == 42, let first = read(4, 4) else { return [:] }
        let names = [0x010e: "ImageDescription", 0x010f: "Make", 0x0110: "Model", 0x9286: "UserComment",
                     0x9c9b: "XPTitle", 0x9c9c: "XPComment", 0x9c9d: "XPAuthor", 0x9c9e: "XPKeywords", 0x9c9f: "XPSubject"]
        let widths = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1]
        var pending = [first]
        var visited = Set<Int>()
        var result: [String: String] = [:]
        while let offset = pending.popLast() {
            guard offset > 0, visited.insert(offset).inserted, let count = read(offset, 2) else { continue }
            for index in 0..<count {
                let cursor = offset + 2 + 12 * index
                guard let tag = read(cursor, 2), let type = read(cursor + 2, 2),
                      let items = read(cursor + 4, 4), let value = read(cursor + 8, 4) else { break }
                if tag == 0x8769 && items == 1 { pending.append(value); continue }
                guard let name = names[tag], let width = widths[type],
                      let bytes = data.part(items * width <= 4 ? cursor + 8 : value, items * width) else { continue }
                let text: String
                if tag == 0x9286 { text = decodeComment(bytes) }
                else if tag >= 0x9c9b { text = decodeUTF16(bytes, little: true, infer: false) }
                else { text = decodeBest(bytes, ifd: true) }
                if !text.isEmpty { result[name] = text }
            }
            if let next = read(offset + 2 + 12 * count, 4), next > 0 { pending.append(next) }
        }
        return result
    }

    static func decodeComment(_ data: Data) -> String {
        guard data.count >= 8 else { return decodeBest(data) }
        let head = Data(data.prefix(8))
        let text = Data(data.dropFirst(8))
        if head.starts(with: Data("ASCII".utf8)) { return latin1(text).trimmingCharacters(in: nul) }
        if head.starts(with: Data("UNICODE".utf8)) { return decodeUTF16(text, little: false, infer: true) }
        if head.starts(with: Data("JIS".utf8)) { return (japanese(text) ?? "").trimmingCharacters(in: nul) }
        return decodeBest(text)
    }

    private static let nul = CharacterSet(charactersIn: "\0")

    private static func latin1(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    private static func japanese(_ data: Data) -> String? {
        let cp932 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: cp932)) ?? String(data: data, encoding: .shiftJIS)
    }

    static func decodeBest(_ data: Data, ifd: Bool = false) -> String {
        if data.starts(with: [239, 187, 191]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self).trimmingCharacters(in: nul)
        }
        if data.starts(with: [255, 254]) || data.starts(with: [254, 255]) {
            return decodeUTF16(data, little: true, infer: true)
        }
        var sample = Array(data.prefix(4096))
        if sample.count % 2 == 1 { sample.removeLast() }
        while sample.suffix(2).elementsEqual([0, 0]) { sample.removeLast(2) }
        var zero = [0, 0]
        for (index, byte) in sample.enumerated() where byte == 0 { zero[index % 2] += 1 }
        if let most = zero.max(), most >= 2, most * 5 > sample.count, zero[0] != zero[1] {
            return decodeUTF16(data, little: zero[1] > zero[0], infer: true)
        }
        if let text = String(data: data, encoding: .utf8) ?? japanese(data) {
            return text.trimmingCharacters(in: nul)
        }
        if ifd { return String(decoding: data, as: UTF8.self).trimmingCharacters(in: nul) }
        for encoding: String.Encoding in [.utf16LittleEndian, .utf16BigEndian] {
            if data.count % 2 == 0, let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text.trimmingCharacters(in: nul)
            }
        }
        return latin1(data).trimmingCharacters(in: nul)
    }

    private static func decodeUTF16(_ data: Data, little: Bool, infer: Bool) -> String {
        var bytes = Array(data)
        if bytes.count % 2 == 1 { bytes.removeLast() }
        var little = little
        if bytes.starts(with: [255, 254]) || bytes.starts(with: [254, 255]) {
            little = bytes[0] == 255
            bytes.removeFirst(2)
        } else if infer {
            var totals = [0, 0], runs = [0, 0], longest = [0, 0]
            func ascii(_ value: UInt8) -> Bool { [9, 10, 13].contains(value) || (32...126).contains(value) }
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let be = bytes[index] == 0 && ascii(bytes[index + 1])
                let le = bytes[index + 1] == 0 && ascii(bytes[index])
                for (order, match) in [be, le].enumerated() {
                    if match { totals[order] += 1; runs[order] += 1 }
                    else { runs[order] = 0 }
                    longest[order] = max(longest[order], runs[order])
                }
            }
            let beScore = (longest[0], totals[0]), leScore = (longest[1], totals[1])
            if beScore != leScore { little = leScore > beScore }
        }
        let units = stride(from: 0, to: bytes.count, by: 2).map { index in
            little ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                   : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        }
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: nul)
    }

    private static func workflowGraph(_ object: Any?) -> [String: Any]? {
        guard let object = object as? [String: Any], let nodes = object["nodes"] as? [[String: Any]] else { return nil }
        var graph: [String: Any] = [:]
        for node in nodes { if let id = node["id"] { graph[String(describing: id)] = node } }
        return graph
    }

    private static func comfyFields(_ graph: [String: Any]) -> [String: String]? {
        guard let node = graph.keys.sorted().compactMap({ graph[$0] as? [String: Any] }).first(where: {
            ($0["class_type"] as? String)?.hasPrefix("KSampler") == true
        }) else { return nil }
        let inputs = node["inputs"] as? [String: Any] ?? [:]
        var result = ["generator": "ComfyUI"]
        for (input, key) in [("seed", "Seed"), ("steps", "Steps"), ("cfg", "CFG scale"),
                             ("sampler_name", "Sampler"), ("scheduler", "scheduler"), ("denoise", "denoise")] {
            if let value = inputs[input], !(value is NSNull) { result[key] = String(describing: value) }
        }
        for (input, key) in [("positive", "prompt"), ("negative", "negative_prompt")] {
            guard let source = inputs[input], let id = (source as? [Any])?.first ?? source as Any?,
                  let encoder = graph[String(describing: id)] as? [String: Any],
                  let text = encoder["inputs"] as? [String: Any] else { continue }
            let prompt = text["text"] as? String ??
                [text["text_g"] as? String, text["text_l"] as? String].compactMap { $0 }.joined(separator: " ")
            if !prompt.isEmpty { result[key] = prompt }
        }
        return result
    }

    private static func automaticFields(_ parameters: String) -> [String: String] {
        guard let steps = parameters.range(of: "\nSteps: ", options: .backwards) else { return [:] }
        let text = String(parameters[..<steps.lowerBound])
        let prompts = text.components(separatedBy: "\nNegative prompt: ")
        var fields = ["prompt": prompts[0], "generator": "Stable Diffusion"]
        if prompts.count > 1 { fields["negative_prompt"] = prompts.dropFirst().joined(separator: "\nNegative prompt: ") }
        for option in parameters[parameters.index(after: steps.lowerBound)...].components(separatedBy: ", ") {
            if let separator = option.range(of: ": ") {
                fields[String(option[..<separator.lowerBound])] = String(option[separator.upperBound...])
            }
        }
        return fields
    }
}

private final class XMPFields: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var key: String?
    private var body = ""
    private let supported = ["parameters", "Parameters", "sd-metadata", "sd_metadata"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        for (name, value) in attributes {
            if let local = name.split(separator: ":").last.map(String.init), supported.contains(local) {
                values[local] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let local = elementName.split(separator: ":").last.map(String.init), supported.contains(local) {
            key = local
            body = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if key != nil { body += string } }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if let key, elementName.split(separator: ":").last == Substring(key) {
            let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[key] = value }
            self.key = nil
        }
    }
}
