# ja0 SDK (mtracker) — 배포 채널

앱에 넣어 쓰는 **ja0 SDK(mtracker)** 의 공개 배포 저장소입니다. 설치·세션·잔존·어트리뷰션
측정과 네이티브 광고 지면을 제공합니다. 연동 가이드/기능 설명: <https://mtracker.ja0.com/sdk>.

- **무인증 공개 배포** — 별도 토큰/계정 없이 아래 좌표로 바로 받습니다.
- 담긴 것: **Android AAR**(정적 Maven), **React Native 패키지**(tarball), **Flutter 플러그인**.
- **iOS 제외** — CocoaPods/XCFramework는 macOS 빌드가 필요해 이 저장소에 포함하지 않습니다.
- 현재 버전 **v1.0.0** (네 플랫폼 lockstep).

키 발급: `sdkKey`/`sdkSecret`/`appId`는 콘솔 <https://admin.ja0.com/> 에서 발급하거나
<help-myshop@mocoplex.com> 로 문의하세요.

---

## Android — 정적 Maven 저장소

`raw.githubusercontent.com`에서 바로 resolve합니다(무인증).

```kotlin
// settings.gradle.kts — dependencyResolutionManagement { repositories { … } }
maven { url = uri("https://raw.githubusercontent.com/mocoplex-corp/mtracker-sdk/v1.0.0/maven") }
google(); mavenCentral()   // 전이 의존성(androidx, play-review 등) 해석용

// app/build.gradle.kts
dependencies {
    implementation("io.mtracker:mtracker-android:1.0.0")
}
```

`minSdk 24`, `compileSdk 34`. Play Install Referrer로 결정적 어트리뷰션.

---

## React Native — tarball 설치

레지스트리 없이 tarball URL로 설치합니다(무인증).

```bash
npm install https://raw.githubusercontent.com/mocoplex-corp/mtracker-sdk/v1.0.0/react-native/mocoplex-corp-mtracker-react-native-1.0.0.tgz
cd ios && pod install   # iOS 네이티브는 별도(아래 iOS 참고)
```

```ts
import { MTracker } from '@mocoplex-corp/mtracker-react-native';
MTracker.initialize({ sdkKey: 'pk_...', sdkSecret: 'sk_...', appId: 'YOUR_APP_ID' });
```

- Android 브리지는 Core AAR(`io.mtracker:mtracker-android:1.0.0`)에 의존 → 위 **Android Maven
  저장소도 함께 등록**하세요.
- New Architecture(TurboModule/Fabric) 및 레거시 브리지 모두 지원.

---

## Flutter — git 의존성

Flutter 플러그인은 바이너리 형태가 없어 **git 의존성**(소스)으로 배포합니다(무인증).

```yaml
# pubspec.yaml
dependencies:
  mtracker:
    git:
      url: https://github.com/mocoplex-corp/mtracker-sdk.git
      ref: v1.0.0
      path: flutter
```

```dart
await MTracker.initialize(MTrackerConfig(sdkKey: 'pk_...', sdkSecret: 'sk_...', appId: 'YOUR_APP_ID'));
```

- Flutter Android도 Core AAR에 의존 → 위 **Android Maven 저장소 등록** 필요.

---

## iOS (이 저장소에서 제외)

iOS SDK(및 RN/Flutter의 iOS 네이티브)는 **macOS + Xcode**에서만 빌드됩니다. 이 무인증 공개
경로에는 포함하지 않으며, macOS 환경에서 Swift Package/CocoaPods로 별도 배포합니다. 필요 시
<help-myshop@mocoplex.com> 로 문의하세요.

---

## 좌표 요약 (v1.0.0)

| 플랫폼 | 방식 | 좌표 |
|---|---|---|
| Android | 정적 Maven (raw) | `io.mtracker:mtracker-android:1.0.0` |
| React Native | tarball (raw) | `react-native/mocoplex-corp-mtracker-react-native-1.0.0.tgz` |
| Flutter | git ref + path | `ref: v1.0.0`, `path: flutter` |

이 저장소의 아티팩트는 내부 모노레포에서 빌드되어 배포됩니다(빌드/릴리스 절차는 내부
`docs/sdk-github-release.md`). 버그/문의: <help-myshop@mocoplex.com>.
</content>
