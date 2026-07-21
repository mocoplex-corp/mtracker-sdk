// swift-tools-version:5.9
// ja0 SDK (mtracker) — iOS Swift Package (무인증 공개 배포)
//
// 이 저장소는 멀티플랫폼 배포 채널(Android/RN/Flutter + iOS)이다. 루트의 이
// Package.swift 는 iOS SDK 소스(ios/Sources/MTracker)만 노출하며, 다른 플랫폼
// 디렉토리(maven/·react-native/·flutter/)는 SPM 대상이 아니다.
//
//   .package(url: "https://github.com/mocoplex-corp/mtracker-sdk.git", from: "1.0.7")
//
// Apple 프레임워크만 사용(CryptoKit/StoreKit/AdAttributionKit/AppTrackingTransparency/
// UIKit/Security) — 서드파티 의존성 없음. macOS + Xcode(iOS 툴체인)에서 빌드된다.

import PackageDescription

let package = Package(
    name: "Ja0TrackerSDK",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "Ja0TrackerSDK",
            targets: ["Ja0TrackerSDK"]
        ),
    ],
    dependencies: [
        // No third-party deps in the Core — Apple frameworks only.
    ],
    targets: [
        // Module `Ja0TrackerSDK` ≠ public entry class `Ja0Tracker`, so a binary
        // XCFramework's .swiftinterface has no module/type name collision.
        // Source dir stays ios/Sources/MTracker.
        .target(
            name: "Ja0TrackerSDK",
            path: "ios/Sources/MTracker",
            resources: [
                // Privacy manifest is REQUIRED for App Store review.
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "MTrackerTests",
            dependencies: ["Ja0TrackerSDK"],
            path: "ios/Tests/MTrackerTests"
        ),
    ]
)
