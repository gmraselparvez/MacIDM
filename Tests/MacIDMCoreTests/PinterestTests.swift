import Foundation
import Testing
@testable import MacIDMCore

@Suite struct PinterestTests {
    @Test func recognisesPinsBoardsAndShortLinks() {
        #expect(PinterestService.target(for: URL(string: "https://www.pinterest.com/pin/1125196288136978029/")!) == .pin(id: "1125196288136978029"))
        #expect(PinterestService.target(for: URL(string: "https://pinterest.co.uk/pin/cute-cats--563512972106407094/")!) == .pin(id: "563512972106407094"))
        #expect(PinterestService.target(for: URL(string: "https://www.pinterest.com/lirunyun9/%E5%9B%BE%E6%A0%87/")!) == .board(user: "lirunyun9", slug: "图标"))
        #expect(PinterestService.target(for: URL(string: "https://www.pinterest.com/someone/board/section/")!) == .board(user: "someone", slug: "board"))
        #expect(PinterestService.target(for: URL(string: "https://pin.it/abc123")!) == .shortLink(URL(string: "https://pin.it/abc123")!))
        #expect(PinterestService.target(for: URL(string: "https://www.pinterest.com/search/pins/?q=cats")!) == nil)
        #expect(PinterestService.target(for: URL(string: "https://www.pinterest.com/")!) == nil)
        #expect(PinterestService.target(for: URL(string: "https://example.com/pin/123")!) == nil)
    }

    @Test func parsesImagePinAtOriginalSize() throws {
        let json = #"""
        {"resource_response":{"data":{"id":"1125196288136978029","title":"","grid_title":"Icon set",
          "images":{"236x":{"url":"https://i.pinimg.com/236x/83/4f/85/a.png"},
                    "orig":{"url":"https://i.pinimg.com/originals/83/4f/85/834f859aac345c0f295cad06056b4f70.png"}}}}}
        """#
        let page = PinterestService.parsePage(Data(json.utf8))
        let pin = try #require(PinterestService.pin(from: page.data))
        #expect(pin.title == "Icon set" && !pin.isVideo)
        #expect(pin.imageURL?.absoluteString.contains("/originals/") == true)
        #expect(PinterestService.fileName(for: pin, url: pin.imageURL!) == "Icon set.png")
        var untitled = pin
        untitled.title = ""
        #expect(PinterestService.fileName(for: untitled, url: pin.imageURL!) == "pin-8136978029.png")
    }

    @Test func parsesBoardFeedWithVideoAndPaging() throws {
        let json = #"""
        {"resource_response":{"bookmark":"Y2JVSG81","data":[
          {"type":"pin","id":"1","images":{"orig":{"url":"https://i.pinimg.com/originals/a.jpg"}}},
          {"type":"story","id":"x"},
          {"type":"pin","id":"2","images":{"orig":{"url":"https://i.pinimg.com/originals/b.jpg"}},
           "videos":{"video_list":{"V_HLSV4":{"url":"https://v1.pinimg.com/videos/x.m3u8"},
                                    "V_720P":{"url":"https://v1.pinimg.com/videos/mc/720p/x.mp4","height":720}}}},
          {"type":"pin","id":"3","videos":{"video_list":{"V_HLSV4":{"url":"https://v1.pinimg.com/videos/y.m3u8"}}}}]}}
        """#
        let page = PinterestService.parsePage(Data(json.utf8))
        #expect(page.bookmark == "Y2JVSG81")
        let pins = PinterestService.pins(fromFeed: page.data)
        #expect(pins.map(\.id) == ["1", "2", "3"])
        #expect(pins[1].videoURL?.absoluteString.hasSuffix("720p/x.mp4") == true)
        #expect(pins[2].videoNeedsStreaming && pins[2].videoURL == nil)
        let collection = PinterestService.Collection(title: "B", pins: pins, isBoard: true)
        #expect(collection.images.map(\.id) == ["1"] && collection.videos.map(\.id) == ["2", "3"])
        let end = PinterestService.parsePage(Data(#"{"resource_response":{"bookmark":"-end-","data":[]}}"#.utf8))
        #expect(end.bookmark == nil)
    }

    @Test func batchRequestsKeepOnlyWebLinks() {
        var r = BrowserRequest(url: "https://example.com/gallery")
        r.type = "batch"
        r.urls = ["https://e.com/a.jpg", "https://e.com/a.jpg", "data:image/png;base64,xx", "javascript:x", "https://e.com/b.png"]
        #expect(r.validated() != nil)
        #expect(r.batchURLs.map(\.absoluteString) == ["https://e.com/a.jpg", "https://e.com/b.png"])
    }

    @Test func imagesHaveTheirOwnCategory() {
        #expect(MacIDMCore.Category.from(fileName: "photo.JPG") == .images)
        #expect(MacIDMCore.Category.from(fileName: "pic.webp") == .images)
        #expect(MacIDMCore.Category.from(fileName: "paper.pdf") == .documents)
    }
}
