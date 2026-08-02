# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'

module Drale
  module ComponentLibraryBrowser
    EXTENSION_VERSION = '0.2.0' unless const_defined?(:EXTENSION_VERSION)

    module Logger
      def self.info(*)
        nil
      end

      def self.warn(*)
        nil
      end

      def self.error(*)
        nil
      end
    end
  end
end

require_relative '../component_library_browser/services/updater'

class UpdaterContractTest < Minitest::Test
  Updater = Drale::ComponentLibraryBrowser::Updater

  Response = Struct.new(:code, :body, :headers) do
    def [](name)
      (headers || {})[name.to_s.downcase]
    end
  end

  def release_payload
    {
      'tag_name' => 'v0.3.0',
      'assets' => [
        { 'name' => 'component-library-browser-0.3.0.rbz', 'browser_download_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/component-library-browser-0.3.0.rbz' },
        { 'name' => 'component-library-browser-0.3.0.rbz.sha256', 'browser_download_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/component-library-browser-0.3.0.rbz.sha256' },
        { 'name' => 'source.zip', 'browser_download_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/archive/v0.3.0.zip' }
      ]
    }
  end

  def test_package_dir_is_the_extension_folder_not_the_plugins_root
    package_dir = Updater.package_dir

    assert_equal 'component_library_browser', File.basename(package_dir)
    assert_equal File.join(package_dir, 'VERSION'), Updater.version_file
    assert File.file?(Updater.version_file), 'VERSION must travel inside the extension package directory'
    refute_equal File.dirname(package_dir), package_dir
  end

  def test_latest_release_selects_matching_rbz_and_checksum_assets
    http_get = lambda do |uri, **_options|
      assert_equal Updater::API_RELEASES_URL, uri.to_s
      Response.new('200', JSON.generate(release_payload))
    end

    release = Updater.fetch_latest_release(http_get: http_get)

    assert_equal '0.3.0', release.fetch('version')
    assert_equal 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/component-library-browser-0.3.0.rbz', release.fetch('rbz_url')
    assert_equal 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/component-library-browser-0.3.0.rbz.sha256', release.fetch('checksum_url')
  end

  def test_release_without_matching_checksum_is_rejected
    payload = release_payload
    payload['assets'].delete_at(1)

    error = assert_raises(Updater::ReleaseError) do
      Updater.fetch_latest_release(http_get: ->(_uri, **_options) { Response.new('200', JSON.generate(payload)) })
    end

    assert_match(/checksum/i, error.message)
  end

  def test_checksum_requires_named_rbz_digest_and_matches_file
    Dir.mktmpdir('updater-contract-') do |dir|
      rbz = File.join(dir, 'release.rbz')
      File.binwrite(rbz, 'safe package')
      digest = Digest::SHA256.file(rbz).hexdigest

      assert Updater.verify_checksum!(rbz, "#{digest}  release.rbz\n")
      assert_raises(Updater::VerificationError) { Updater.verify_checksum!(rbz, "#{digest}  another.rbz\n") }
    end
  end

  def test_staged_package_requires_loader_version_and_runtime_directories
    Dir.mktmpdir('updater-contract-') do |dir|
      package = File.join(dir, 'component_library_browser')
      %w[icons ui tools services].each { |name| FileUtils.mkdir_p(File.join(package, name)) }
      File.write(File.join(dir, 'component_library_browser.rb'), '# loader')
      File.write(File.join(package, 'VERSION'), '0.3.0')

      validated = Updater.validate_staged_package!(dir, expected_version: '0.3.0')

      assert_equal package, validated.fetch('package_dir')
      assert_equal File.join(dir, 'component_library_browser.rb'), validated.fetch('loader')
    end
  end

  def test_staged_package_rejects_paths_outside_staging_root
    Dir.mktmpdir('updater-contract-') do |dir|
      outside = File.join(File.dirname(dir), 'component_library_browser')
      error = assert_raises(Updater::VerificationError) do
        Updater.assert_path_within!(dir, outside)
      end

      assert_match(/outside/i, error.message)
    end
  end

  def test_download_follows_bounded_https_redirects_for_trusted_release_asset_hosts
    calls = []
    http_get = lambda do |uri, **_options|
      calls << uri.to_s
      if calls.length == 1
        Response.new('302', '', 'location' => 'https://github-releases.githubusercontent.com/assets/release.rbz')
      else
        Response.new('200', 'signed rbz')
      end
    end

    Dir.mktmpdir('updater-download-') do |dir|
      target = File.join(dir, 'release.rbz')
      Updater.download_to!('https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/release.rbz', target, http_get: http_get)

      assert_equal 'signed rbz', File.binread(target)
      assert_equal 2, calls.length
      assert_match(%r{\Ahttps://github-releases\.githubusercontent\.com/}, calls.last)
    end
  end

  def test_download_rejects_redirect_to_untrusted_or_non_https_host
    http_get = ->(_uri, **_options) { Response.new('302', '', 'location' => 'http://example.test/release.rbz') }

    Dir.mktmpdir('updater-download-') do |dir|
      error = assert_raises(Updater::ReleaseError) do
        Updater.download_to!('https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/release.rbz', File.join(dir, 'release.rbz'), http_get: http_get)
      end
      assert_match(/HTTPS|trusted/i, error.message)
    end
  end

  def test_pending_update_staging_survives_target_package_move_and_cleans_up_after_success
    Dir.mktmpdir('pending-update-') do |dir|
      package = File.join(dir, 'component_library_browser')
      FileUtils.mkdir_p(package)
      File.write(File.join(package, 'old.rb'), 'old package')
      pending_root = File.join(dir, '.component_library_browser_update')
      staged = File.join(pending_root, 'staged')
      %w[icons ui tools services].each { |name| FileUtils.mkdir_p(File.join(staged, 'component_library_browser', name)) }
      File.write(File.join(staged, 'component_library_browser.rb'), '# loader')
      File.write(File.join(staged, 'component_library_browser', 'VERSION'), '0.3.0')
      rbz = File.join(pending_root, 'release.rbz')
      FileUtils.mkdir_p(pending_root)
      File.binwrite(rbz, 'safe pending archive')
      digest = Digest::SHA256.file(rbz).hexdigest
      File.write(File.join(pending_root, 'release.rbz.sha256'), "#{digest}  release.rbz\n")
      manifest = File.join(pending_root, 'pending_update.json')
      File.write(manifest, JSON.generate('version' => '0.3.0', 'asset_name' => 'release.rbz', 'checksum_name' => 'release.rbz.sha256', 'stage_name' => 'staged'))

      applied = false
      result = Updater.apply_pending_update(manifest_path: manifest, install: lambda do |validated, _workspace|
        FileUtils.mv(package, "#{package}.previous")
        assert File.file?(File.join(staged, 'component_library_browser', 'VERSION')), 'staged package must remain outside moved target package'
        FileUtils.cp_r(validated.fetch('package_dir'), package)
        applied = validated['version'] == '0.3.0'
      end)

      assert result['success']
      assert applied
      refute File.exist?(manifest)
      refute File.exist?(pending_root)
    end
  end

  def test_invalid_pending_update_is_preserved_without_install_for_retry
    Dir.mktmpdir('pending-update-') do |dir|
      package = File.join(dir, 'component_library_browser')
      FileUtils.mkdir_p(package)
      pending_root = File.join(dir, '.component_library_browser_update')
      FileUtils.mkdir_p(pending_root)
      manifest = File.join(pending_root, 'pending_update.json')
      File.write(manifest, '{"version":"0.3.0","stage_name":"../outside"}')

      result = Updater.apply_pending_update(manifest_path: manifest, install: ->(*) { flunk 'invalid pending update must not install' })

      assert result['retry_required']
      assert File.exist?(manifest)
    end
  end

  def test_extracts_a_safe_rbz_with_the_real_release_ui_directory_layout
    Dir.mktmpdir('updater-release-layout-') do |dir|
      output = File.join(dir, 'dist')
      script = File.expand_path('../scripts/build_rbz.ps1', __dir__)
      stdout, stderr, status = Open3.capture3(
        'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
        '-OutputDirectory', output, '-SelfTest'
      )
      assert status.success?, "RBZ fixture build failed:\n#{stdout}\n#{stderr}"

      rbz = File.join(output, 'component-library-browser-0.2.3.rbz')
      stage = File.join(dir, 'staged')
      Updater.send(:extract_rbz!, rbz, stage)

      validated = Updater.validate_staged_package!(stage, expected_version: '0.2.3')
      assert_equal '0.2.3', validated.fetch('version')
      assert File.file?(File.join(stage, 'component_library_browser', 'ui', 'app.js'))
    end
  end

  def test_rejects_a_backslash_parent_path_before_extracting
    Dir.mktmpdir('updater-unsafe-path-') do |dir|
      rbz = File.join(dir, 'unsafe.rbz')
      quoted_rbz = rbz.gsub("'", "''")
      script = <<~POWERSHELL
        Add-Type -AssemblyName System.IO.Compression
        $stream = [IO.File]::Open('#{quoted_rbz}', [IO.FileMode]::CreateNew)
        try {
          $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
          try { $zip.CreateEntry('component_library_browser\\..\\escape.txt').Open().Dispose() } finally { $zip.Dispose() }
        } finally { $stream.Dispose() }
      POWERSHELL
      _stdout, stderr, status = Open3.capture3('powershell', '-NoProfile', '-NonInteractive', '-Command', script)
      assert status.success?, stderr

      error = assert_raises(Updater::VerificationError) { Updater.send(:extract_rbz!, rbz, File.join(dir, 'staged')) }
      assert_match(/safe RBZ archive/i, error.message)
    end
  end

  def test_download_and_apply_update_reports_progress_for_download_checksum_and_staging
    Dir.mktmpdir('updater-progress-') do |dir|
      output = File.join(dir, 'dist')
      script = File.expand_path('../scripts/build_rbz.ps1', __dir__)
      _stdout, stderr, status = Open3.capture3('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-OutputDirectory', output, '-SelfTest')
      assert status.success?, stderr

      rbz = File.join(output, 'component-library-browser-0.2.3.rbz')
      checksum = "#{Digest::SHA256.file(rbz).hexdigest}  #{File.basename(rbz)}"
      update = {
        'available' => true,
        'latest_version' => '0.2.3',
        'asset_name' => File.basename(rbz),
        'rbz_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.2.3/component-library-browser-0.2.3.rbz',
        'checksum_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.2.3/component-library-browser-0.2.3.rbz.sha256'
      }
      installed = nil
      progress = []
      http_get = lambda do |uri, **_options|
        Response.new('200', uri.path.end_with?('.sha256') ? checksum : File.binread(rbz))
      end
      original_install = Updater.method(:install_staged_package!)
      original_state = Updater.method(:write_update_state)
      Updater.define_singleton_method(:install_staged_package!) { |validated, workspace| installed = [validated, workspace] }
      Updater.define_singleton_method(:write_update_state) { |_version| true }

      result = Updater.download_and_apply_update(update: update, http_get: http_get, on_status: ->(text) { progress << text })

      assert result['success']
      assert_equal '0.2.3', installed.first.fetch('version')
      assert_includes progress, 'Загрузка обновления…'
      assert_includes progress, 'Проверка контрольной суммы…'
      assert_includes progress, 'Безопасная распаковка и проверка…'
    ensure
      Updater.define_singleton_method(:install_staged_package!, original_install) if original_install
      Updater.define_singleton_method(:write_update_state, original_state) if original_state
    end
  end

  def test_no_update_result_skips_download
    http_get = ->(*) { flunk 'cancelled update must not download files' }
    result = Updater.download_and_apply_update(update: { 'available' => false }, http_get: http_get)

    assert_equal false, result.fetch('success')
    assert_match(/up to date/i, result.fetch('message'))
  end

  def test_legacy_update_entrypoint_keeps_successful_installs_restart_only
    source = File.read(File.expand_path('../component_library_browser/services/updater.rb', __dir__), encoding: 'UTF-8')
    method = source[source.index('def apply_and_reload'), source.index('def verify_checksum!') - source.index('def apply_and_reload')]

    assert_includes method, 'Restart SketchUp to load the new code.'
    refute_includes method, 'reload_plugin!'
  end

  def test_download_error_is_reported_to_the_progress_callback
    progress = []
    update = {
      'available' => true,
      'latest_version' => '0.3.0',
      'asset_name' => 'release.rbz',
      'rbz_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/release.rbz',
      'checksum_url' => 'https://github.com/draleksei1-cmyk/sketchup-component-browser/releases/download/v0.3.0/release.rbz.sha256'
    }
    http_get = ->(*) { Response.new('500', '') }

    result = Updater.download_and_apply_update(update: update, http_get: http_get, on_status: ->(text) { progress << text })

    refute result['success']
    assert_match(/Download returned HTTP 500/, result.fetch('error'))
    assert_includes progress, 'Загрузка обновления…'
    assert_match(/Ошибка обновления/, progress.last)
  end
end
