// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Convertmax",
    platforms: [.iOS(.v15)],
    products: [.library(name: "Convertmax", targets: ["Convertmax"])],
    targets: [
        .target(name: "Convertmax"),
        .testTarget(name: "ConvertmaxTests", dependencies: ["Convertmax"])
    ]
)
