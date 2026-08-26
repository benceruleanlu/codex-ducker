import AppKit
import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--policy-check") {
    do {
        try runOutputPolicySelfTest()
        try runPreferredInputPolicySelfTest()
        print("Audio policy tests passed")
        exit(0)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--pipeline-check") {
    let engine = DuckingEngine(enabled: true, duckGain: 0.2, monitorsDevices: false)
    print(engine.pipelineDiagnosticReport())
    let failed = engine.state.menuText.hasPrefix("Needs attention")
    engine.shutdown()
    exit(failed ? 1 : 0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
