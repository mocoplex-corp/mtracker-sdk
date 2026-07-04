Pod::Spec.new do |s|
  s.name             = 'Ja0TrackerSDK'
  s.version          = '1.0.0'
  s.summary          = 'ja0 SDK (mtracker) — iOS attribution, sessions, deep links, native ads.'
  s.description      = <<-DESC
    Native iOS Core for mtracker: SKAdNetwork 4 + AdAttributionKit attribution,
    a durable offline event queue, session tracking, deferred/live deep links,
    and native ad slots. Apple frameworks only — no third-party dependencies.
  DESC
  s.homepage         = 'https://mtracker.ja0.com/sdk'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Mocoplex. All rights reserved.' }
  s.author           = { 'Mocoplex' => 'help-myshop@mocoplex.com' }

  # 무인증 공개 배포: Podfile 에서 :git + :tag 로 소스 설치 (소스 pod → 앱 빌드시 컴파일).
  s.source           = { :git => 'https://github.com/mocoplex-corp/mtracker-sdk.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  s.source_files     = 'ios/Sources/MTracker/**/*.swift'
  s.resource_bundles = { 'Ja0TrackerSDK' => ['ios/Sources/MTracker/PrivacyInfo.xcprivacy'] }

  s.frameworks       = 'Foundation', 'UIKit', 'Security', 'StoreKit', 'AppTrackingTransparency', 'AdSupport', 'CryptoKit'
  # AdAttributionKit is iOS 17.4+ — weak-link so the pod stays iOS 15 compatible.
  s.weak_frameworks  = 'AdAttributionKit'
end
