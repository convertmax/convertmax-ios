// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Convertmax",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Convertmax", targets: ["Convertmax"])],
    targets: [
        .target(
            name: "Convertmax",
            resources: [.process("PrivacyInfo.xcprivacy")],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]
        ),
        .testTarget(name: "ConvertmaxTests", dependencies: ["Convertmax"])
    ]
)
