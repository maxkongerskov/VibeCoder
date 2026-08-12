// swift-tools-version: 5.10
//
// VibeCoder
// Successor to the original AgentOS DEV PLAN.
// See DESIGN.md for the full rationale.
//
// Two main targets (plus experimental Harness):
//   • AgentCore   — pure Swift library, the agent loop + backends + tools
//   • MLXBackend  — opt-in MLX adapter (Apple Silicon only)
//
// The SwiftUI app lives in App/ and links AgentCore via XcodeGen.
// See App/project.yml.
//
// Interactive agentos CLI removed — native app is primary.
// EvalRunner is a thin headless executable for Evals/eval.sh only.
//
import PackageDescription

let package = Package(
    // SPM package name (historical). Shipping product is AppBranding.displayName = "VibeCoder".
    name: "VibeCoder",
    platforms: [
        // macOS 14 is the floor — same as the original. Apple Silicon only,
        // but that's enforced at runtime, not by the platform clause, so the
        // package itself can build on Linux for CI compile-checks.
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "MLXBackend", targets: ["MLXBackend"]),
        // Harness — experimental algorithm sandbox (ArgumentCoercer, etc.).
        // Depends on AgentCore; **not** linked by the app. Prefer extracting
        // algorithms into AgentCore over growing a second runtime.
        .library(name: "Harness", targets: ["Harness"]),
        // Headless agent loop for the eval harness (replaces removed agentos CLI).
        .executable(name: "eval-runner", targets: ["EvalRunner"]),
        // Pure helpers shared by eval-runner CLI + unit tests (PB6).
        .library(name: "EvalRunnerLib", targets: ["EvalRunnerLib"]),
    ],
    dependencies: [
        // No remote package deps. App links AgentCore (+ optional MLXBackend stub)
        // only. Sparkle/Sentry were removed; mlx-swift not wired.
    ],
    targets: [
        .target(
            name: "AgentCore",
            path: "Sources/AgentCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "MLXBackend",
            dependencies: ["AgentCore"],
            path: "Sources/MLXBackend",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // Experimental sandbox — depends on AgentCore for ResponseNormalizer /
        // ChatLoop plan tools. Not the app daily driver (see README).
        .target(
            name: "Harness",
            dependencies: ["AgentCore"],
            path: "Sources/Harness",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // PB6: pure JSONL event + conversation I/O helpers for eval-runner.
        .target(
            name: "EvalRunnerLib",
            dependencies: ["AgentCore"],
            path: "Sources/EvalRunner",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "EvalRunner",
            dependencies: ["AgentCore", "EvalRunnerLib"],
            path: "Sources/EvalRunnerCLI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"],
            path: "Tests/AgentCoreTests"
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"],
            path: "Tests/HarnessTests"
        ),
        .testTarget(
            name: "EvalRunnerLibTests",
            dependencies: ["EvalRunnerLib", "AgentCore"],
            path: "Tests/EvalRunnerLibTests"
        ),
    ]
)
