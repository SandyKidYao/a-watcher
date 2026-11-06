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
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "WatcherCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "WatcherApp", dependencies: ["WatcherCore"]),
        .executableTarget(name: "WatcherCLI", dependencies: ["WatcherCore"]),
        .executableTarget(name: "WatcherChecks", dependencies: ["WatcherCore"], path: "Tests/WatcherCoreTests")
    ]
)
