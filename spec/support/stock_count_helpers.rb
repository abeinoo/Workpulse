# Drives a stock count through the real lifecycle services, so every counted
# row carries a physical count time and the ledger baseline read at that
# moment — exactly as on the counting screen. A row built directly with a
# counted_quantity (no quantity_source) is a LEGACY, unverified quantity; build
# one that way only to test legacy behaviour.
module StockCountHelpers
  # lines: [[product, quantity], …]; quantity nil leaves the row uncounted.
  # The session preloads every transactable product; unlisted ones stay uncounted.
  def record_stock_count!(business:, warehouse:, counter:, lines:, complete: false, counted_on: Date.current)
    created = Inventory::StockCountCreator.new(actor: counter, warehouse_id: warehouse.id, counted_on: counted_on).call
    raise "create failed: #{created.error}" unless created.ok?

    count = created.count
    record_counts!(count, counter, lines) if lines.any?   # no lines: stays draft
    complete_stock_count!(count, counter) if complete
    count.reload
  end

  def record_counts!(count, actor, lines)
    entries = lines.map { |product, quantity| { product_id: product.id, counted_quantity: quantity&.to_s } }
    result  = Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: actor, entries: entries).call
    raise "record failed: #{result.error}" unless result.ok?

    count.reload
  end

  def complete_stock_count!(count, actor)
    result = Inventory::StockCountCompletion.new(stock_count_id: count.id, actor: actor).call
    raise "complete failed: #{result.error}" unless result.ok?

    count.reload
  end

  def approve_stock_count(count, actor)
    Inventory::StockCountApprover.new(stock_count_id: count.id, actor: actor).call
  end

  def reopen_stock_count(count, actor, reason: "Recount needed")
    Inventory::StockCountReopener.new(stock_count_id: count.id, actor: actor, reason: reason).call
  end

  def user_with_stock_permissions(business, *permissions, name: "Role #{SecureRandom.hex(3)}")
    role = business.permission_roles.create!(name: name, permissions: permissions.map(&:to_s))
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
end

RSpec.configure { |config| config.include StockCountHelpers }
