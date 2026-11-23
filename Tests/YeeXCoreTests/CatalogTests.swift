import Foundation
import Testing
@testable import YeeXCore

@Test func independentOrdersAndWrap() {
    let catalog = Catalog()
    let seed = UUID()
    let a = ImageRecord(url: URL(fileURLWithPath: "/a.png"), modified: Date(timeIntervalSince1970: 3), seed: seed)
    let b = ImageRecord(url: URL(fileURLWithPath: "/b.png"), modified: Date(timeIntervalSince1970: 2), seed: seed)
    let c = ImageRecord(url: URL(fileURLWithPath: "/c.png"), modified: Date(timeIntervalSince1970: 1), seed: seed)
    for record in [b, c, a] { catalog.upsert(record) }
    #expect(catalog.first(.mtime) == a.id)
    #expect(catalog.first(.fname) == c.id)
    #expect(catalog.neighbor(b.id, order: .mtime, forward: true, loop: false) == c.id)
    #expect(catalog.neighbor(b.id, order: .fname, forward: true, loop: false) == a.id)
    #expect(catalog.neighbor(a.id, order: .mtime, forward: false, loop: false) == nil)
    #expect(catalog.neighbor(a.id, order: .mtime, forward: false, loop: true) == c.id)
    #expect(BrowseOrder.mtime.toggled(excluding: .random) == .fname)
    catalog.remove(b.id)
    #expect(catalog.neighbor(a.id, order: .mtime, forward: true, loop: false) == c.id)
}
