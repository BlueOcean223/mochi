import Foundation
import Testing
@testable import MochiCore

@Test func versionsCompareByNumber() throws {
    let v = { (text: String) in try #require(AppVersion(text)) }
    #expect(try v("0.10.0") > v("0.9.9"))
    #expect(try v("v1.2") == v("1.2.0"))
    #expect(try v("1.2.1") > v("1.2"))
    #expect(try v("2.0.0-beta.1") == v("2.0.0"))
    #expect(try v("v0.2.0").description == "0.2.0")
    #expect(AppVersion("latest") == nil)
    #expect(AppVersion("1..2") == nil)
    #expect(AppVersion("") == nil)
}

@Test func decodesTheLatestRelease() throws {
    let json = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/o/r/releases/tag/v0.2.0", "body": "- 新的",
         "draft": false, "prerelease": false,
         "assets": [
           {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt", "size": 10},
           {"name": "Mochi-0.2.0.zip", "browser_download_url": "https://example.com/Mochi-0.2.0.zip", "size": 2048}
         ]}
        """
    let release = try Release.decode(Data(json.utf8))
    #expect(release.version == AppVersion("0.2.0"))
    #expect(release.notes == "- 新的")
    #expect(release.archive?.name == "Mochi-0.2.0.zip")
    #expect(release.archive?.size == 2048)
}

@Test func releaseWithoutTheAppHasNoArchive() throws {
    let json = #"{"tag_name": "v0.2.0", "html_url": "https://example.com", "body": null, "assets": []}"#
    let release = try Release.decode(Data(json.utf8))
    #expect(release.archive == nil)
    #expect(release.notes == nil)
}
