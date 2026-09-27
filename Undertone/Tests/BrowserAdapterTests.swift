import Foundation
import JavaScriptCore
@main struct BrowserAdapterTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Undertone/SpotifyController.swift", encoding: .utf8)
        let start = source.range(of: "        let js = \"\"\"\n")!.upperBound
        let end = source.range(of: "\n        \"\"\"", range: start..<source.endIndex)!.lowerBound
        let template = String(source[start..<end])
        func run(_ setup: String, command: String = "") -> String {
            let context = JSContext()!
            context.evaluateScript(setup)
            let result = context.evaluateScript(template.replacingOccurrences(of: "\\(command)", with: command))
            assert(context.exception == nil, context.exception?.toString() ?? "JavaScript failed")
            return result!.toString()
        }
        let fixture = """
        var first={paused:true,duration:100,currentTime:5,volume:0.5,currentSrc:'first'};
        var active={paused:false,duration:240,currentTime:42,volume:0.75,currentSrc:'second',pause(){this.paused=true}};
        var document={title:'Page',querySelectorAll(){return [first,active]}};
        var location={hostname:'example.com',href:'https://example.com'};
        var navigator={mediaSession:{metadata:{title:'Song',artist:'Artist',album:'Album',artwork:[{src:'https://example.com/cover.png'}]}}};
        """
        func decode(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [String: Any] }
        let normal = decode(run(fixture)); assert(normal["id"] as? String == "second"); assert(normal["title"] as? String == "Song"); assert(normal["duration"] as? Int == 240)
        let paused = decode(run(fixture, command: "m.pause();")); assert(paused["playing"] as? Bool == false)
        let seek = decode(run(fixture, command: "m.currentTime=120;")); assert(seek["position"] as? Int == 120)
        let stream = decode(run(fixture + "active.duration=Infinity; navigator.mediaSession.metadata=null;")); assert(stream["duration"] as? Int == 0); assert(stream["title"] as? String == "Page")
        assert(run(fixture + "document.querySelectorAll=()=>[];") == "")
        print("PASS: browser adapter active-media selection, metadata, pause, seek, live streams and empty pages")
    }
}
