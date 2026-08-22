require 'json'
require 'fileutils'
require 'time'
require 'tmpdir'

module Drale
  module ComponentLibraryBrowser
    module Logger
      extend self

      LOG_DIR = File.join(Dir.tmpdir, 'ComponentLibraryBrowser').freeze
      LOG_FILE = File.join(LOG_DIR, 'component_library_browser.log').freeze
      MAX_LOG_BYTES = 2 * 1024 * 1024

      def info(message, data = nil)
        write('INFO', message, data)
      end

      # Переключатель отладочного уровня: включать только для диагностики,
      # в обычной работе отладочные записи в лог не попадают.
      DEBUG_ENABLED = false

      def debug(message, data = nil)
        write('DEBUG', message, data)
      end

      def warn(message, data = nil)
        write('WARN', message, data)
      end

      def error(message, error = nil, data = nil)
        payload = data || {}
        if error
          payload = payload.merge(
            'error_class' => error.class.to_s,
            'error_message' => error.message.to_s,
            'backtrace' => Array(error.backtrace)
          )
        end
        write('ERROR', message, payload)
      end

      def file_path
        LOG_FILE
      end

      def clear!
        FileUtils.mkdir_p(LOG_DIR)
        File.write(LOG_FILE, '', mode: 'w:UTF-8')
        true
      rescue StandardError => e
        puts("[ComponentLibraryBrowser::Logger] #{e.class}: #{e.message}")
        false
      end

      def write(level, message, data = nil)
        rotate_if_needed!
        FileUtils.mkdir_p(LOG_DIR)
        line = format_line(level, message, data)
        File.open(LOG_FILE, 'a:UTF-8') { |f| f.puts(line) }
        puts(line)
        true
      rescue StandardError => e
        puts("[ComponentLibraryBrowser::Logger] #{e.class}: #{e.message}")
        false
      end

      private

      def rotate_if_needed!
        return unless File.file?(LOG_FILE)
        return unless File.size(LOG_FILE).to_i >= MAX_LOG_BYTES

        rotated = "#{LOG_FILE}.1"
        File.delete(rotated) if File.file?(rotated)
        FileUtils.mv(LOG_FILE, rotated)
      rescue StandardError
        # keep current log file on any rotation error
      end

      def format_line(level, message, data = nil)
        stamp = Time.now.utc.iso8601
        msg = message.to_s.gsub(/\s+/, ' ').strip
        tail = ''
        if data && !data.to_s.strip.empty?
          tail = " | #{safe_json(data)}"
        end
        "[#{stamp}] [#{level}] #{msg}#{tail}"
      end

      def safe_json(value)
        JSON.generate(value)
      rescue StandardError
        value.inspect
      end
    end
  end
end
