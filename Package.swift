// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "a-watcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "a-watcher", targets: ["WatcherApp"]),
        .executable(name: "watcherctl", targets: ["WatcherCLI"]),
        .executable(name: "watcher-checks", targets: ["WatcherChecks"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "WatcherCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "WatcherApp", dependencies: ["WatcherCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "WatcherCLI", dependencies: ["WatcherCore"]),
        .executableTarget(name: "WatcherChecks", dependencies: ["WatcherCore"], path: "Tests/WatcherCoreTests")
    ]
)
