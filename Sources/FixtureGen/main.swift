// Command-line fixture generator: `swift run fixturegen <outputDir>` writes
// every fixture in `FixtureCatalog.all` (deterministic bytes) into the
// directory. Scripts/generate-fixtures.sh runs it with Fixtures/.
import Foundation
import Fixtures

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1] != "--help", arguments[1] != "-h" else {
    FileHandle.standardError.write(Data("usage: fixturegen <outputDir>\n".utf8))
    exit(2)
}
let outputDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    let urls = try FixtureCatalog.writeAll(to: outputDir)
    var total = 0
    for url in urls {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        total += size
        print("\(url.lastPathComponent == url.path ? url.path : url.path.replacingOccurrences(of: outputDir.path + "/", with: ""))\t\(size) bytes")
    }
    print("wrote \(urls.count) fixtures, \(total) bytes total, to \(outputDir.path)")
} catch {
    FileHandle.standardError.write(Data("fixturegen: \(error)\n".utf8))
    exit(1)
}
