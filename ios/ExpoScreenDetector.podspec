require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoScreenDetector'
  s.version        = package['version']
  s.summary        = 'Expo module for detecting screen-off, screen-lock, and screen-unavailable state'
  s.description    = 'Detects whether the device screen is off, locked, or unavailable on iOS and Android'
  s.author         = 'sbigstar0310'
  s.homepage       = 'https://github.com/sbigstar0310/expo-screen-detector'
  s.license        = 'MIT'
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/sbigstar0310/expo-screen-detector.git', tag: s.version.to_s }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = '**/*.{h,m,swift}'
end
