// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HealthCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HealthCore", targets: ["HealthCore"]),
               .executable(name: "HealthCoreChecks", targets: ["HealthCoreChecks"]),
               .executable(name: "NativeCoreChecks", targets: ["NativeCoreChecks"])],
    targets: [
        .target(name: "HealthCore", path: "Shared"),
        // Command Line Tools lack XCTest; these real Swift checks also run without Xcode.
        .executableTarget(name: "HealthCoreChecks", dependencies: ["HealthCore"], path: "Checks"),
        .executableTarget(name: "NativeCoreChecks", dependencies: ["HealthCore"], path: "NativeChecks")
    ]
)
