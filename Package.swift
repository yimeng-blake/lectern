// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lectern",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lectern", targets: ["Lectern"]),
        .executable(name: "lectern-probe", targets: ["lectern-probe"]),
    ],
    targets: [
        // Backends, PDF text/context logic, process plumbing. No SwiftUI.
        .target(
            name: "LecternCore",
            path: "Sources/LecternCore"
        ),
        // The macOS app (SwiftUI + PDFKit + WKWebView).
        .executableTarget(
            name: "Lectern",
            dependencies: ["LecternCore"],
            path: "Sources/Lectern",
            // Resources/ (the chat page with its vendored libraries, and the optional AppIcon.icns) is
            // copied into the .app by scripts/build-app.sh instead of being a SwiftPM resource bundle,
            // whose generated accessor would embed the absolute build path in the binary. Unbundled
            // `swift run Lectern` finds the page in the source tree (TranscriptWebView).
            exclude: ["Resources"]
        ),
        // Headless CLI for exercising backends and context building without the GUI.
        .executableTarget(
            name: "lectern-probe",
            dependencies: ["LecternCore"],
            path: "Sources/lectern-probe"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
