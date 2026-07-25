require_relative 'test_helper'
require_relative '../component_library_browser/storage'
require 'json'
require 'digest'

Storage = Drale::ComponentLibraryBrowser::Storage

class StorageV4Test < Minitest::Test
  ASSET_ID = '11111111-1111-1111-1111-111111111111'.freeze
  SECOND_ASSET_ID = '22222222-2222-2222-2222-222222222222'.freeze

  def setup
    @previous_clb_test_mode = ENV['CLB_TEST_MODE']
    ENV['CLB_TEST_MODE'] = '1'
  end

  def teardown
    @previous_clb_test_mode.nil? ? ENV.delete('CLB_TEST_MODE') : ENV['CLB_TEST_MODE'] = @previous_clb_test_mode
  end

  def with_library_root
    Dir.mktmpdir('component-library-v4') { |root| yield root }
  end

  def write_asset(root, id: ASSET_ID, directory_id: id, manifest: {})
    asset_dir = File.join(root, 'assets', directory_id)
    FileUtils.mkdir_p(asset_dir)
    File.write(File.join(asset_dir, 'model.skp'), 'skp') unless manifest.delete(:without_model)

    without_asset_version = manifest.delete(:without_asset_version)
    payload = canonical_manifest(id).merge(manifest)
    payload.delete('asset_version') if without_asset_version
    File.write(File.join(asset_dir, 'asset.json'), JSON.pretty_generate(payload)) unless manifest.delete(:unreadable)
    asset_dir
  end

  def canonical_manifest(id, name: 'Door', category: 'Doors')
    {
      'asset_version' => 1,
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

  def v4_payload_paths(root, id = ASSET_ID)
    asset_dir = File.join(root, 'assets', id)
    {
      'model.skp' => File.join(asset_dir, 'model.skp'),
      'preview.png' => File.join(asset_dir, 'preview.png'),
      'asset.json' => File.join(asset_dir, 'asset.json')
    }
  end

  def write_v4_preview(root, bytes = 'preview')
    File.binwrite(v4_payload_paths(root).fetch('preview.png'), bytes)
  end

  def create_directory_link(target, link)
    File.symlink(target, link)
    true
  rescue NotImplementedError, Errno::EACCES, Errno::EPERM
    return false unless Gem.win_platform?

    system(%(cmd /d /c mklink /J "#{link}" "#{target}"), out: File::NULL, err: File::NULL)
  end

  def write_pending_transaction(root, phase:, operation:, original:, current:, corrupt_backup: false, txid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', payload_overrides: {})
    tx_root = File.join(root, '.clb', 'transactions', txid)
    before_root = File.join(tx_root, 'before')
    snapshot_path = File.join(root, '.clb', 'snapshots', "#{txid}-library.json")
    FileUtils.mkdir_p(before_root)
    FileUtils.mkdir_p(File.dirname(snapshot_path))
    File.binwrite(snapshot_path, original.fetch('catalog'))

    payloads = original.fetch('payloads').map do |name, bytes|
      before_path = File.join(before_root, name)
      File.binwrite(before_path, corrupt_backup && name == 'model.skp' ? 'corrupt-backup' : bytes)
      {
        'name' => name,
        'existed' => true,
        'sha256' => Digest::SHA256.hexdigest(bytes),
        'backup_ready' => true
      }.merge(payload_overrides.fetch(name, {}))
    end

    current.fetch('payloads').each { |name, bytes| File.binwrite(v4_payload_paths(root).fetch(name), bytes) }
    File.binwrite(File.join(root, 'library.json'), current.fetch('catalog'))
    journal = {
      'version' => 2,
      'id' => txid,
      'state' => phase,
      'operation' => operation,
      'item_id' => ASSET_ID,
      'created_at' => '2026-07-25T12:00:00Z',
      'updated_at' => '2026-07-25T12:00:00Z',
      'payloads' => payloads,
      'catalog_snapshot' => {
        'existed' => true,
        'sha256' => Digest::SHA256.hexdigest(original.fetch('catalog'))
      }
    }
    File.write("#{tx_root}.json", JSON.pretty_generate(journal))
    "#{tx_root}.json"
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

  def test_catalog_rebuild_uses_its_own_unique_temp_and_leaves_no_temp_files
    with_library_root do |root|
      write_asset(root)
      catalog_path = File.join(root, 'library.json')
      unrelated_tmp = "#{catalog_path}.tmp"
      File.write(unrelated_tmp, 'unrelated')

      Storage.new(root)

      assert_equal 'unrelated', File.file?(unrelated_tmp) ? File.read(unrelated_tmp) : nil
      assert_empty Dir.glob(File.join(root, 'library.json.*.tmp'))
      assert_equal ASSET_ID, read_catalog(root).fetch('assets').first.fetch('id')
    end
  end

  def test_catalog_rebuild_propagates_atomic_replace_failure
    with_library_root do |root|
      write_asset(root)
      FileUtils.mkdir_p(File.join(root, 'library.json'))

      assert_raises(SystemCallError) { Storage.new(root) }
      assert_empty Dir.glob(File.join(root, 'library.json.*.tmp'))
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

  def test_v4_rejects_assets_without_integer_asset_version_one
    [
      { without_asset_version: true },
      { 'asset_version' => nil },
      { 'asset_version' => '1' },
      { 'asset_version' => 2 }
    ].each do |version_override|
      with_library_root do |root|
        write_asset(root, manifest: version_override)

        storage = Storage.new(root)
        recovery = Array(storage.index['recovery']).first || {}

        assert_nil storage.item_by_id(ASSET_ID)
        assert_match(/asset_version/, recovery['reason'].to_s)
      end
    end
  end

  def test_v4_rejects_noncanonical_or_reversed_manifest_timestamps
    [
      { 'created_at' => '2026-07-25T12:00:00+00:00' },
      { 'updated_at' => 'not-a-timestamp' },
      { 'created_at' => '2026-07-25T13:00:00Z', 'updated_at' => '2026-07-25T12:00:00Z' }
    ].each do |timestamps|
      with_library_root do |root|
        write_asset(root, manifest: timestamps)

        storage = Storage.new(root)
        recovery = Array(storage.index['recovery']).first || {}

        assert_nil storage.item_by_id(ASSET_ID)
        assert_match(/timestamp/, recovery['reason'].to_s)
      end
    end
  end

  def test_v4_category_is_catalog_only
    with_library_root do |root|
      write_asset(root)
      storage = Storage.new(root)
      assert storage.add_category!('Empty category')
      assert_includes storage.index.fetch('categories'), 'Empty category'
      assert_includes read_catalog(root).fetch('categories'), 'Empty category'
      refute Dir.exist?(File.join(root, 'categories'))
    end
  end

  def test_empty_root_starts_a_v4_library
    with_library_root do |root|
      storage = Storage.new(root)

      assert_equal Storage::FORMAT_V4, storage.index.fetch('version')
      assert File.file?(File.join(root, 'library.json'))
      refute File.exist?(File.join(root, 'library_index.json'))
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

  def test_checkpoint_a_v4_rebuilds_from_asset_manifest_without_changing_v3_fixture_bytes
    with_library_root do |root|
      write_asset(root, manifest: { 'name' => 'Manifest authority' })

      item = Storage.new(root).item_by_id(ASSET_ID)

      assert_equal 'Manifest authority', item.fetch('name')
    end

    fixture = File.expand_path('fixtures/library_v3', __dir__)
    fixture_bytes = Dir.glob(File.join(fixture, '**', '*')).select { |path| File.file?(path) }
                       .to_h { |path| [path.delete_prefix("#{fixture}#{File::SEPARATOR}"), File.binread(path)] }
    with_library_root do |root|
      FileUtils.cp_r(Dir.glob(File.join(fixture, '*')), root)

      Storage.new(root)

      actual_bytes = Dir.glob(File.join(root, '**', '*')).select { |path| File.file?(path) }
                        .to_h { |path| [path.delete_prefix("#{root}#{File::SEPARATOR}"), File.binread(path)] }
      assert_equal fixture_bytes, actual_bytes
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

  def test_parseable_v4_catalog_activates_v4_without_a_v3_index_even_when_stale
    with_library_root do |root|
      File.write(File.join(root, 'library.json'), JSON.pretty_generate(
        'version' => 4,
        'created_at' => 'not-a-timestamp',
        'updated_at' => 'not-a-timestamp',
        'assets' => [{ 'id' => ASSET_ID, 'asset_rel_path' => "assets/#{ASSET_ID}", 'updated_at' => 'not-a-timestamp' }]
      ))

      storage = Storage.new(root)

      assert_equal Storage::FORMAT_V4, storage.index.fetch('version')
      assert_equal [], read_catalog(root).fetch('assets')
      refute File.exist?(File.join(root, 'library_index.json'))
    end
  end

  def test_invalid_assets_without_v3_activate_v4_recovery_and_rebuild_catalog
    with_library_root do |root|
      write_asset(root, id: SECOND_ASSET_ID, directory_id: ASSET_ID)
      write_asset(root, id: SECOND_ASSET_ID, directory_id: SECOND_ASSET_ID, manifest: { unreadable: true })

      storage = Storage.new(root)
      catalog = File.file?(File.join(root, 'library.json')) ? read_catalog(root) : {}

      assert_equal Storage::FORMAT_V4, storage.index['version']
      assert_equal [ASSET_ID, SECOND_ASSET_ID], Array(storage.index['recovery']).map { |entry| entry['id'] }.sort
      assert_equal [], catalog['assets']
      refute File.exist?(File.join(root, 'library_index.json'))
    end
  end

  def test_incomplete_v4_catalog_does_not_override_or_rewrite_a_v3_library
    fixture = File.expand_path('fixtures/library_v3', __dir__)
    with_library_root do |root|
      FileUtils.cp_r(Dir.glob(File.join(fixture, '*')), root)
      catalog_path = File.join(root, 'library.json')
      catalog_before = '{"version":4}'
      File.write(catalog_path, catalog_before)

      item = Storage.new(root).item_by_id(ASSET_ID)

      assert_equal 'Door', item && item['name']
      assert_equal catalog_before, File.read(catalog_path)
    end
  end

  def test_replace_failure_after_model_staged_restores_previous_payload_and_metadata
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)
      assert_respond_to storage, :replace_v4_asset_payloads!
      original = v4_payload_paths(root).transform_values { |path| File.binread(path) }

      ENV['CLB_TEST_FAILURE_AFTER'] = 'model_staged'
      assert_raises(RuntimeError) do
        storage.replace_v4_asset_payloads!(ASSET_ID, {
          'model.skp' => 'new-model',
          'preview.png' => 'new-preview',
          'asset.json' => JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'New door'))
        })
      end

      assert_equal original, v4_payload_paths(root).transform_values { |path| File.binread(path) }
      assert_empty Dir.glob(File.join(root, '.clb', 'transactions', '*.json'))
      assert_empty Dir.glob("#{v4_payload_paths(root).fetch('model.skp')}.new-*")
    ensure
      ENV.delete('CLB_TEST_FAILURE_AFTER')
    end
  end

  def test_backup_copy_failure_leaves_original_payloads_untouched
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)
      original = v4_payload_paths(root).transform_values { |path| File.binread(path) }

      ENV['CLB_TEST_FAILURE_AFTER'] = 'backup_model_copied'
      assert_raises(RuntimeError) do
        storage.replace_v4_asset_payloads!(ASSET_ID, {
          'model.skp' => 'new-model',
          'preview.png' => 'new-preview',
          'asset.json' => JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'New door'))
        })
      end

      assert_equal original, v4_payload_paths(root).transform_values { |path| File.binread(path) }
      assert_empty Dir.glob(File.join(root, '.clb', 'transactions', '*.json'))
    ensure
      ENV.delete('CLB_TEST_FAILURE_AFTER')
    end
  end

  def test_startup_recovers_delete_journal_after_payload_quarantined
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      Storage.new(root)
      paths = v4_payload_paths(root)
      original = { 'payloads' => paths.transform_values { |path| File.binread(path) }, 'catalog' => File.binread(File.join(root, 'library.json')) }
      original.fetch('payloads').each_key { |name| File.delete(paths.fetch(name)) }
      journal_path = write_pending_transaction(root, phase: 'payload_quarantined', operation: 'delete', original: original,
                                                current: { 'payloads' => {}, 'catalog' => original.fetch('catalog') })

      recovered = Storage.new(root)

      assert File.file?(paths.fetch('model.skp'))
      assert_equal 'skp', File.binread(paths.fetch('model.skp'))
      assert_equal ASSET_ID, recovered.item_by_id(ASSET_ID).fetch('id')
      refute File.exist?(journal_path)
    end
  end

  def test_startup_recovers_replace_after_payload_committed_before_catalog
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      Storage.new(root)
      paths = v4_payload_paths(root)
      original = { 'payloads' => paths.transform_values { |path| File.binread(path) }, 'catalog' => File.binread(File.join(root, 'library.json')) }
      File.binwrite("#{paths.fetch('model.skp')}.new-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 'staged-model')
      write_pending_transaction(root, phase: 'payload_committed', operation: 'replace', original: original,
                                current: { 'payloads' => { 'model.skp' => 'new-model', 'preview.png' => 'new-preview', 'asset.json' => JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'Changed')) }, 'catalog' => original.fetch('catalog') })

      recovered = Storage.new(root)

      assert_equal original.fetch('payloads'), paths.transform_values { |path| File.binread(path) }
      assert_empty Dir.glob("#{paths.fetch('model.skp')}.new-*")
      assert_equal({ 'id' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operation' => 'replace', 'phase' => 'payload_committed' }, recovered.recovery_status.fetch('transactions').first)
    end
  end

  def test_startup_recovers_replace_after_manifest_committed_before_catalog
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      Storage.new(root)
      paths = v4_payload_paths(root)
      original = { 'payloads' => paths.transform_values { |path| File.binread(path) }, 'catalog' => File.binread(File.join(root, 'library.json')) }
      changed_manifest = JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'Changed'))
      write_pending_transaction(root, phase: 'manifest_committed', operation: 'replace', original: original,
                                current: { 'payloads' => { 'model.skp' => 'new-model', 'preview.png' => 'new-preview', 'asset.json' => changed_manifest }, 'catalog' => '{"version":4,"assets":[]}' })

      Storage.new(root)

      assert_equal original.fetch('payloads').fetch('model.skp'), File.binread(paths.fetch('model.skp'))
      assert_equal original.fetch('payloads').fetch('asset.json'), File.binread(paths.fetch('asset.json'))
      assert_equal original.fetch('catalog'), File.binread(File.join(root, 'library.json'))
    end
  end

  def test_startup_stops_recovery_without_mutating_when_backup_hash_mismatches
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      Storage.new(root)
      paths = v4_payload_paths(root)
      original = { 'payloads' => paths.transform_values { |path| File.binread(path) }, 'catalog' => File.binread(File.join(root, 'library.json')) }
      journal_path = write_pending_transaction(root, phase: 'payload_committed', operation: 'replace', original: original,
                                                current: { 'payloads' => { 'model.skp' => 'new-model', 'preview.png' => 'new-preview', 'asset.json' => JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'Changed')) }, 'catalog' => '{"version":4,"assets":[]}' }, corrupt_backup: true)
      current_model = File.binread(paths.fetch('model.skp'))
      current_catalog = File.binread(File.join(root, 'library.json'))

      recovered = Storage.new(root)

      assert_equal current_model, File.binread(paths.fetch('model.skp'))
      assert_equal current_catalog, File.binread(File.join(root, 'library.json'))
      assert File.exist?(journal_path)
      assert_includes recovered.recovery_status.fetch('transactions').first.fetch('reason'), 'SHA256'
    end
  end

  def test_startup_preserves_external_sentinel_for_traversal_transaction_id
    with_library_root do |root|
      write_asset(root)
      Storage.new(root)
      sentinel = File.join(root, 'external-sentinel.txt')
      File.binwrite(sentinel, 'do not touch')
      journal_path = File.join(root, '.clb', 'transactions', 'invalid-id.json')
      FileUtils.mkdir_p(File.dirname(journal_path))
      File.write(journal_path, JSON.generate('version' => 2, 'id' => '../..', 'state' => 'payload_committed', 'operation' => 'replace', 'item_id' => ASSET_ID, 'payloads' => [], 'catalog_snapshot' => { 'existed' => false }))

      recovered = Storage.new(root)

      assert_equal 'do not touch', File.binread(sentinel)
      assert File.file?(journal_path)
      assert_includes recovered.recovery_status.fetch('transactions').first.fetch('reason'), 'transaction id'
    end
  end

  def test_startup_preserves_external_sentinel_when_journal_contains_path_fields
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      Storage.new(root)
      sentinel = File.join(root, 'external-sentinel.txt')
      File.binwrite(sentinel, 'do not touch')
      paths = v4_payload_paths(root)
      original = { 'payloads' => paths.transform_values { |path| File.binread(path) }, 'catalog' => File.binread(File.join(root, 'library.json')) }
      journal_path = write_pending_transaction(root, phase: 'payload_committed', operation: 'replace', original: original,
                                                current: { 'payloads' => original.fetch('payloads'), 'catalog' => original.fetch('catalog') },
                                                payload_overrides: { 'model.skp' => { 'path' => sentinel } })

      recovered = Storage.new(root)

      assert_equal 'do not touch', File.binread(sentinel)
      assert File.file?(journal_path)
      assert_includes recovered.recovery_status.fetch('transactions').first.fetch('reason'), 'path field'
    end
  end

  def test_successful_transaction_cleans_journal_and_before_backup_after_catalog_commit
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)
      assert_respond_to storage, :replace_v4_asset_payloads!

      storage.replace_v4_asset_payloads!(ASSET_ID, {
        'model.skp' => 'new-model',
        'preview.png' => 'new-preview',
        'asset.json' => JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'New door'))
      })

      assert_equal 'new-model', File.binread(v4_payload_paths(root).fetch('model.skp'))
      assert_empty Dir.glob(File.join(root, '.clb', 'transactions', '*.json'))
      assert_empty Dir.glob(File.join(root, '.clb', 'transactions', '*', 'before'))
      assert_operator Dir.glob(File.join(root, '.clb', 'snapshots', '*.json')).length, :<=, 20
    end
  end

  def test_startup_catalog_committed_keeps_new_payload_and_only_cleans_transaction_artifacts
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      Storage.new(root)
      paths = v4_payload_paths(root)
      original = { 'payloads' => paths.transform_values { |path| File.binread(path) }, 'catalog' => File.binread(File.join(root, 'library.json')) }
      new_manifest = JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'New door'))
      new_catalog = JSON.generate('version' => 4, 'created_at' => '2026-07-25T12:00:00Z', 'updated_at' => '2026-07-25T12:00:00Z', 'assets' => [{ 'id' => ASSET_ID, 'asset_rel_path' => "assets/#{ASSET_ID}", 'updated_at' => '2026-07-25T12:00:00Z' }])
      journal_path = write_pending_transaction(root, phase: 'catalog_committed', operation: 'replace', original: original,
                                                current: { 'payloads' => { 'model.skp' => 'new-model', 'preview.png' => 'new-preview', 'asset.json' => new_manifest }, 'catalog' => new_catalog })

      recovered = Storage.new(root)

      assert_equal 'new-model', File.binread(paths.fetch('model.skp'))
      assert_equal new_catalog, File.binread(File.join(root, 'library.json'))
      refute File.exist?(journal_path)
      assert_empty Dir.glob(File.join(root, '.clb', 'transactions', '*', 'before'))
      assert_equal({ 'id' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operation' => 'replace', 'phase' => 'catalog_committed' }, recovered.recovery_status.fetch('transactions').first)
    end
  end

  def test_failure_after_catalog_replacement_before_journal_phase_restores_old_state
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)
      original = v4_payload_paths(root).transform_values { |path| File.binread(path) }
      original_catalog = File.binread(File.join(root, 'library.json'))

      ENV['CLB_TEST_FAILURE_AFTER'] = 'catalog_replaced'
      assert_raises(RuntimeError) do
        storage.replace_v4_asset_payloads!(ASSET_ID, {
          'model.skp' => 'new-model',
          'preview.png' => 'new-preview',
          'asset.json' => JSON.generate(canonical_manifest(ASSET_ID).merge('name' => 'New door'))
        })
      end

      assert_equal original, v4_payload_paths(root).transform_values { |path| File.binread(path) }
      assert_equal original_catalog, File.binread(File.join(root, 'library.json'))
      assert_empty Dir.glob(File.join(root, '.clb', 'transactions', '*.json'))
    ensure
      ENV.delete('CLB_TEST_FAILURE_AFTER')
    end
  end

  def test_clb_link_outside_library_aborts_without_touching_external_sentinel
    Dir.mktmpdir('component-library-parent') do |parent|
      root = File.join(parent, 'library')
      outside = File.join(parent, 'outside')
      FileUtils.mkdir_p([root, outside])
      sentinel = File.join(outside, 'sentinel.txt')
      File.binwrite(sentinel, 'do not touch')
      link = File.join(root, '.clb')
      linked = create_directory_link(outside, link)
      skip 'This environment cannot create directory links.' unless linked

      assert_raises(ArgumentError) { Storage.new(root) }
      assert_equal 'do not touch', File.binread(sentinel)
      assert_empty Dir.children(outside).reject { |name| name == 'sentinel.txt' }
    ensure
      if defined?(link) && File.symlink?(link)
        File.delete(link)
      elsif defined?(link) && File.directory?(link)
        Dir.rmdir(link)
      end
    end
  end

  FakeBounds = Struct.new(:width, :depth, :height)
  class FakeDefinition
    attr_reader :bounds

    def initialize(model = 'saved-model', preview = 'saved-preview')
      @model = model
      @preview = preview
      @bounds = FakeBounds.new(1, 2, 3)
    end

    def save_copy(path)
      File.binwrite(path, @model)
      true
    end

    def save_thumbnail(path)
      File.binwrite(path, @preview)
      true
    end
  end

  def test_save_definition_writes_a_self_contained_v4_asset_and_catalog
    with_library_root do |root|
      storage = Storage.new(root)

      result = storage.save_definition!(FakeDefinition.new, source: 'component', category: 'Doors', display_name: 'Door', tags: ['Door'], description: 'A door')
      item = result.fetch('item')
      asset_dir = File.join(root, 'assets', item.fetch('id'))

      assert File.file?(File.join(asset_dir, 'model.skp'))
      assert File.file?(File.join(asset_dir, 'asset.json'))
      assert File.file?(File.join(asset_dir, 'preview.png'))
      assert_equal "assets/#{item.fetch('id')}", read_catalog(root).fetch('assets').first.fetch('asset_rel_path')
      refute Dir.exist?(File.join(root, 'categories'))
    end
  end

  def test_v4_metadata_edits_keep_payload_bytes_and_asset_paths_stable
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)
      paths = v4_payload_paths(root)
      original = paths.transform_values { |path| File.binread(path) }

      storage.edit_item!(ASSET_ID, 'name' => 'Renamed', 'category' => 'Windows', 'tags' => ['window'], 'description' => 'Updated')
      item = storage.item_by_id(ASSET_ID)

      assert_equal original.slice('model.skp', 'preview.png'), paths.slice('model.skp', 'preview.png').transform_values { |path| File.binread(path) }
      assert_equal "assets/#{ASSET_ID}/model.skp", item.fetch('skp_rel_path')
      assert_equal "assets/#{ASSET_ID}/preview.png", item.fetch('thumb_rel_path')
      assert_equal 'Windows', item.fetch('category')
    end
  end

  def test_v4_manifest_mutations_are_transactional_and_scan_preserves_user_metadata
    with_library_root do |root|
      write_asset(root)
      storage = Storage.new(root)

      storage.toggle_favorite!(ASSET_ID, true)
      storage.update_item_metadata!(ASSET_ID, 'faces_count' => 9)
      storage.set_content_hash!(ASSET_ID, 'abc')
      storage.touch_last_used!(ASSET_ID)
      count = storage.scan_library!
      item = storage.item_by_id(ASSET_ID)

      assert_equal 1, count
      assert item.fetch('favorite')
      assert_equal 9, item.fetch('faces_count')
      assert_equal 'abc', item.fetch('content_hash')
      refute_nil item.fetch('last_used_at')
    end
  end

  def test_v4_delete_quarantines_entire_asset_payload_in_trash
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)

      assert storage.delete_item!(ASSET_ID)
      assert_nil storage.item_by_id(ASSET_ID)
      trashed = Dir.glob(File.join(root, '.clb', 'trash', '*', ASSET_ID))
      assert_equal 1, trashed.length
      assert File.file?(File.join(trashed.first, 'model.skp'))
      assert File.file?(File.join(trashed.first, 'asset.json'))
      assert File.file?(File.join(trashed.first, 'preview.png'))
    end
  end

  def test_v4_replace_commits_model_then_metadata_and_rolls_back_on_failure
    with_library_root do |root|
      write_asset(root, manifest: { 'favorite' => true, 'description' => 'Keep me', 'content_hash' => 'old-hash' })
      storage = Storage.new(root)
      before = v4_payload_paths(root).transform_values { |path| File.file?(path) ? File.binread(path) : nil }

      ENV['CLB_TEST_FAILURE_AFTER'] = 'model_staged'
      assert_raises(RuntimeError) { storage.replace_item_definition!(ASSET_ID, FakeDefinition.new('new-model'), source: 'component', metadata: { 'faces_count' => 12 }, content_hash: 'new-hash') }
      assert_equal before, v4_payload_paths(root).transform_values { |path| File.file?(path) ? File.binread(path) : nil }

      ENV.delete('CLB_TEST_FAILURE_AFTER')
      replaced = storage.replace_item_definition!(ASSET_ID, FakeDefinition.new('new-model'), source: 'component', metadata: { 'faces_count' => 12 }, content_hash: 'new-hash')
      assert_equal ASSET_ID, replaced.fetch('id')
      assert replaced.fetch('favorite')
      assert_equal 'Keep me', replaced.fetch('description')
      assert_equal 'new-model', File.binread(v4_payload_paths(root).fetch('model.skp'))
      assert_equal 'new-hash', replaced.fetch('content_hash')
      assert_equal 12, replaced.fetch('faces_count')
      assert_equal File.size(v4_payload_paths(root).fetch('model.skp')), replaced.fetch('file_size_bytes')
    ensure
      ENV.delete('CLB_TEST_FAILURE_AFTER')
    end
  end

  def test_v4_replace_merges_only_explicit_metadata_and_preserves_existing_hash
    with_library_root do |root|
      write_asset(root, manifest: {
        'faces_count' => 7, 'edges_count' => 8, 'materials_count' => 9, 'content_hash' => 'kept-hash'
      })
      storage = Storage.new(root)

      replaced = storage.replace_item_definition!(ASSET_ID, FakeDefinition.new('replacement'), source: 'component', metadata: { 'faces_count' => 12 })

      assert_equal 12, replaced.fetch('faces_count')
      assert_equal 8, replaced.fetch('edges_count')
      assert_equal 9, replaced.fetch('materials_count')
      assert_equal 'kept-hash', replaced.fetch('content_hash')
    end
  end

  def test_v4_touch_last_used_keeps_legacy_nil_return_value
    with_library_root do |root|
      write_asset(root)
      storage = Storage.new(root)

      assert_nil storage.touch_last_used!(ASSET_ID)
      refute_nil storage.item_by_id(ASSET_ID).fetch('last_used_at')
    end
  end

  def test_v4_category_rename_updates_only_manifests_and_empty_category_can_be_deleted
    with_library_root do |root|
      write_asset(root)
      write_v4_preview(root)
      storage = Storage.new(root)
      model = File.binread(v4_payload_paths(root).fetch('model.skp'))
      preview = File.binread(v4_payload_paths(root).fetch('preview.png'))

      assert storage.rename_category!('Doors', 'Windows')
      assert_equal 'Windows', storage.item_by_id(ASSET_ID).fetch('category')
      assert_equal model, File.binread(v4_payload_paths(root).fetch('model.skp'))
      assert_equal preview, File.binread(v4_payload_paths(root).fetch('preview.png'))
      assert_raises(ArgumentError) { storage.delete_category!('Windows') }
      assert storage.add_category!('Empty')
      assert storage.delete_category!('Empty')
      refute_includes storage.index.fetch('categories'), 'Empty'
      refute Dir.exist?(File.join(root, 'categories'))
    end
  end
end
