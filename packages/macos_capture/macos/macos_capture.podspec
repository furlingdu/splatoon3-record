Pod::Spec.new do |s|
  s.name             = 'macos_capture'
  s.version          = '0.1.0'
  s.summary          = 'Native macOS capture for Splatoon3 Record.'
  s.description      = 'AVFoundation capture with NV12 frames piped into FFmpeg.'
  s.homepage         = 'https://github.com/furlingdu/splatoon3-record-flutter'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'furlingdu' => 'furlingdu@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
