import Foundation
let sem = DispatchSemaphore(value: 0)
Task {
    for p in CommandLine.arguments.dropFirst() {
        do { let r = try await VideoReader(url: URL(fileURLWithPath: p)); print(URL(fileURLWithPath: p).lastPathComponent, "isHDR =", r.isHDR) }
        catch { print(p, "ERR", error) }
    }
    sem.signal()
}
sem.wait()
