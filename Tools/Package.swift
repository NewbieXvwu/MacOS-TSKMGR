// swift-tools-version: 6.2
import PackageDescription

// Packaging note for the standalone runtime .app wrapper:
// The final macOS 26 app bundle must preserve:
// - AppIcon.icns
// - Assets.car
// - CFBundleIconFile = "AppIcon"
// - CFBundleIconName = "AppIcon"
// This keeps the newer macOS 26 icon presentation intact when packaging the
// executable outside the Xcode-generated app bundle.
enum RuntimeAppPackagingDefaults {
    static let appName = "MacOSTSKMGR"
    static let bundleIdentifier = "com.linqin.MacOSTSKMGR"
    static let minimumMacOSVersion = "26.0"
    static let iconBaseName = "AppIcon"
    static let requiresAssetCatalog = true
    static let requiresCFBundleIconName = true
}

let package = Package(
    name: "MacOSTSKMGRTools",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "thermal_probe", targets: ["thermal_probe"]),
        .library(name: "CPUFrequencyTierReference", targets: ["CPUFrequencyTierReference"])
    ],
    targets: [
        .executableTarget(
            name: "thermal_probe",
            path: ".",
            exclude: [
                "Package.swift",
                "ane_probe.swift",
                "cpu_frequency_tier_reference.swift",
                "package_swift_runtime_app.sh",
                "set_version.sh"
            ],
            sources: ["thermal_probe.swift"]
        ),
        .target(
            name: "CPUFrequencyTierReference",
            path: ".",
            exclude: [
                "Package.swift",
                "ane_probe.swift",
                "package_swift_runtime_app.sh",
                "set_version.sh",
                "thermal_probe.swift"
            ],
            sources: ["cpu_frequency_tier_reference.swift"]
        )
    ]
)
