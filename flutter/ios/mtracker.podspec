#
# mtracker (Flutter) — iOS plugin podspec.
#
# Thin Pigeon + PlatformView bridge to the shared iOS Core (the `Ja0Tracker` Swift package /
# XCFramework at sdk/ios). DELEGATES to the Core; does not duplicate it.
#
Pod::Spec.new do |s|
  s.name             = 'mtracker'
  s.version          = '1.0.0'
  s.summary          = 'mtracker Flutter SDK (iOS plugin) — thin wrapper over the Ja0TrackerSDK Core.'
  s.description      = <<-DESC
Attribution, in-app events, deferred deep links, and native ad slots for Flutter. Wraps the
native iOS Core (Ja0Tracker) via Pigeon + PlatformView.
                       DESC
  s.homepage         = 'https://github.com/mocoplex/mtracker'
  s.license          = { :type => 'Proprietary', :text => 'UNLICENSED' }
  s.author           = { 'mocoplex' => 'dev@mocoplex.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'

  s.dependency 'Flutter'

  # The shared native Core — DELEGATE, never duplicate.
  # Ship an Ja0TrackerSDK.podspec (XCFramework/source) from sdk/ios and depend on it here:
  s.dependency 'Ja0TrackerSDK'   # provides `import Ja0TrackerSDK`

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
