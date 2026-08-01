# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'

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

  def test_pending_update_applies_validated_staging_and_removes_manifest
    Dir.mktmpdir('pending-update-') do |dir|
      package = File.join(dir, 'component_library_browser')
      pending_root = File.join(package, '.pending_update')
      staged = File.join(pending_root, 'staged')
      %w[icons ui tools services].each { |name| FileUtils.mkdir_p(File.join(staged, 'component_library_browser', name)) }
      File.write(File.join(staged, 'component_library_browser.rb'), '# loader')
      File.write(File.join(staged, 'component_library_browser', 'VERSION'), '0.3.0')
      rbz = File.join(pending_root, 'release.rbz')
      FileUtils.mkdir_p(pending_root)
      File.binwrite(rbz, 'safe pending archive')
      digest = Digest::SHA256.file(rbz).hexdigest
      File.write(File.join(pending_root, 'release.rbz.sha256'), "#{digest}  release.rbz\n")
      manifest = File.join(package, '.pending_update.json')
      File.write(manifest, JSON.generate('version' => '0.3.0', 'asset_name' => 'release.rbz', 'checksum_name' => 'release.rbz.sha256', 'stage_name' => 'staged'))

      applied = false
      result = Updater.apply_pending_update(manifest_path: manifest, install: ->(validated, _workspace) { applied = validated['version'] == '0.3.0' })

      assert result['success']
      assert applied
      refute File.exist?(manifest)
      refute File.exist?(pending_root)
    end
  end

  def test_invalid_pending_update_is_discarded_without_install
    Dir.mktmpdir('pending-update-') do |dir|
      package = File.join(dir, 'component_library_browser')
      FileUtils.mkdir_p(package)
      manifest = File.join(package, '.pending_update.json')
      File.write(manifest, '{"version":"0.3.0","stage_name":"../outside"}')

      result = Updater.apply_pending_update(manifest_path: manifest, install: ->(*) { flunk 'invalid pending update must not install' })

      assert result['discarded']
      refute File.exist?(manifest)
    end
  end
end
