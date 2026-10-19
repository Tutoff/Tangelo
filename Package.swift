// swift-tools-version:6.0
import Foundation
import PackageDescription

/// The CLI doubles as the app's conversion helper; an embedded Info.plist gives it its own bundle identity
/// so it never registers with LaunchServices as a second "Tangelo".
let workerPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Worker-Info.plist").path

let package = Package(
    name: "Tangelo",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tangelo", targets: ["Tangelo"]),
        .executable(name: "tangelo-cli", targets: ["TangeloCLI"]),
    ],
    targets: [
        .target(name: "TangeloCore", path: "Sources/TangeloCore"),
        .executableTarget(name: "Tangelo", dependencies: ["TangeloCore"], path: "Sources/Tangelo"),
        .executableTarget(name: "TangeloCLI", dependencies: ["TangeloCore"], path: "Sources/TangeloCLI",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", workerPlist])]),
    ],
    swiftLanguageModes: [.v5]
)
