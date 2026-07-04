# ja0 SDK (mtracker) — 배포 채널

앱에 넣어 쓰는 **ja0 SDK(mtracker)** 의 공개 배포 저장소입니다. 설치·세션·잔존·어트리뷰션
측정과 네이티브 광고 지면을 제공합니다. 연동 가이드/기능 설명: <https://mtracker.ja0.com/sdk>.

- **무인증 공개 배포** — 별도 토큰/계정 없이 아래 좌표로 바로 받습니다.
- 담긴 것: **Android AAR**(정적 Maven), **React Native 패키지**(tarball), **Flutter 플러그인**,
  **iOS**(Swift Package / CocoaPods 소스).
- 현재 최신 **v1.0.1** (네 플랫폼 lockstep).

> **버전 정책 — 아래 설치 예시는 항상 최신(main)을 가져오도록 되어 있습니다.**
> - **최신 자동**: `main` 브랜치 / `latest.release` 를 그대로 쓰면 새 릴리스가 자동 반영됩니다.
>   (단, 빌드 도구가 캐시하므로 *매 빌드* 갱신하려면 각 항목의 캐시 무효화 옵션을 참고하세요.)
> - **버전 고정(재현성)**: 특정 버전이 필요하면 `main` 대신 태그 `vX.Y.Z`(예: `v1.0.1`),
>   Android는 `latest.release` 대신 `1.0.1` 로 바꿔 핀하면 됩니다.

키 발급: `sdkKey`/`sdkSecret`/`appId`는 콘솔 <https://admin.ja0.com/> 에서 발급하거나
<help-myshop@mocoplex.com> 로 문의하세요.

---

## Android — 정적 Maven 저장소

`raw.githubusercontent.com`에서 바로 resolve합니다(무인증).

```kotlin
// settings.gradle.kts — dependencyResolutionManagement { repositories { … } }
// main = 항상 최신 (고정하려면 main 대신 태그, 예: v1.0.1)
maven { url = uri("https://raw.githubusercontent.com/mocoplex-corp/mtracker-sdk/main/maven") }
google(); mavenCentral()   // 전이 의존성(androidx, play-review 등) 해석용

// app/build.gradle.kts
dependencies {
    implementation("io.ja0tracker:ja0tracker-android:latest.release")  // 최신 자동 (고정: "1.0.1")
}

// (선택) 매 빌드 최신 재확인 — Gradle 동적 버전 캐시 무효화
configurations.all {
    resolutionStrategy.cacheDynamicVersionsFor(0, "seconds")
    resolutionStrategy.cacheChangingModulesFor(0, "seconds")
}
```

`minSdk 24`, `compileSdk 34`. Play Install Referrer로 결정적 어트리뷰션.

---

## React Native — tarball 설치

레지스트리 없이 tarball URL로 설치합니다(무인증).

```bash
npm install https://raw.githubusercontent.com/mocoplex-corp/mtracker-sdk/main/react-native/mocoplex-corp-ja0tracker-react-native-1.0.1.tgz
cd ios && pod install   # iOS 네이티브는 별도(아래 iOS 참고)
```

```ts
import { Ja0Tracker } from '@mocoplex-corp/ja0tracker-react-native';
Ja0Tracker.initialize({ sdkKey: 'pk_...', sdkSecret: 'sk_...', appId: 'YOUR_APP_ID' });
```

- Android 브리지는 Core AAR(`...:latest.release` (main) · 고정 `:1.0.1`)에 의존 → 위 **Android Maven
  저장소도 함께 등록**하세요.
- New Architecture(TurboModule/Fabric) 및 레거시 브리지 모두 지원.

---

## Flutter — git 의존성

Flutter 플러그인은 바이너리 형태가 없어 **git 의존성**(소스)으로 배포합니다(무인증).

```yaml
# pubspec.yaml
dependencies:
  ja0tracker:
    git:
      url: https://github.com/mocoplex-corp/mtracker-sdk.git
      ref: main            # 최신 자동 (고정하려면 v1.0.1)
      path: flutter
```

```dart
await Ja0Tracker.instance.initialize(Ja0TrackerConfig(sdkKey: 'pk_...', sdkSecret: 'sk_...', appId: 'YOUR_APP_ID'));
```

- Flutter Android도 Core AAR에 의존 → 위 **Android Maven 저장소 등록** 필요.

---

## iOS — Swift Package / CocoaPods (소스)

iOS SDK 소스가 이 저장소 `ios/` 에 담겨 있고, 루트 `Package.swift` 로 SPM 좌표를 노출합니다.
바이너리(XCFramework)가 아니라 **소스**로 배포되므로 앱 빌드 시 함께 컴파일됩니다(무인증).

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/mocoplex-corp/mtracker-sdk.git", branch: "main")  // 최신 자동 (고정: from: "1.0.1")
]
```

Xcode: **File ▸ Add Package Dependencies…** 에 위 URL을 넣고 `Ja0TrackerSDK` 라이브러리를 추가합니다.

### CocoaPods (소스 pod)

```ruby
# Podfile
pod 'Ja0TrackerSDK', :git => 'https://github.com/mocoplex-corp/mtracker-sdk.git', :branch => 'main'  # 최신 자동 (고정: :tag => 'v1.0.1')
```

```swift
import Ja0TrackerSDK
Ja0Tracker.shared.initialize(Ja0TrackerConfig(sdkKey: "pk_...", sdkSecret: "sk_...", appId: "YOUR_APP_ID"))
```

- **iOS 15+.** `NSUserTrackingUsageDescription`(ATT 문구)와 `SKAdNetworkItems` 를 호스트 앱
  `Info.plist` 에 추가해야 합니다. 개인정보 매니페스트(`PrivacyInfo.xcprivacy`)는 패키지에 동봉됩니다.
- RN/Flutter 의 iOS 네이티브도 이 Core 에 의존합니다.

---

## 좌표 요약 (v1.0.1)

| 플랫폼 | 방식 | 좌표 |
|---|---|---|
| Android | 정적 Maven (raw) | `...:latest.release` (main) · 고정 `:1.0.1` |
| React Native | tarball (raw) | `react-native/mocoplex-corp-ja0tracker-react-native-1.0.1.tgz` |
| Flutter | git ref + path | `ref: main` (최신) · 고정 `v1.0.1`, `path: flutter` |
| iOS | SPM (repo 루트 Package.swift) | `branch: "main"` (최신) · 고정 `from: "1.0.1")` |
| iOS | CocoaPods (소스 pod) | `:branch => 'main'` (최신) · 고정 `:tag => 'v1.0.1'` |

이 저장소의 아티팩트는 내부 모노레포에서 빌드되어 배포됩니다(빌드/릴리스 절차는 내부
`docs/sdk-github-release.md`). 버그/문의: <help-myshop@mocoplex.com>.
</content>
