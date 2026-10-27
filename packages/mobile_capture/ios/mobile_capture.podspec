Pod::Spec.new do |s|
  s.name             = 'mobile_capture'
  s.version          = '0.1.0'
  s.summary          = 'Native capture for Android and iOS.'
  s.description      = 'AVFoundation capture, preview and segmented recording.'
  s.homepage         = 'https://github.com/furlingdu/splatoon3-record-flutter'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'furlingdu' => 'furlingdu@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
