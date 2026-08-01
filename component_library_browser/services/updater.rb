# frozen_string_literal: true

require 'net/http'
require 'json'
require 'fileutils'
require 'uri'
require 'tmpdir'
require 'digest'
require 'time'
require 'shellwords'

module Drale
  module ComponentLibraryBrowser
    module Updater
      extend self

      GITHUB_OWNER = 'draleksei1-cmyk'.freeze
      GITHUB_REPO = 'sketchup-component-browser'.freeze
      API_RELEASES_URL = "https://api.github.com/repos/#{GITHUB_OWNER}/#{GITHUB_REPO}/releases/latest".freeze
      LOADER_NAME = 'component_library_browser.rb'.freeze
      PACKAGE_NAME = 'component_library_browser'.freeze
      REQUIRED_DIRECTORIES = %w[icons ui tools services].freeze
      TRUSTED_ASSET_HOSTS = %w[github.com github-releases.githubusercontent.com release-assets.githubusercontent.com objects.githubusercontent.com].freeze
      REDIRECT_CODES = [301, 302, 307, 308].freeze
      MAX_REDIRECTS = 3

      class ReleaseError < StandardError; end
      class VerificationError < StandardError; end

      def package_dir
        File.expand_path('..', __dir__)
      end

      def package_root
        File.dirname(package_dir)
      end

      def version_file
        File.join(package_dir, 'VERSION')
      end

      def loader_file
        File.join(package_root, LOADER_NAME)
      end

      def current_version
        File.file?(version_file) ? File.read(version_file).strip : EXTENSION_VERSION.to_s
      end

      def check_for_updates(background: false, http_get: nil)
        release = fetch_latest_release(http_get: http_get)
        current = current_version
        available = compare_versions(release.fetch('version'), current) > 0
        {
          'available' => available,
          'latest_version' => release.fetch('version'),
          'current_version' => current,
          'rbz_url' => release.fetch('rbz_url'),
          'checksum_url' => release.fetch('checksum_url'),
          'asset_name' => release.fetch('asset_name')
        }
      rescue StandardError => error
        Logger.error('Update check failed', error)
        background ? nil : { 'error' => error.message }
      end

      def fetch_latest_release(http_get: nil)
        response = http_request(URI(API_RELEASES_URL), open_timeout: 5, read_timeout: 10, http_get: http_get)
        raise ReleaseError, "GitHub release API returned HTTP #{response.code}" unless response.code.to_i == 200

        data = JSON.parse(response.body.to_s)
        version = data['tag_name'].to_s.sub(/\Av/i, '')
        raise ReleaseError, 'Latest release has no semantic version tag' unless semantic_version?(version)

        assets = Array(data['assets'])
        rbz = assets.find { |asset| asset['name'].to_s.downcase.end_with?('.rbz') }
        raise ReleaseError, 'Latest release has no RBZ asset' unless rbz && rbz['browser_download_url']

        checksum_names = ["#{rbz['name']}.sha256", "#{rbz['name']}.sha256.txt"]
        checksum = assets.find { |asset| checksum_names.include?(asset['name'].to_s) }
        raise ReleaseError, 'Latest release has no matching RBZ checksum asset' unless checksum && checksum['browser_download_url']
        validate_asset_url!(rbz.fetch('browser_download_url'))
        validate_asset_url!(checksum.fetch('browser_download_url'))

        {
          'version' => version,
          'asset_name' => rbz.fetch('name'),
          'rbz_url' => rbz.fetch('browser_download_url'),
          'checksum_url' => checksum.fetch('browser_download_url')
        }
      rescue JSON::ParserError => error
        raise ReleaseError, "GitHub release response is invalid JSON: #{error.message}"
      end

      def download_and_apply_update(http_get: nil)
        update = check_for_updates(http_get: http_get)
        return update if update.is_a?(Hash) && update['error']
        return { 'success' => false, 'message' => 'Already up to date.' } unless update && update['available']

        workspace = Dir.mktmpdir('component_library_browser_update_')
        rbz_path = File.join(workspace, update.fetch('asset_name'))
        checksum_path = "#{rbz_path}.sha256"
        stage_dir = File.join(workspace, 'staged')

        download_to!(update.fetch('rbz_url'), rbz_path, http_get: http_get)
        download_to!(update.fetch('checksum_url'), checksum_path, http_get: http_get)
        verify_checksum!(rbz_path, File.read(checksum_path, encoding: 'UTF-8'))
        extract_rbz!(rbz_path, stage_dir)
        validated = validate_staged_package!(stage_dir, expected_version: update.fetch('latest_version'))

        install_staged_package!(validated, workspace)
        write_update_state(update.fetch('latest_version'))
        FileUtils.remove_entry_secure(workspace) if File.directory?(workspace)
        { 'success' => true, 'version' => update.fetch('latest_version') }
      rescue Errno::EACCES, Errno::EPERM, Errno::EBUSY => error
        if defined?(rbz_path) && File.file?(rbz_path) && File.file?(checksum_path) && File.directory?(stage_dir)
          staged_path = persist_pending_update!(rbz_path, checksum_path, stage_dir, update.fetch('latest_version'))
          FileUtils.remove_entry_secure(workspace) if File.directory?(workspace)
          Logger.warn("Update staged at #{staged_path}; SketchUp restart required: #{error.message}")
          { 'success' => false, 'restart_required' => true, 'staged_path' => staged_path, 'error' => error.message }
        else
          { 'success' => false, 'error' => error.message }
        end
      rescue StandardError => error
        Logger.error('Update installation failed', error)
        { 'success' => false, 'error' => error.message, 'staged_path' => (defined?(workspace) ? workspace : nil) }
      end

      def apply_and_reload
        result = download_and_apply_update
        if result && result['success']
          UI.messagebox("Update v#{result['version']} installed. Reloading Ruby code now.")
          reload_plugin!
        elsif result && result['restart_required']
          UI.messagebox("Update is safely staged at:\n#{result['staged_path']}\n\nRestart SketchUp to complete it.", MB_MULTILINE)
        elsif result && result['error']
          UI.messagebox("Update error: #{result['error']}", MB_MULTILINE)
        end
        result
      end

      def verify_checksum!(rbz_path, checksum_text)
        expected_name = File.basename(rbz_path)
        line = checksum_text.to_s.each_line.map(&:strip).find { |entry| entry.end_with?(expected_name) }
        raise VerificationError, "Checksum manifest has no digest for #{expected_name}" unless line

        digest, filename = line.split(/\s+/, 2)
        raise VerificationError, 'Checksum manifest has an invalid SHA256 digest' unless digest.to_s.match?(/\A[0-9a-f]{64}\z/i)
        raise VerificationError, 'Checksum manifest asset name does not match RBZ' unless filename.to_s.sub(/\A\*?/, '') == expected_name
        raise VerificationError, 'RBZ SHA256 does not match release manifest' unless Digest::SHA256.file(rbz_path).hexdigest.casecmp?(digest)

        true
      end

      def download_to!(url, path, http_get: nil)
        uri = validate_asset_url!(url)
        redirects = 0
        loop do
          response = http_request(uri, open_timeout: 30, read_timeout: 120, http_get: http_get)
          if response.code.to_i == 200
            File.binwrite(path, response.body)
            return true
          end
          raise ReleaseError, "Download returned HTTP #{response.code}" unless REDIRECT_CODES.include?(response.code.to_i)
          raise ReleaseError, 'Download redirect limit exceeded' if redirects >= MAX_REDIRECTS

          location = response['location'].to_s
          raise ReleaseError, 'Download redirect has no location' if location.empty?
          uri = validate_asset_url!(URI.join(uri.to_s, location).to_s)
          redirects += 1
        end
      end

      def pending_update_manifest_path
        File.join(pending_update_root, 'pending_update.json')
      end

      def apply_pending_update(manifest_path: pending_update_manifest_path, install: nil)
        return nil unless File.file?(manifest_path)

        pending_root = pending_update_root(manifest_path)
        data = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))
        version = data.fetch('version').to_s
        raise VerificationError, 'Pending update has invalid version' unless semantic_version?(version)
        rbz_path = pending_file!(pending_root, data.fetch('asset_name'))
        checksum_path = pending_file!(pending_root, data.fetch('checksum_name'))
        stage_dir = pending_file!(pending_root, data.fetch('stage_name'))
        raise VerificationError, 'Pending RBZ is missing' unless File.file?(rbz_path)
        raise VerificationError, 'Pending checksum is missing' unless File.file?(checksum_path)
        verify_checksum!(rbz_path, File.read(checksum_path, encoding: 'UTF-8'))
        validated = validate_staged_package!(stage_dir, expected_version: version)
        (install || method(:install_staged_package!)).call(validated, pending_root)
        write_update_state(version)
        clear_pending_update!(manifest_path)
        { 'success' => true, 'version' => version }
      rescue Errno::EACCES, Errno::EPERM, Errno::EBUSY => error
        { 'success' => false, 'restart_required' => true, 'error' => error.message }
      rescue StandardError => error
        Logger.warn("Pending update preserved for retry: #{error.message}")
        { 'success' => false, 'retry_required' => true, 'error' => error.message }
      end

      def validate_staged_package!(stage_root, expected_version: nil)
        stage_root = File.expand_path(stage_root)
        package = File.join(stage_root, PACKAGE_NAME)
        loader = File.join(stage_root, LOADER_NAME)
        version = File.join(package, 'VERSION')
        assert_path_within!(stage_root, package)
        assert_path_within!(stage_root, loader)
        raise VerificationError, 'RBZ contains no extension loader' unless File.file?(loader)
        raise VerificationError, 'RBZ contains no package VERSION' unless File.file?(version)
        REQUIRED_DIRECTORIES.each do |directory|
          raise VerificationError, "RBZ is missing required directory: #{directory}" unless File.directory?(File.join(package, directory))
        end

        actual_version = File.read(version).strip
        if expected_version && actual_version != expected_version
          raise VerificationError, "RBZ VERSION #{actual_version} does not match release #{expected_version}"
        end
        { 'stage_root' => stage_root, 'package_dir' => package, 'loader' => loader, 'version' => actual_version }
      end

      def assert_path_within!(root, path)
        root = File.expand_path(root)
        path = File.expand_path(path)
        return path if path.start_with?(root + File::SEPARATOR)

        raise VerificationError, "Path outside staged extension root: #{path}"
      end

      private

      def persist_pending_update!(rbz_path, checksum_path, stage_dir, version)
        manifest_path = pending_update_manifest_path
        pending_root = pending_update_root(manifest_path)
        raise VerificationError, 'A pending update already exists; restart SketchUp to apply it first' if File.exist?(manifest_path) || File.directory?(pending_root)

        FileUtils.mkdir_p(pending_root)
        asset_name = File.basename(rbz_path)
        checksum_name = File.basename(checksum_path)
        FileUtils.cp(rbz_path, File.join(pending_root, asset_name))
        FileUtils.cp(checksum_path, File.join(pending_root, checksum_name))
        FileUtils.cp_r(stage_dir, File.join(pending_root, 'staged'))
        File.write(manifest_path, JSON.pretty_generate(
          'version' => version,
          'asset_name' => asset_name,
          'checksum_name' => checksum_name,
          'stage_name' => 'staged'
        ))
        pending_root
      end

      def pending_update_root(manifest_path = nil)
        return File.join(package_root, ".#{PACKAGE_NAME}_update") unless manifest_path

        File.dirname(File.expand_path(manifest_path))
      end

      def pending_file!(pending_root, name)
        name = name.to_s
        raise VerificationError, 'Pending update has unsafe file name' if name.empty? || File.basename(name) != name

        assert_path_within!(pending_root, File.join(pending_root, name))
      end

      def clear_pending_update!(manifest_path)
        pending_root = pending_update_root(manifest_path)
        FileUtils.rm_f(manifest_path) if File.file?(manifest_path)
        FileUtils.rm_rf(pending_root) if File.directory?(pending_root)
      end

      def install_staged_package!(validated, workspace)
        target_package = package_dir
        target_loader = loader_file
        backup = File.join(package_root, ".#{PACKAGE_NAME}_backup_#{Time.now.strftime('%Y%m%d_%H%M%S')}")
        FileUtils.mkdir_p(backup)

        # No Plugins-root replacement: only this extension folder and its loader.
        FileUtils.cp_r(target_package, File.join(backup, PACKAGE_NAME)) if File.directory?(target_package)
        FileUtils.cp(target_loader, backup) if File.file?(target_loader)

        pending_package = File.join(workspace, 'pending_package')
        pending_loader = File.join(workspace, LOADER_NAME)
        FileUtils.cp_r(validated.fetch('package_dir'), pending_package)
        FileUtils.cp(validated.fetch('loader'), pending_loader)

        old_package = "#{target_package}.previous"
        old_loader = "#{target_loader}.previous"
        FileUtils.rm_rf(old_package) if File.exist?(old_package)
        FileUtils.rm_f(old_loader) if File.file?(old_loader)
        FileUtils.mv(target_package, old_package) if File.exist?(target_package)
        FileUtils.mv(target_loader, old_loader) if File.file?(target_loader)
        FileUtils.mv(pending_package, target_package)
        FileUtils.mv(pending_loader, target_loader)
        FileUtils.rm_rf(old_package) if File.exist?(old_package)
        FileUtils.rm_f(old_loader) if File.file?(old_loader)
        backup
      rescue StandardError
        FileUtils.rm_rf(target_package) if File.exist?(target_package) && File.directory?(File.join(backup, PACKAGE_NAME))
        FileUtils.cp_r(File.join(backup, PACKAGE_NAME), target_package) if File.directory?(File.join(backup, PACKAGE_NAME))
        FileUtils.cp(File.join(backup, LOADER_NAME), target_loader) if File.file?(File.join(backup, LOADER_NAME))
        raise
      end

      def http_request(uri, open_timeout:, read_timeout:, http_get: nil)
        return http_get.call(uri, open_timeout: open_timeout, read_timeout: read_timeout) if http_get

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = "ComponentLibraryBrowser/#{EXTENSION_VERSION}"
        request['Accept'] = 'application/vnd.github+json'
        http.request(request)
      end

      def extract_rbz!(rbz_path, destination)
        raise VerificationError, 'RBZ archive is empty' unless File.size?(rbz_path)

        if Gem.win_platform?
          extract_rbz_powershell!(rbz_path, destination)
        else
          raise VerificationError, 'RBZ archive contains unsafe paths' unless archive_paths_safe?(rbz_path)
          raise VerificationError, 'Unable to extract RBZ' unless system('unzip', '-q', rbz_path, '-d', destination)
        end
      end

      def archive_paths_safe?(rbz_path)
        entries = `unzip -Z1 #{Shellwords.escape(rbz_path)}`.lines.map(&:strip)
        !entries.empty? && entries.all? { |entry| archive_entry_safe?(entry) }
      end

      def archive_entry_safe?(entry)
        !entry.empty? && !entry.start_with?('/', '\\') && !entry.match?(/\A[A-Za-z]:[\\\/]/) && entry.split(/[\\\/]/).none? { |part| part == '..' }
      end

      def extract_rbz_powershell!(rbz_path, destination)
        archive = powershell_literal(rbz_path)
        target = powershell_literal(destination)
        script = <<~POWERSHELL
          Add-Type -AssemblyName System.IO.Compression.FileSystem
          $archive = [System.IO.Compression.ZipFile]::OpenRead(#{archive})
          try {
            foreach ($entry in $archive.Entries) {
              $name = $entry.FullName
              $normalized = $name.Replace([char]92, [char]47)
              if ([IO.Path]::IsPathRooted($name) -or $normalized.Split('/') -contains '..' -or $name -match '^[A-Za-z]:') { throw "Unsafe RBZ path: $name" }
            }
          } finally { $archive.Dispose() }
          [System.IO.Compression.ZipFile]::ExtractToDirectory(#{archive}, #{target})
        POWERSHELL
        raise VerificationError, 'Unable to extract a safe RBZ archive' unless system('powershell', '-NoProfile', '-NonInteractive', '-Command', script)
      end

      def powershell_literal(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end

      def semantic_version?(version)
        version.match?(/\A\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?\z/)
      end

      def validate_asset_url!(url)
        uri = URI(url.to_s)
        raise ReleaseError, 'Release asset URL must use HTTPS' unless uri.scheme == 'https'
        raise ReleaseError, "Release asset host is not trusted: #{uri.host}" unless TRUSTED_ASSET_HOSTS.include?(uri.host.to_s.downcase)
        if uri.host.to_s.casecmp?('github.com')
          prefix = "/#{GITHUB_OWNER}/#{GITHUB_REPO}/releases/download/"
          raise ReleaseError, 'Release asset URL is outside this repository' unless uri.path.start_with?(prefix)
        end
        raise ReleaseError, 'Release asset URL has no file path' if File.basename(uri.path).to_s.empty?

        uri
      rescue URI::InvalidURIError => error
        raise ReleaseError, "Invalid release asset URL: #{error.message}"
      end

      def compare_versions(a, b)
        a_segments = a.to_s.split(/[.+-]/).first(3).map(&:to_i)
        b_segments = b.to_s.split(/[.+-]/).first(3).map(&:to_i)
        3.times do |index|
          comparison = (a_segments[index] || 0) <=> (b_segments[index] || 0)
          return comparison unless comparison.zero?
        end
        0
      end

      def write_update_state(version)
        path = File.join(package_dir, '.update_state.json')
        File.write(path, JSON.pretty_generate('updated_to' => version, 'updated_at' => Time.now.utc.iso8601))
      rescue StandardError => error
        Logger.warn("Could not write update state: #{error.message}")
      end

      def reload_plugin!
        main = Drale::ComponentLibraryBrowser
        if main.respond_to?(:reload_plugin!, true)
          main.send(:reload_plugin!)
        else
          Sketchup.status_text = 'Update installed. Restart SketchUp to load all extension files.'
        end
      rescue StandardError => error
        Logger.error('Plugin reload failed; restart SketchUp is required', error)
      end
    end
  end
end
