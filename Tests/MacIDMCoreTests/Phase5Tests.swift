import Foundation
import Testing
@testable import MacIDMCore

@Suite struct BatchPatternTests {
    @Test func zeroPaddedRange() throws {
        let urls = try BatchPattern.expand("https://e.com/file[001-100].jpg")
        #expect(urls.count == 100)
        #expect(urls.first == "https://e.com/file001.jpg")
        #expect(urls[9] == "https://e.com/file010.jpg")
        #expect(urls.last == "https://e.com/file100.jpg")
    }

    @Test func unpaddedDescendingAndLetters() throws {
        #expect(try BatchPattern.expand("p[1-3]") == ["p1", "p2", "p3"])
        #expect(try BatchPattern.expand("p[3-1]") == ["p3", "p2", "p1"])
        #expect(try BatchPattern.expand("x[a-c].zip") == ["xa.zip", "xb.zip", "xc.zip"])
        #expect(try BatchPattern.expand("plain.zip") == ["plain.zip"])
    }

    @Test func multipleRangesMultiply() throws {
        let urls = try BatchPattern.expand("s[1-2]e[01-03].mp4")
        #expect(urls == ["s1e01.mp4", "s1e02.mp4", "s1e03.mp4", "s2e01.mp4", "s2e02.mp4", "s2e03.mp4"])
    }

    @Test func rejectsBadOrHugePatterns() {
        #expect(throws: BatchPatternError.invalidRange("1-")) { try BatchPattern.expand("f[1-].jpg") }
        #expect(throws: BatchPatternError.invalidRange("x")) { try BatchPattern.expand("f[x].jpg") }
        #expect(throws: BatchPatternError.self) { try BatchPattern.expand("f[1-200]g[1-200]") }
    }

    @Test func linksFromPastedText() throws {
        let text = """
        https://e.com/a.zip
        # comment
        https://e.com/img[1-2].png

        not a url
        https://e.com/a.zip
        """
        let urls = try BatchPattern.links(from: text).map(\.absoluteString)
        #expect(urls == ["https://e.com/a.zip", "https://e.com/img1.png", "https://e.com/img2.png"])
    }
}

@Suite struct ListTransferTests {
    @Test func exportOmitsCookiesAndRoundTrips() throws {
        var a = DownloadItem(url: URL(string: "https://e.com/a.zip")!, fileName: "a.zip")
        a.headers = ["Cookie": "secret=1"]
        var b = DownloadItem(url: URL(string: "https://e.com/done.iso")!)
        b.status = .completed
        var c = DownloadItem(url: URL(string: "https://www.youtube.com/watch?v=x")!, fileName: "Clip")
        c.media = MediaRequest(choice: .audio(format: .mp3), title: "Clip")

        let data = try ListTransfer.exportJSON([a, b, c])
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))

        let imported = try ListTransfer.importItems(from: data, requestedSegments: 4)
        #expect(imported.map(\.url.absoluteString) == ["https://e.com/a.zip", "https://www.youtube.com/watch?v=x"])
        #expect(imported[0].fileName == "a.zip" && imported[0].requestedSegments == 4 && imported[0].headers == nil)
        #expect(imported[1].media?.choice == .audio(format: .mp3) && imported[1].category == .music)
        #expect(imported.allSatisfy { $0.status == .queued })
    }

    @Test func importsPlainTextAndExportsText() throws {
        let items = try ListTransfer.importItems(from: Data("https://e.com/x[1-3].bin\n".utf8), requestedSegments: 8)
        #expect(items.count == 3)
        #expect(ListTransfer.exportText(items) == "https://e.com/x1.bin\nhttps://e.com/x2.bin\nhttps://e.com/x3.bin\n")
    }
}
