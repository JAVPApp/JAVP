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

  # Cargo's default LC_ID_DYLIB is an absolute build-machine path. If we leave
  # that in place, the shipped javp binary records LC_LOAD_DYLIB →
  # /Users/<builder>/…/librqbit_engine.dylib and crashes at launch on every
  # other Mac (dyld "Library missing"). Force an @rpath id at link time and
  # again after copy so prebuilts are covered too.
  rpath_id = '@rpath/librqbit_engine.dylib'
  rustflags = "-C link-arg=-Wl,-install_name,#{rpath_id}"

  unless ENV['RQBIT_ENGINE_SKIP_CARGO'] == '1'
    abort('rqbit_engine: cargo not found. Install rustup (https://rustup.rs).') unless system('cargo', '--version')
    cmd = [
      'cargo', 'build', '--release',
      '--manifest-path', File.join(crate, 'Cargo.toml'),
      '--target-dir', target_dir,
    ]
    cmd += ['--target', rust_target] if rust_target
    env = ENV.to_h
    # Append so callers can still pass other RUSTFLAGS.
    existing = env['RUSTFLAGS'].to_s.strip
    env['RUSTFLAGS'] = existing.empty? ? rustflags : "#{existing} #{rustflags}"
    abort('rqbit_engine: cargo build failed') unless system(env, *cmd)
  end

  dylib = prebuilt if !File.exist?(dylib) && File.exist?(prebuilt)
  abort("rqbit_engine: missing #{dylib}") unless File.exist?(dylib)
  # CocoaPods rejects absolute vendored_libraries paths.
  require 'fileutils'
  bundled = File.expand_path('librqbit_engine.dylib', __dir__)
  FileUtils.cp(dylib, bundled)
  abort("rqbit_engine: install_name_tool failed for #{bundled}") unless system(
    'install_name_tool', '-id', rpath_id, bundled
  )
  # Rewriting LC_ID_DYLIB invalidates the ad-hoc signature cargo applied.
  abort("rqbit_engine: codesign failed for #{bundled}") unless system(
    'codesign', '--force', '--sign', '-', bundled
  )
  s.vendored_libraries = 'librqbit_engine.dylib'
end
