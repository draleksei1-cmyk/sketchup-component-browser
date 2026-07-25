require 'fileutils'
require 'pathname'
require 'securerandom'
require 'time'

module Drale
  module ComponentLibraryBrowser
    module FS
      extend self

      INDEX_FILENAME = 'library_index.json'.freeze
      CATEGORIES_DIR = 'categories'.freeze
      PREVIEWS_DIR = 'previews'.freeze

      FORMAT_VERSION = 4
      ASSETS_DIR = 'assets'.freeze
      INTERNAL_DIR = '.clb'.freeze
      CATALOG_FILENAME = 'library.json'.freeze

      INVALID_FILENAME_CHARS = /[<>:"\/\\|?*\x00-\x1F]/.freeze
      RESERVED_WINDOWS_NAMES = %w[
        CON PRN AUX NUL
        COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9
        LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9
      ].freeze

      def now_iso8601
        Time.now.utc.iso8601
      end

      def short_id
        SecureRandom.hex(4)
      end

      def index_path(lib_root)
        File.join(lib_root, INDEX_FILENAME)
      end

      def assets_root(lib_root)
        File.join(lib_root, ASSETS_DIR)
      end

      def asset_dir(lib_root, asset_id)
        to_full_path(lib_root, [ASSETS_DIR, asset_id.to_s].join('/'))
      end

      def asset_model_rel_path(asset_id)
        asset_rel_path(asset_id, 'model.skp')
      end

      def asset_preview_rel_path(asset_id)
        asset_rel_path(asset_id, 'preview.png')
      end

      def asset_metadata_rel_path(asset_id)
        asset_rel_path(asset_id, 'asset.json')
      end

      def catalog_path(lib_root)
        File.join(lib_root, CATALOG_FILENAME)
      end

      def internal_root(lib_root)
        File.join(lib_root, INTERNAL_DIR)
      end

      def transactions_root(lib_root)
        File.join(internal_root(lib_root), 'transactions')
      end

      def snapshots_root(lib_root)
        File.join(internal_root(lib_root), 'snapshots')
      end

      def trash_root(lib_root)
        File.join(internal_root(lib_root), 'trash')
      end

      def categories_root(lib_root)
        File.join(lib_root, CATEGORIES_DIR)
      end

      def category_dir(lib_root, category)
        File.join(categories_root(lib_root), category)
      end

      def previews_root(lib_root)
        File.join(lib_root, PREVIEWS_DIR)
      end

      def ensure_library_structure(lib_root)
        FileUtils.mkdir_p(categories_root(lib_root))
        FileUtils.mkdir_p(previews_root(lib_root))
      end

      def normalize_category_name(value)
        normalized = sanitize_segment(value, 'Category')
        raise ArgumentError, 'Category name cannot be empty.' if normalized.to_s.strip.empty?

        normalized
      end

      def sanitize_segment(value, fallback = 'item')
        text = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').strip
        text = text.gsub(INVALID_FILENAME_CHARS, '_')
        text = text.gsub(/[[:space:]]+/, ' ')
        text = text.gsub(/\A[. ]+/, '')
        text = text.gsub(/[. ]+\z/, '')
        text = fallback if text.empty?

        return "#{text}_" if RESERVED_WINDOWS_NAMES.include?(text.upcase)

        text
      end

      def normalize_display_name(value)
        sanitize_segment(value, 'Item')
      end

      def normalize_tags(raw)
        values =
          case raw
          when Array
            raw
          else
            raw.to_s.split(',')
          end

        values.map { |tag| tag.to_s.strip.downcase }
              .reject(&:empty?)
              .uniq
              .sort
      end

      def same_name?(a, b)
        a.to_s.casecmp?(b.to_s)
      end

      def next_unique_name(desired_name, taken_names)
        candidate = desired_name
        index = 2

        while taken_names.any? { |name| same_name?(name, candidate) }
          candidate = "#{desired_name}_#{index}"
          index += 1
        end

        candidate
      end

      def to_rel_path(lib_root, full_path)
        Pathname.new(full_path).relative_path_from(Pathname.new(lib_root)).to_s.tr('\\', '/')
      end

      def to_full_path(lib_root, rel_path)
        relative_path = rel_path.to_s
        raise ArgumentError, 'Relative path cannot be blank.' if relative_path.strip.empty?

        normalized_path = relative_path.tr('\\', '/')
        if normalized_path.start_with?('/') || normalized_path.match?(/\A[A-Za-z]:/)
          raise ArgumentError, 'Path must be relative to the library root.'
        end

        full_path = File.expand_path(normalized_path, File.expand_path(lib_root.to_s))
        raise ArgumentError, 'Path escapes the library root.' unless path_within_root?(lib_root, full_path)

        full_path
      end

      def path_within_root?(lib_root, path)
        root = File.expand_path(lib_root.to_s)
        candidate = File.expand_path(path.to_s)
        return true if candidate == root

        candidate.start_with?(root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}")
      end

      def extract_short_id(filename)
        match = filename.to_s.match(/__([0-9a-zA-Z]+)\.skp\z/)
        match && match[1]
      end

      def display_name_from_skp(filename)
        base = File.basename(filename.to_s, '.skp')
        short = extract_short_id(filename)
        name = short ? base.sub(/__#{Regexp.escape(short)}\z/, '') : base
        name.strip.empty? ? 'Item' : name
      end

      # Уменьшает PNG-превью до компактного размера.
      # Если PowerShell/System.Drawing недоступны, тихо оставляет исходный файл.
      def compact_png_thumbnail(path, max_side_px = 256)
        return false unless path && File.file?(path)
        # Не запускаем тяжелую оптимизацию для небольших файлов:
        # это заметно снижает подвисания при интерактивных операциях.
        return false if File.size(path).to_i <= 400_000
        max_side = max_side_px.to_i
        return false if max_side <= 0

        escaped = path.to_s.gsub("'", "''")
        script = <<~PS
          Add-Type -AssemblyName System.Drawing
          $path = '#{escaped}'
          if (-not (Test-Path $path)) { exit 0 }
          $img = [System.Drawing.Image]::FromFile($path)
          try {
            $max = #{max_side}
            $w = [int]$img.Width
            $h = [int]$img.Height
            if ($w -le $max -and $h -le $max) { exit 0 }
            if ($w -ge $h) {
              $newW = $max
              $newH = [int][Math]::Round($h * $max / $w)
            } else {
              $newH = $max
              $newW = [int][Math]::Round($w * $max / $h)
            }
            if ($newW -lt 1) { $newW = 1 }
            if ($newH -lt 1) { $newH = 1 }
            $bmp = New-Object System.Drawing.Bitmap($newW, $newH)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
              $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
              $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
              $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
              $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
              $g.DrawImage($img, 0, 0, $newW, $newH)
            } finally {
              $g.Dispose()
            }
            $tmp = "$path.tmp.png"
            $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            Move-Item -Path $tmp -Destination $path -Force
          } finally {
            $img.Dispose()
          }
        PS

        system('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script)
      rescue StandardError
        false
      end

      private

      def asset_rel_path(asset_id, filename)
        [ASSETS_DIR, asset_id.to_s, filename].join('/')
      end
    end
  end
end
