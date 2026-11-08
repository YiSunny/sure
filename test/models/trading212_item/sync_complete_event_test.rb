require "test_helper"
require "turbo/broadcastable/test_helper"

class Trading212Item::SyncCompleteEventTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  test "background completion sends the family toast without rendering a viewer dependent provider card" do
    item = trading212_items(:configured_item)
    Current.reset

    streams = capture_turbo_stream_broadcasts(item.family) do
      Trading212Item::SyncCompleteEvent.new(item).broadcast
    end

    targets = streams.map { |stream| stream["target"] }
    assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
    assert_includes targets, "sync-toast"
    assert_nil Current.user
  end
end
