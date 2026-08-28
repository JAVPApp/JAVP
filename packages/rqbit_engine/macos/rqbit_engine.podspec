Pod::Spec.new do |s|
  s.name             = 'rqbit_engine'
  s.version          = '0.1.0'
  s.summary          = 'Embedded librqbit HTTP API for JAVP.'
  s.homepage         = 'https://javp.app'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'JAVP' => 'dev@javp.app' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  crate = File.expand_path('../rust', __dir__)
  target_dir = File.expand_path('build/rust-target', __dir__)
  arch = ENV['FLUTTER_XCODE_ARCHS'].to_s.strip
  arch = ENV['ARCHS'].to_s.split.first.to_s if arch.empty?
  rust_target = case arch
                when 'x86_64' then 'x86_64-apple-darwin'
                when 'arm64' then 'aarch64-apple-darwin'
                end
  out_dir = rust_target ? File.join(target_dir, rust_target, 'release') : File.join(target_dir, 'release')
  dylib = File.join(out_dir, 'librqbit_engine.dylib')
  prebuilt_arch = arch.empty? ? 'arm64' : arch
  prebuilt = File.expand_path("../prebuilt/macos/#{prebuilt_arch}/librqbit_engine.dylib", __dir__)

  unless ENV['RQBIT_ENGINE_SKIP_CARGO'] == '1'
    abort('rqbit_engine: cargo not found. Install rustup (https://rustup.rs).') unless system('cargo', '--version')
    cmd = [
      'cargo', 'build', '--release',
      '--manifest-path', File.join(crate, 'Cargo.toml'),
      '--target-dir', target_dir,
    ]
    cmd += ['--target', rust_target] if rust_target
    abort('rqbit_engine: cargo build failed') unless system(*cmd)
  end

  dylib = prebuilt if !File.exist?(dylib) && File.exist?(prebuilt)
  abort("rqbit_engine: missing #{dylib}") unless File.exist?(dylib)
  # CocoaPods rejects absolute vendored_libraries paths.
  require 'fileutils'
  bundled = File.expand_path('librqbit_engine.dylib', __dir__)
  FileUtils.cp(dylib, bundled)
  s.vendored_libraries = 'librqbit_engine.dylib'
end
