// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeribenimKit",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13)],
    products: [
        .library(name: "VeribenimKit", targets: ["VeribenimKit"]),
    ],
    targets: [
        // Sıfır üçüncü parti bağımlılık: rıza SDK'sı uygulamanın bağımlılık
        // ağacını kirletmemeli. Firebase köprüsü opsiyoneldir ve reflection
        // yerine uygulamanın kendi callback'i üzerinden kurulur.
        .target(name: "VeribenimKit"),
        .testTarget(name: "VeribenimKitTests", dependencies: ["VeribenimKit"]),
    ]
)
