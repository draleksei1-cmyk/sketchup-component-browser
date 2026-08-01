# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../component_library_browser/storage'
require 'json'

Storage = Drale::ComponentLibraryBrowser::Storage

class FlatStorageTest < Minitest::Test
  ID = '11111111-1111-1111-1111-111111111111'.freeze

  FakeBounds = Struct.new(:width, :depth, :height)
  class FakeDefinition
    attr_reader :bounds
    def initialize(model = 'model-bytes', preview = 'preview-bytes')
      @model = model
      @preview = preview
      @bounds = FakeBounds.new(1, 2, 3)
    end
    def save_copy(path)
      File.binwrite(path, @model)
    end

    def save_thumbnail(path)
      File.binwrite(path, @preview)
    end
  end

  def with_root
    Dir.mktmpdir('flat-library') { |root| yield root }
  end

  def manifest(id = ID, name: 'Door', category: 'Doors')
    { 'asset_version' => 1, 'id' => id, 'name' => name, 'category' => category,
      'description' => '', 'tags' => ['door'], 'favorite' => false,
      'created_at' => '2026-07-25T12:00:00Z', 'updated_at' => '2026-07-25T12:00:00Z', 'source' => 'component' }
  end

  def write_asset(root, id = ID, model: 'model', preview: 'preview')
    FileUtils.mkdir_p(File.join(root, 'assets'))
    File.binwrite(File.join(root, FS.asset_model_rel_path(id)), model)
    File.binwrite(File.join(root, FS.asset_preview_rel_path(id)), preview) unless preview.nil?
    File.write(File.join(root, FS.asset_metadata_rel_path(id)), JSON.pretty_generate(manifest(id)))
  end

  def payloads(root, id = ID)
    %w[skp png json].to_h { |extension| [extension, File.binread(File.join(root, "assets/#{id}.#{extension}"))] }
  end

  def test_rebuild_catalog_uses_flat_payload_references_without_asset_directories
    with_root do |root|
      write_asset(root)
      storage = Storage.new(root)
      item = storage.item_by_id(ID)

      assert_equal "assets/#{ID}.skp", item.fetch('skp_rel_path')
      assert_equal "assets/#{ID}.png", item.fetch('thumb_rel_path')
      assert_equal [{ 'id' => ID, 'asset_rel_path' => "assets/#{ID}.json", 'updated_at' => '2026-07-25T12:00:00Z' }],
                   JSON.parse(File.read(File.join(root, 'library.json'))).fetch('assets')
      refute Dir.exist?(File.join(root, 'assets', ID))
      refute Dir.exist?(File.join(root, '.clb'))
    end
  end

  def test_save_edit_and_replace_keep_uuid_and_payload_paths_flat
    with_root do |root|
      storage = Storage.new(root)
      saved = storage.save_definition!(FakeDefinition.new, source: 'component', category: 'Doors', display_name: 'Door', tags: ['door'])
      id = saved.fetch('item').fetch('id')
      storage.edit_item!(id, 'name' => 'Renamed', 'category' => 'Windows', 'tags' => ['glass'])
      storage.replace_item_definition!(id, FakeDefinition.new('replacement'), source: 'component')

      assert_equal 'replacement', File.binread(File.join(root, "assets/#{id}.skp"))
      assert_equal "assets/#{id}.skp", storage.item_by_id(id).fetch('skp_rel_path')
      refute Dir.exist?(File.join(root, 'assets', id))
    end
  end

  def test_delete_moves_flat_payloads_to_recoverable_trash
    with_root do |root|
      write_asset(root)
      Storage.new(root).delete_item!(ID)

      refute File.exist?(File.join(root, "assets/#{ID}.skp"))
      trashed = Dir.glob(File.join(root, 'trash', '*', "#{ID}.*"))
      assert_equal 3, trashed.length
      assert_equal %w[json png skp], trashed.map { |path| File.extname(path).delete_prefix('.') }.sort
    end
  end

  def test_interrupted_replace_recovers_original_flat_payload_bytes
    with_root do |root|
      write_asset(root)
      storage = Storage.new(root)
      original = payloads(root)
      ENV['CLB_TEST_MODE'] = '1'
      ENV['CLB_TEST_FAILURE_AFTER'] = 'model_staged'
      assert_raises(RuntimeError) do
        storage.replace_v4_asset_payloads!(ID, 'model.skp' => 'new-model', 'preview.png' => 'new-preview', 'asset.json' => JSON.pretty_generate(manifest))
      end
      assert_equal original, payloads(root)
      assert_empty Dir.glob(File.join(root, 'trash', '*', 'transaction.json'))
    ensure
      ENV.delete('CLB_TEST_MODE')
      ENV.delete('CLB_TEST_FAILURE_AFTER')
    end
  end

  def test_rejects_traversal_and_directory_link_escape_for_flat_assets
    with_root do |root|
      assert_raises(ArgumentError) { FS.to_full_path(root, '../outside.skp') }
      outside = Dir.mktmpdir('outside')
      link = File.join(root, 'assets')
      begin
        File.symlink(outside, link)
      rescue Errno::EACCES, Errno::EPERM, NotImplementedError
        skip 'directory links are unavailable in this Windows session'
      end
      assert_raises(ArgumentError) { FS.to_full_path(root, "assets/#{ID}.skp") }
    ensure
      File.delete(link) if defined?(link) && File.symlink?(link)
      FileUtils.rm_rf(outside) if defined?(outside)
    end
  end

  def test_legacy_root_is_left_unchanged_and_exposed_as_empty_read_only_library
    with_root do |root|
      File.write(File.join(root, 'library_index.json'), '{"version":3,"items":[]}')
      storage = Storage.new(root)

      assert_empty storage.index.fetch('items')
      refute Dir.exist?(File.join(root, 'assets'))
      assert_raises(ArgumentError) { storage.add_category!('Doors') }
    end
  end
end
