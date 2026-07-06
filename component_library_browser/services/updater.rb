require 'net/http'
require 'json'
require 'fileutils'
require 'uri'
require 'tmpdir'

module Drale
  module ComponentLibraryBrowser
    module Updater
      extend self

      GITHUB_OWNER = 'draleksei1-cmyk'.freeze
      GITHUB_REPO = 'sketchup-component-browser'.freeze

      API_RELEASES_URL = "https://api.github.com/repos/#{GITHUB_OWNER}/#{GITHUB_REPO}/releases/latest".freeze
      RAW_VERSION_URL = "https://raw.githubusercontent.com/#{GITHUB_OWNER}/#{GITHUB_REPO}/master/VERSION".freeze
      ZIPBALL_URL = "https://github.com/#{GITHUB_OWNER}/#{GITHUB_REPO}/archive/refs/heads/master.zip".freeze

      UPDATE_STATE_FILE = File.join(File.dirname(__FILE__), '..', '..', '.update_state.json').freeze

      def check_for_updates(background: false)
        Logger.info('Проверка обновлений...')
        latest_version = fetch_latest_version
        return nil unless latest_version

        current = current_version
        Logger.info("Текущая версия: #{current}, последняя: #{latest_version}")

        comparison = compare_versions(latest_version, current)
        if comparison > 0
          Logger.info("Доступно обновление: v#{current} -> v#{latest_version}")
          return { 'available' => true, 'latest_version' => latest_version, 'current_version' => current }
        end

        Logger.info('Установлена последняя версия.')
        { 'available' => false, 'latest_version' => latest_version, 'current_version' => current }
      rescue StandardError => e
        Logger.error('Ошибка проверки обновлений', e)
        if background
          nil
        else
          { 'error' => e.message }
        end
      end

      def download_and_apply_update
        update_info = check_for_updates
        return nil unless update_info && update_info['available']

        latest = update_info['latest_version']
        Logger.info("Скачивание обновления v#{latest}...")

        zip_path = download_zipball
        return nil unless zip_path

        extract_dir = File.join(Dir.tmpdir, "sketchup_component_library_update_#{Time.now.to_i}")
        FileUtils.mkdir_p(extract_dir)

        extract_zip(zip_path, extract_dir)
        return nil unless extract_dir

        repo_root = find_repo_root_in_extract(extract_dir)
        return nil unless repo_root

        plugin_dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))
        backup_dir = File.join(File.dirname(plugin_dir), ".backup_#{Time.now.strftime('%Y%m%d_%H%M%S')}")

        Logger.info("Создание резервной копии: #{backup_dir}")
        FileUtils.cp_r(plugin_dir, backup_dir)

        Logger.info("Применение обновления...")
        replace_plugin_files(repo_root, plugin_dir)
        FileUtils.remove_entry(extract_dir) if File.directory?(extract_dir)
        FileUtils.remove_entry(zip_path) if File.file?(zip_path)

        write_update_state(latest)
        Logger.info("Обновление до v#{latest} применено. Перезагрузка плагина...")
        { 'success' => true, 'version' => latest, 'backup' => backup_dir }
      rescue StandardError => e
        Logger.error('Ошибка применения обновления', e)
        { 'error' => e.message }
      end

      def apply_and_reload
        result = download_and_apply_update
        if result && result['success']
          UI.messagebox("Обновление до v#{result['version']} установлено.\nПлагин будет перезагружен.")
          reload_plugin!
        elsif result && result['error']
          UI.messagebox("Ошибка обновления: #{result['error']}", MB_MULTILINE)
        end
        result
      end

      def current_version
        EXTENSION_VERSION
      end

      private

      def fetch_latest_version
        uri = URI(RAW_VERSION_URL)
        response = make_http_request(uri, open_timeout: 5, read_timeout: 5)
        return nil unless response.is_a?(Net::HTTPResponse) && response.code.to_i == 200

        body = response.body.to_s.strip
        body.empty? ? nil : body
      rescue StandardError => e
        Logger.warn("Не удалось получить версию: #{e.message}")
        nil
      end

      def fetch_latest_release_tag
        uri = URI(API_RELEASES_URL)
        response = make_http_request(uri, open_timeout: 5, read_timeout: 5)
        return nil unless response.is_a?(Net::HTTPResponse) && response.code.to_i == 200

        data = JSON.parse(response.body)
        tag = data['tag_name'].to_s.strip
        tag.empty? ? nil : tag.sub(/\Av/i, '')
      rescue StandardError => e
        Logger.warn("Не удалось получить релиз: #{e.message}")
        nil
      end

      def download_zipball
        zip_path = File.join(Dir.tmpdir, "sketchup_component_library_update_#{Time.now.to_i}.zip")

        uri = URI(ZIPBALL_URL)
        Logger.info("Скачивание #{ZIPBALL_URL}")

        response = make_http_request(uri, open_timeout: 30, read_timeout: 120)
        return nil unless response.is_a?(Net::HTTPResponse) && response.code.to_i == 200

        File.open(zip_path, 'wb') { |f| f.write(response.body) }
        Logger.info("Архив сохранён: #{zip_path} (#{response.body.bytesize} байт)")
        zip_path
      rescue StandardError => e
        Logger.error('Ошибка скачивания архива', e)
        nil
      end

      def make_http_request(uri, open_timeout:, read_timeout:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout

        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = "ComponentLibraryBrowser/#{EXTENSION_VERSION}"
        request['Accept'] = 'application/json'

        http.request(request)
      end

      def extract_zip(zip_path, dest_dir)
        if Gem.win_platform?
          extract_zip_powershell(zip_path, dest_dir)
        else
          extract_zip_system(zip_path, dest_dir)
        end
      end

      def extract_zip_powershell(zip_path, dest_dir)
        ps_command = "Add-Type -AssemblyName System.IO.Compression.FileSystem; " \
                     "[System.IO.Compression.ZipFile]::ExtractToDirectory('#{zip_path.gsub("'", "''")}', '#{dest_dir.gsub("'", "''")}')"
        system('powershell', '-NoProfile', '-Command', ps_command)
      end

      def extract_zip_system(zip_path, dest_dir)
        system('unzip', '-o', zip_path, '-d', dest_dir)
      end

      def find_repo_root_in_extract(extract_dir)
        entries = Dir.entries(extract_dir) - ['.', '..']
        if entries.length == 1
          candidate = File.join(extract_dir, entries.first)
          return candidate if File.directory?(candidate)
        end
        extract_dir
      end

      def replace_plugin_files(source_root, target_root)
        Dir.glob(File.join(source_root, '**', '{*,.*}'), File::FNM_DOTMATCH).each do |source_path|
          next if File.directory?(source_path)
          basename = File.basename(source_path)
          next if basename == '.' || basename == '..'
          next if basename == '.git' || source_path.include?('/.git/')
          next if basename == '.update_state.json'

          relative = source_path.sub(source_root, '').sub(%r{\A[/\\]}, '')
          next if relative.empty?

          target_path = File.join(target_root, relative)
          FileUtils.mkdir_p(File.dirname(target_path))
          FileUtils.cp(source_path, target_path)
          Logger.debug("Обно��лён: #{relative}")
        end
        true
      end

      def compare_versions(a, b)
        a_segments = a.split('.').map(&:to_i)
        b_segments = b.split('.').map(&:to_i)
        max_len = [a_segments.length, b_segments.length].max
        a_segments += [0] * (max_len - a_segments.length)
        b_segments += [0] * (max_len - b_segments.length)

        a_segments.zip(b_segments).each do |sa, sb|
          return sa <=> sb unless sa == sb
        end
        0
      end

      def write_update_state(version)
        state = { 'updated_to' => version, 'updated_at' => Time.now.utc.iso8601 }
        File.write(UPDATE_STATE_FILE, JSON.pretty_generate(state))
      rescue StandardError => e
        Logger.warn("Не удалось записать состояние обновления: #{e.message}")
      end

      def reload_plugin!
        main = Drale::ComponentLibraryBrowser
        if main.respond_to?(:reload_plugin!, true)
          main.send(:reload_plugin!)
        else
          Sketchup.status_text = 'Component Library Browser обновлён. Перезапустите SketchUp для применения изменений.'
          Logger.info('Плагин обновлён. Требуется ручная перезагрузка.')
        end
      rescue StandardError => e
        Logger.error('Ошибка перезагрузки плагина', e)
        UI.messagebox("Ошибка перезагрузки плагина после обновления:\n#{e.message}\n\nПерезапустите SketchUp.")
      end
    end
  end
end