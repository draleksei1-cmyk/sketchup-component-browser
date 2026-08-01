# frozen_string_literal: true

require_relative 'test_helper'

class FlatStorageContractTest < Minitest::Test
  ASSET_ID = '11111111-1111-1111-1111-111111111111'.freeze

  def test_asset_payload_paths_are_flat_and_id_addressed
    assert_equal "assets/#{ASSET_ID}.skp", FS.asset_model_rel_path(ASSET_ID)
    assert_equal "assets/#{ASSET_ID}.png", FS.asset_preview_rel_path(ASSET_ID)
    assert_equal "assets/#{ASSET_ID}.json", FS.asset_metadata_rel_path(ASSET_ID)
  end
end
