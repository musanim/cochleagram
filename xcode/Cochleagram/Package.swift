// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cochleagram",
    platforms: [.macOS(.v12)],
    targets: [
        // Plain C ABI over a C++ implementation, so the same core can be
        // lifted into an AU/VST plugin or a command-line tool unchanged.
        .target(
            name: "CochleaDSP",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CochleagramApp",
            dependencies: ["CochleaDSP"],
            // One baked coefficient file per ERB scale. Listed rather
            // than globbed so a missing bake is a build error, not a
            // menu entry that fails at runtime.
            resources: [
                .copy("Resources/cochlea_88200_erb050.coch"),
                .copy("Resources/cochlea_88200_erb060.coch"),
                .copy("Resources/cochlea_88200_erb070.coch"),
                .copy("Resources/cochlea_88200_erb080.coch"),
                .copy("Resources/cochlea_88200_erb090.coch"),
                .copy("Resources/cochlea_88200_erb100.coch"),
                .copy("Resources/cochlea_88200_erb110.coch"),
                .copy("Resources/cochlea_88200_erb120.coch"),
                .copy("Resources/cochlea_88200_erb130.coch"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
