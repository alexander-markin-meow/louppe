// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Louppe",
    platforms: [.macOS(.v14)],
    targets: [
        // Use Sparkle's checksum-pinned public binary directly. This avoids a
        // source-control checkout (and therefore never needs GitHub credentials).
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
        ),
        .target(
            name: "XMPBridge",
            path: "Sources/XMPBridge",
            sources: [
                "XMPBridge.mm",
                "Vendor/Expat/expat/lib/xmlparse.c",
                "Vendor/Expat/expat/lib/xmlrole.c",
                "Vendor/Expat/expat/lib/xmltok.c",
                "Vendor/XMPToolkit/XMPCore/source/WXMPIterator.cpp",
                "Vendor/XMPToolkit/XMPCore/source/WXMPMeta.cpp",
                "Vendor/XMPToolkit/XMPCore/source/WXMPUtils.cpp",
                "Vendor/XMPToolkit/XMPCore/source/CoreObjectFactoryImpl.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPIterator.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPIterator2.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPMeta-GetSet.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPMeta-Parse.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPMeta-Serialize.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPMeta.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPMeta2-GetSet.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPUtils-FileInfo.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPUtils.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPUtils2.cpp",
                "Vendor/XMPToolkit/XMPCore/source/ExpatAdapter.cpp",
                "Vendor/XMPToolkit/XMPCore/source/ParseRDF.cpp",
                "Vendor/XMPToolkit/XMPCore/source/XMPCore_Impl.cpp",
                "Vendor/XMPToolkit/source/UnicodeConversions.cpp",
                "Vendor/XMPToolkit/source/XML_Node.cpp",
                "Vendor/XMPToolkit/source/XMP_LibUtils.cpp",
                "Vendor/XMPToolkit/third-party/zuid/interfaces/MD5.cpp",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Vendor/XMPToolkit"),
                .headerSearchPath("Vendor/XMPToolkit/public/include"),
                .headerSearchPath("Vendor/XMPToolkit/XMPCore/resource/mac"),
                .headerSearchPath("Vendor/Expat/expat/lib"),
            ],
            cxxSettings: [
                .define("MAC_ENV", to: "1"),
                .define("XMP_64", to: "1"),
                .define("XMP_StaticBuild", to: "1"),
                .define("BUILDING_XMPCORE_LIB", to: "1"),
                .define("BUILDING_XMPCORE_AS_STATIC", to: "1"),
                .define("ENABLE_CPP_DOM_MODEL", to: "0"),
                .define(
                    "XMP_COMPONENT_INT_NAMESPACE",
                    to: "AdobeXMPCore_Int"
                ),
                .define("BanAllEntityUsage", to: "1"),
                .headerSearchPath("Vendor/XMPToolkit"),
                .headerSearchPath("Vendor/XMPToolkit/public/include"),
                .headerSearchPath("Vendor/XMPToolkit/XMPCore/resource/mac"),
                .headerSearchPath("Vendor/Expat/expat/lib"),
                .unsafeFlags([
                    "-Wno-deprecated-declarations",
                    "-Wno-register",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .executableTarget(
            name: "Louppe",
            dependencies: ["Sparkle", "XMPBridge"],
            path: "Sources/Louppe",
            linkerSettings: [
                // The release executable lives in Louppe.app/Contents/MacOS
                // and Sparkle is embedded in Louppe.app/Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "LouppeTests",
            dependencies: ["Louppe"],
            path: "Tests/LouppeTests"
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
