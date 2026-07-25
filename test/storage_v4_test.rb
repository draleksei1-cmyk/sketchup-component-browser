require_relative 'test_helper'
require_relative '../component_library_browser/storage'
require 'json'

Storage = Drale::ComponentLibraryBrowser::Storage

class StorageV4Test < Minitest::Test
  ASSET_ID = '11111111-1111-1111-1111-111111111111'.freeze
  SECOND_ASSET_ID = '22222222-2222-2222-2222-222222222222'.freeze

  def with_library_root
    Dir.mktmpdir('component-library-v4') { |root| yield root }
  end

  def write_asset(root, id: ASSET_ID, directory_id: id, manifest: {})
    asset_dir = File.join(root, 'assets', directory_id)
    FileUtils.mkdir_p(asset_dir)
    File.write(File.join(asset_dir, 'model.skp'), 'skp') unless manifest.delete(:without_model)

    payload = canonical_manifest(id).merge(manifest)
    File.write(File.join(asset_dir, 'asset.json'), JSON.pretty_generate(payload)) unless manifest.delete(:unreadable)
    asset_dir
  end

  def canonical_manifest(id, name: 'Door', category: 'Doors')
    {
      'id' => id,
      'name' => name,
      'category' => category,
      'description' => 'A standard door.',
      'tags' => ['door'],
      'favorite' => false,
      'created_at' => '2026-07-25T12:00:00Z',
      'updated_at' => '2026-07-25T12:00:00Z',
      'source' => 'component'
    }
  end

  def read_catalog(root)
    JSON.parse(File.read(File.join(root, 'library.json')))
  end

  def test_catalog_is_built_from_a_canonical_asset_when_missing
    with_library_root do |root|
      write_asset(root)

      storage = Storage.new(root)
      item = storage.item_by_id(ASSET_ID)
      catalog = File.file?(File.join(root, 'library.json')) ? read_catalog(root) : {}

      assert_equal 'Door', item && item['name']
      assert_equal "assets/#{ASSET_ID}/model.skp", item && item['skp_rel_path']
      assert_equal "assets/#{ASSET_ID}/preview.png", item && item['thumb_rel_path']
      assert_equal [
        { 'id' => ASSET_ID, 'asset_rel_path' => "assets/#{ASSET_ID}", 'updated_at' => '2026-07-25T12:00:00Z' }
      ], catalog['assets']
      refute Dir.exist?(File.join(root, 'categories'))
      refute Dir.exist?(File.join(root, 'previews'))
    end
  end

  def test_catalog_is_not_used_as_item_metadata_cache
    with_library_root do |root|
      write_asset(root, manifest: { 'name' => 'Canonical name' })
      File.write(File.join(root, 'library.json'), JSON.pretty_generate(
        'version' => 4,
        'created_at' => '2026-07-25T10:00:00Z',
        'updated_at' => '2026-07-25T10:00:00Z',
        'assets' => [{ 'id' => ASSET_ID, 'asset_rel_path' => "assets/#{ASSET_ID}", 'updated_at' => '2026-07-25T12:00:00Z', 'name' => 'Stale cache' }],
        'items' => [{ 'id' => ASSET_ID, 'name' => 'Stale cache' }]
      ))

      item = Storage.new(root).item_by_id(ASSET_ID)
      assert_equal 'Canonical name', item && item['name']
    end
  end

  def test_catalog_rebuilds_when_missing_corrupt_incomplete_or_inconsistent
    with_library_root do |root|
      write_asset(root)

      [
        nil,
        '{not-json',
        JSON.pretty_generate('version' => 4, 'assets' => []),
        JSON.pretty_generate('version' => 4, 'assets' => [{ 'id' => ASSET_ID, 'asset_rel_path' => "assets/#{ASSET_ID}", 'updated_at' => 'stale' }])
      ].each do |catalog|
        path = File.join(root, 'library.json')
        if catalog.nil?
          File.delete(path) if File.file?(path)
        else
          File.write(path, catalog)
        end

        Storage.new(root)
        rebuilt = File.file?(path) ? read_catalog(root) : {}
        entry = Array(rebuilt['assets']).first || {}
        assert_equal ASSET_ID, entry['id']
        assert_equal '2026-07-25T12:00:00Z', entry['updated_at']
      end
    end
  end

  def test_catalog_rebuilds_when_version_or_timestamps_are_not_canonical
    with_library_root do |root|
      write_asset(root)

      [
        { 'version' => '4', 'created_at' => '2026-07-25T10:00:00Z', 'updated_at' => '2026-07-25T12:00:00Z' },
        { 'version' => 4, 'created_at' => '2026-07-25T13:00:00Z', 'updated_at' => '2026-07-25T12:00:00Z' },
        { 'version' => 4, 'created_at' => '2026-07-25T10:00:00+00:00', 'updated_at' => '2026-07-25T12:00:00Z' }
      ].each do |header|
        File.write(File.join(root, 'library.json'), JSON.pretty_generate(header.merge(
          'assets' => [{ 'id' => ASSET_ID, 'asset_rel_path' => "assets/#{ASSET_ID}", 'updated_at' => '2026-07-25T12:00:00Z' }]
        )))

        Storage.new(root)
        rebuilt = read_catalog(root)

        assert_equal 4, rebuilt.fetch('version')
        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, rebuilt.fetch('created_at'))
        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, rebuilt.fetch('updated_at'))
        assert_operator Time.iso8601(rebuilt.fetch('created_at')), :<=, Time.iso8601(rebuilt.fetch('updated_at'))
      end
    end
  end

  def test_invalid_or_unreadable_assets_are_recoverable_and_not_deleted
    with_library_root do |root|
      invalid_dir = write_asset(root, id: SECOND_ASSET_ID, directory_id: ASSET_ID)
      unreadable_dir = write_asset(root, id: SECOND_ASSET_ID, directory_id: SECOND_ASSET_ID, manifest: { unreadable: true })
      File.write(File.join(root, 'library.json'), JSON.pretty_generate(
        'version' => 4,
        'created_at' => '2026-07-25T10:00:00Z',
        'updated_at' => '2026-07-25T10:00:00Z',
        'assets' => []
      ))

      storage = Storage.new(root)

      assert_nil storage.item_by_id(ASSET_ID)
      assert_equal [ASSET_ID, SECOND_ASSET_ID], storage.index.fetch('recovery').map { |entry| entry.fetch('id') }.sort
      assert File.directory?(invalid_dir)
      assert File.directory?(unreadable_dir)
      assert_equal [], read_catalog(root).fetch('assets')
    end
  end

  def test_v4_accepts_only_matching_uuid_manifest_with_model_and_computes_categories_from_manifests
    with_library_root do |root|
      write_asset(root, manifest: { 'category' => 'Windows' })
      write_asset(root, id: SECOND_ASSET_ID, directory_id: 'not-a-uuid')
      write_asset(root, id: SECOND_ASSET_ID, directory_id: SECOND_ASSET_ID, manifest: { without_model: true })

      storage = Storage.new(root)

      assert_equal ['Windows'], storage.index.fetch('categories')
      assert_equal [ASSET_ID], storage.index.fetch('items').map { |item| item.fetch('id') }
    end
  end

  def test_v4_normalizes_public_item_values_from_the_manifest
    with_library_root do |root|
      write_asset(root, manifest: {
        'name' => '  Canonical   Door  ',
        'category' => '  Windows  ',
        'tags' => [' Door ', 'door', ''],
        'description' => "  Canonical description  "
      })

      item = Storage.new(root).item_by_id(ASSET_ID)

      assert_equal 'Canonical Door', item.fetch('name')
      assert_equal 'Windows', item.fetch('category')
      assert_equal ['door'], item.fetch('tags')
      assert_equal 'Canonical description', item.fetch('description')
    end
  end

  def test_v4_adapter_rejects_mutations_without_changing_assets_catalog_or_categories
    with_library_root do |root|
      write_asset(root)
      storage = Storage.new(root)
      asset_dir = File.join(root, 'assets', ASSET_ID)
      catalog_before = File.binread(File.join(root, 'library.json'))
      manifest_before = File.binread(File.join(asset_dir, 'asset.json'))
      model_before = File.binread(File.join(asset_dir, 'model.skp'))

      assert_raises(ArgumentError) { storage.toggle_favorite!(ASSET_ID, true) }
      assert_raises(ArgumentError) { storage.add_category!('Mutated category') }
      assert_equal catalog_before, File.binread(File.join(root, 'library.json'))
      assert_equal manifest_before, File.binread(File.join(asset_dir, 'asset.json'))
      assert_equal model_before, File.binread(File.join(asset_dir, 'model.skp'))
      refute File.exist?(File.join(root, 'library_index.json'))
      refute Dir.exist?(File.join(root, 'categories', 'Mutated category'))
    end
  end

  def test_empty_root_keeps_the_legacy_v3_index_contract
    with_library_root do |root|
      storage = Storage.new(root)

      assert_equal Storage::FORMAT_V3, storage.index.fetch('version')
      assert File.file?(File.join(root, 'library_index.json'))
      refute File.exist?(File.join(root, 'library.json'))
    end
  end

  def test_v3_library_stays_compatible
    fixture = File.expand_path('fixtures/library_v3', __dir__)
    with_library_root do |root|
      FileUtils.cp_r(Dir.glob(File.join(fixture, '*')), root)

      item = Storage.new(root).item_by_id(ASSET_ID)

      assert_equal 'Door', item.fetch('name')
      assert_equal 'categories/Doors/Door__a1b2c3d4.skp', item.fetch('skp_rel_path')
      refute File.exist?(File.join(root, 'library.json'))
    end
  end

  def test_accidental_empty_assets_directory_does_not_hide_a_v3_library
    fixture = File.expand_path('fixtures/library_v3', __dir__)
    with_library_root do |root|
      FileUtils.cp_r(Dir.glob(File.join(fixture, '*')), root)
      FileUtils.mkdir_p(File.join(root, 'assets'))

      item = Storage.new(root).item_by_id(ASSET_ID)

      assert_equal 'Door', item && item['name']
      refute File.exist?(File.join(root, 'library.json'))
    end
  end

  def test_stale_non_asset_directory_does_not_hide_a_v3_library
    fixture = File.expand_path('fixtures/library_v3', __dir__)
    with_library_root do |root|
      FileUtils.cp_r(Dir.glob(File.join(fixture, '*')), root)
      FileUtils.mkdir_p(File.join(root, 'assets', 'stale-copy'))

      item = Storage.new(root).item_by_id(ASSET_ID)

      assert_equal 'Door', item && item['name']
      refute File.exist?(File.join(root, 'library.json'))
    end
  end
end
