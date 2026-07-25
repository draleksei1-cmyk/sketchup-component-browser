require_relative 'test_helper'

class FSTest < Minitest::Test
  ASSET_ID = '11111111-1111-1111-1111-111111111111'.freeze

  def with_library_root
    Dir.mktmpdir('component-library') { |root| yield root }
  end

  def test_v4_format_constants_are_immutable
    assert_equal 4, FS::FORMAT_VERSION
    assert_equal 'assets', FS::ASSETS_DIR
    assert_equal '.clb', FS::INTERNAL_DIR
    assert_equal 'library.json', FS::CATALOG_FILENAME
  end

  def test_asset_relative_paths_follow_v4_contract
    assert_equal "assets/#{ASSET_ID}/model.skp", FS.asset_model_rel_path(ASSET_ID)
    assert_equal "assets/#{ASSET_ID}/preview.png", FS.asset_preview_rel_path(ASSET_ID)
    assert_equal "assets/#{ASSET_ID}/metadata.json", FS.asset_metadata_rel_path(ASSET_ID)
  end

  def test_v4_roots_and_catalog_paths_follow_contract
    with_library_root do |root|
      assert_equal File.join(root, 'assets'), FS.assets_root(root)
      assert_equal File.join(root, 'assets', ASSET_ID), FS.asset_dir(root, ASSET_ID)
      assert_equal File.join(root, 'library.json'), FS.catalog_path(root)
      assert_equal File.join(root, '.clb'), FS.internal_root(root)
      assert_equal File.join(root, '.clb', 'transactions'), FS.transactions_root(root)
      assert_equal File.join(root, '.clb', 'snapshots'), FS.snapshots_root(root)
      assert_equal File.join(root, '.clb', 'trash'), FS.trash_root(root)
    end
  end

  def test_full_asset_path_is_contained_by_library_root
    with_library_root do |root|
      full_path = FS.to_full_path(root, FS.asset_model_rel_path(ASSET_ID))

      assert FS.path_within_root?(root, full_path)
      assert_equal File.join(root, 'assets', ASSET_ID, 'model.skp'), full_path
    end
  end

  def test_to_full_path_normalizes_valid_relative_paths_and_windows_separators
    with_library_root do |root|
      assert_equal File.join(root, 'assets', ASSET_ID, 'preview.png'),
                   FS.to_full_path(root, "assets\\#{ASSET_ID}\\preview.png")
      assert_equal File.join(root, 'assets', ASSET_ID, 'preview.png'),
                   FS.to_full_path(root, "assets/#{ASSET_ID}/nested/../preview.png")
    end
  end

  def test_to_full_path_preserves_spaces_in_valid_relative_paths
    with_library_root do |root|
      assert_equal File.join(root, 'assets', 'Door model.skp'),
                   FS.to_full_path(root, 'assets/Door model.skp')
    end
  end

  def test_to_full_path_rejects_blank_absolute_and_escaping_paths
    with_library_root do |root|
      ['', '   ', nil, '../outside.skp', '..\\outside.skp', '/outside.skp', 'C:\\outside.skp'].each do |path|
        assert_raises(ArgumentError) { FS.to_full_path(root, path) }
      end
    end
  end

  def test_path_within_root_requires_a_directory_boundary
    with_library_root do |root|
      refute FS.path_within_root?(root, "#{root}-other\\asset.skp")
      refute FS.path_within_root?(root, File.dirname(root))
    end
  end
end
