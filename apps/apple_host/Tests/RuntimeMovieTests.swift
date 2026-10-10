import Foundation
import CoreGraphics

@main struct RuntimeMovieTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let movie = root.appendingPathComponent("fixtures/movie.avi")
        func argument(_ skip: Bool) -> String { "\(movie.path)\t320\t180\t80\t60\t\(skip ? 1 : 0)" }
        let request = try RuntimeMovieRequest(argument(true))
        precondition(request.skippable && request.rectangle == CGRect(x:80,y:60,width:320,height:180))
        precondition(request.displayRectangle(canvas:CGSize(width:640,height:480), viewport:CGSize(width:800,height:480)) == CGRect(x:160,y:60,width:320,height:180))
        for bad in ["movie.avi\t320\t180\t0\t0\t1", "\(movie.path)\t0\t180\t0\t0\t1", "\(movie.path)\t320\t180\t0\t0\t2", "bad", "\(movie.path)\t320\t180\t0\t0\t1\textra"] {
            do { _ = try RuntimeMovieRequest(bad); preconditionFailure("malformed accepted") } catch {}
        }
        var input = RuntimeMovieInputState()
        precondition(input.consumePointer(type: UInt32(ENGINE_INPUT_EVENT_POINTER_DOWN.rawValue),button:0,movieActive:true))
        precondition(input.consumePointer(type: UInt32(ENGINE_INPUT_EVENT_POINTER_MOVE.rawValue),button:0,movieActive:false))
        precondition(input.consumePointer(type: UInt32(ENGINE_INPUT_EVENT_POINTER_UP.rawValue),button:0,movieActive:false))
        precondition(!input.consumePointer(type: UInt32(ENGINE_INPUT_EVENT_POINTER_DOWN.rawValue),button:0,movieActive:false))
        precondition(input.consumeKey(pressed:true,key:32,movieActive:true))
        precondition(input.consumeKey(pressed:true,key:32,movieActive:false), "skip key repeat leaked to resumed script")
        precondition(input.consumeKey(pressed:false,key:32,movieActive:false))
        precondition(!input.consumeKey(pressed:true,key:32,movieActive:false))
        input.reset()
        var engine: engine_handle_t?
        var desc = engine_create_desc_t(); desc.struct_size = UInt32(MemoryLayout<engine_create_desc_t>.size); desc.api_version = ENGINE_API_VERSION
        try FileManager.default.createDirectory(at:root.appendingPathComponent("cache"),withIntermediateDirectories:true)
        let status = root.path.withCString { writable in root.appendingPathComponent("cache").path.withCString { cache in
            desc.writable_path_utf8 = writable; desc.cache_path_utf8 = cache
            return engine_create(&desc,&engine)
        } }
        precondition(status == ENGINE_RESULT_OK && engine != nil)
        defer { engine_destroy(engine) }
        let controller = RuntimeMovieController()
        var responses:[String] = []; var failures:[String] = []; var activity:[Bool] = []
        controller.submit = { responses.append($0) }
        controller.failure = { failures.append($0) }
        controller.activityChanged = { activity.append($0) }
        controller.log = { print($0) }
        func pump(_ seconds: Double) {
            let deadline=Date().addingTimeInterval(seconds)
            while Date() < deadline { controller.update(); RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        }
        func parentAlive() {
            var state:UInt32 = 0
            precondition(engine_get_startup_state(engine,&state) == ENGINE_RESULT_OK, "borrowed engine was destroyed")
        }
        controller.open(argument(true),engine:engine!); pump(0.4)
        precondition(controller.frame != nil && controller.frame!.width == 320)
        let captured = controller.frame!
        let oldBytes = captured.dataProvider!.data! as Data
        pump(0.2); precondition(oldBytes == captured.dataProvider!.data! as Data, "immutable frame")
        controller.skip(); controller.skip(); pump(0.1)
        precondition(responses == ["result=skipped"] && controller.frame == nil && !controller.isActive)
        parentAlive()
        controller.open(argument(false),engine:engine!); pump(0.2); controller.skip()
        precondition(controller.isActive && responses.count == 1, "unskippable must remain active")
        controller.reset(); controller.update()
        precondition(responses.count == 1 && controller.request == nil, "reset must not submit a completion")
        parentAlive()
        controller.open(argument(false),engine:engine!); pump(4.5)
        precondition(responses == ["result=skipped", "result=complete"] && !controller.isActive, "EOF resumes VM once")
        parentAlive()
        controller.open("bad",engine:engine!)
        precondition(responses.last == "result=error&message=media_playback_failed" && !failures.isEmpty)
        controller.open("\(root.path)/missing.avi\t320\t180\t0\t0\t1",engine:engine!)
        precondition(responses.count == 4 && !controller.isActive)
        controller.open(argument(true),engine:engine!); pump(0.2); controller.skip()
        precondition(responses.last == "result=skipped", "recover after failure")
        controller.submit = { _ in throw CocoaError(.fileWriteUnknown) }
        controller.open(argument(true),engine:engine!); controller.skip()
        precondition(!controller.isActive && failures.count == 3, "response error closes media and reports failure")
        controller.reset(); controller.reset(); parentAlive()
        precondition(activity.first == true && activity.last == false)
        print("PASS: movie protocol/placement, skip press/repeat/release isolation, borrowed engine lifetime, frames, skip/unskippable, EOF, one response, reset, failures and recovery")
    }
}
