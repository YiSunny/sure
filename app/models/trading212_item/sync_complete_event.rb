class Trading212Item::SyncCompleteEvent
  attr_reader :trading212_item

  def initialize(trading212_item)
    @trading212_item = trading212_item
  end

  def broadcast
    trading212_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Provider cards need a viewer to filter account access. The family toast
    # makes browsers reload their own authorized page instead (upstream #4046).
    trading212_item.family.broadcast_sync_complete
  end
end
