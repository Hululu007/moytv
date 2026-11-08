Pod::Spec.new do |spec|
  spec.name = 'QuickJSBridge'
  spec.version = '0.1.0'
  spec.summary = '魔蚁box iOS QuickJS 桥（moyi/quickjs）'
  spec.homepage = 'https://github.com/fish2018/guoapp'
  spec.author = '短剧视界 contributors'
  spec.source = { :path => '.' }
  spec.license = { :type => 'See application repository' }
  spec.ios.deployment_target = '15.0'
  spec.source_files = 'Sources/**/*.{m,c,h}'
  spec.public_header_files = 'Sources/*.h'
  spec.static_framework = true
  spec.dependency 'Flutter'
  spec.frameworks = 'Foundation'
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '$(inherited) $(PODS_TARGET_SRCROOT)/Sources/quickjs',
    'OTHER_CFLAGS' => '$(inherited) -DCONFIG_VERSION=\\"2024-01-13\\" -DCONFIG_BIGNUM'
  }
end
