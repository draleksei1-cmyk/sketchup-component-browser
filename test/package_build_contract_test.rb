# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class PackageBuildContractTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'scripts', 'build_rbz.ps1')

  def test_build_creates_a_versioned_rbz_with_only_extension_package_paths
    Dir.mktmpdir('clb-rbz-test-') do |output|
      stdout, stderr, status = Open3.capture3(
        'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT,
        '-OutputDirectory', output, '-SelfTest'
      )
      assert status.success?, "RBZ build failed:\n#{stdout}\n#{stderr}"

      rbz = File.join(output, 'component-library-browser-0.2.2.rbz')
      manifest = "#{rbz}.sha256"
      assert File.file?(rbz), 'versioned RBZ missing'
      assert File.file?(manifest), 'SHA256 manifest missing'

      entries, list_error, list_status = Open3.capture3('tar', '-tf', rbz)
      assert list_status.success?, list_error
      paths = entries.lines.map(&:strip).reject(&:empty?)
      assert_includes paths, 'component_library_browser.rb'
      assert_includes paths, 'component_library_browser/VERSION'
      assert paths.all? { |path| !path.start_with?('/', '../') && !path.include?('/../') }
      refute paths.any? { |path| path.match?(%r{\A(?:test|docs|\.git|component_library_browser_checkpoints)/}) }
      refute paths.any? { |path| path.include?('/runtime_state/') || path.match?(/disabled_plugins/i) || path.match?(/pending_update/i) }
    end
  end
end
