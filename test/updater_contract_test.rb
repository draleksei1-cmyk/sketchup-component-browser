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

  Response = Struct.new(:code, :body)

  def release_payload
    {
      'tag_name' => 'v0.3.0',
      'assets' => [
        { 'name' => 'component-library-browser-0.3.0.rbz', 'browser_download_url' => 'https://example.test/release.rbz' },
        { 'name' => 'component-library-browser-0.3.0.rbz.sha256', 'browser_download_url' => 'https://example.test/release.rbz.sha256' },
        { 'name' => 'source.zip', 'browser_download_url' => 'https://example.test/source.zip' }
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
    assert_equal 'https://example.test/release.rbz', release.fetch('rbz_url')
    assert_equal 'https://example.test/release.rbz.sha256', release.fetch('checksum_url')
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
end
