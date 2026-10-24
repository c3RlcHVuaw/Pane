// swift-tools-version: 6.0
import PackageDescription

let cefSources = [
    "bridge",
    "cef/libcef_dll/base", "cef/libcef_dll/cpptoc", "cef/libcef_dll/ctocpp", "cef/libcef_dll/wrapper",
    "cef/libcef_dll/shutdown_checker.cc", "cef/libcef_dll/transfer_util.cc",
]

// Layering: Pane (composition root) -> PaneUI / PaneCEF -> PaneEngine (protocols only).
// PaneUI, PaneCEF and the future PaneAssistant never import each other.
let package = Package(
    name: "Pane",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Pane", targets: ["Pane"])],
    targets: [
        .target(
            name: "CEFBridge",
            exclude: ["cef/Release", "cef/bazel", "cef/cmake", "cef/BUILD.bazel", "cef/CMakeLists.txt",
                      "cef/MODULE.bazel", "cef/WORKSPACE", "cef/README.txt", "cef/LICENSE.txt",
                      "cef/CREDITS.html", "cef/libcef_dll/CMakeLists.txt"],
            sources: cefSources,
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("cef"), .define("WRAPPING_CEF_SHARED")],
            cxxSettings: [
                .headerSearchPath("cef"), .define("WRAPPING_CEF_SHARED"),
                .unsafeFlags(["-fno-rtti", "-fno-exceptions", "-fobjc-call-cxx-cdtors", "-Wno-narrowing", "-Wno-undefined-var-template"]),
            ],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(name: "PaneEngine"),
        .target(name: "PaneModel"),
        .target(name: "PaneImport", dependencies: ["PaneModel"]),
        .target(name: "PaneSearch", dependencies: ["PaneModel"]),
        .target(name: "PaneUpdate", dependencies: ["PaneModel"]),
        .target(name: "PaneSync", dependencies: ["PaneModel"]),
        .target(name: "PaneAssistant", dependencies: ["PaneModel"]),
        .target(name: "PaneCEF", dependencies: ["CEFBridge", "PaneEngine"]),
        .target(name: "PaneUI", dependencies: ["PaneEngine", "PaneModel"]),
        .executableTarget(name: "Pane", dependencies: ["PaneCEF", "PaneUI", "PaneEngine", "PaneModel", "PaneImport", "PaneSearch", "PaneUpdate", "PaneSync", "PaneAssistant", "CEFBridge"]),
        .testTarget(name: "PaneUITests", dependencies: ["PaneUI", "PaneModel"]),
        .testTarget(name: "PaneModelTests", dependencies: ["PaneModel", "PaneImport", "PaneSearch", "PaneUpdate", "PaneSync", "PaneAssistant"]),
        .executableTarget(name: "PaneHelper", dependencies: ["CEFBridge"]),
    ],
    cxxLanguageStandard: .cxx20
)
