module InventoryHelper
  # Badge colour for a stock-count session status.
  STOCK_COUNT_STATUS_BADGES = {
    "draft" => "badge-neutral", "in_progress" => "badge-warning",
    "completed" => "badge-accent", "approved" => "badge-success"
  }.freeze

  def stock_count_status_class(status)
    STOCK_COUNT_STATUS_BADGES.fetch(status.to_s, "badge-neutral")
  end

  # Badge colour for a goods receipt's approval_status (purchasing decision —
  # independent of whether the goods have physically arrived).
  GOODS_RECEIPT_APPROVAL_STATUS_BADGES = {
    "draft" => "badge-neutral", "pending_approval" => "badge-warning",
    "approved" => "badge-accent", "rejected" => "badge-danger"
  }.freeze

  def goods_receipt_approval_status_class(approval_status)
    GOODS_RECEIPT_APPROVAL_STATUS_BADGES.fetch(approval_status.to_s, "badge-neutral")
  end

  # Receipt (inventory) status for a goods receipt: not_received / received /
  # voided — derived from status + voided?, independent of approval_status.
  def goods_receipt_receipt_status(receipt)
    return "voided" if receipt.voided?

    receipt.confirmed? ? "received" : "not_received"
  end

  GOODS_RECEIPT_RECEIPT_STATUS_BADGES = {
    "not_received" => "badge-neutral", "received" => "badge-success", "voided" => "badge-danger"
  }.freeze

  def goods_receipt_receipt_status_class(receipt)
    GOODS_RECEIPT_RECEIPT_STATUS_BADGES.fetch(goods_receipt_receipt_status(receipt), "badge-neutral")
  end

  # Product <option>s for document line-item selects. Embeds barcode/SKU as data
  # attributes so the barcode-scanner Stimulus controller can resolve a scan
  # client-side without a server round-trip; default supplier is carried for the
  # goods-receipt supplier prefill. Shared by every document form so scanning
  # behaves identically everywhere.
  def inventory_product_options(products, selected_id)
    options_for_select(
      products.map { |p|
        all_barcodes = if p.association(:product_barcodes).loaded?
                         p.product_barcodes.map(&:barcode).compact
                       else
                         [ p.barcode ].compact
                       end
        [ "#{p.name} (#{p.sku})", p.id, {
          "data-barcode"             => all_barcodes.first,
          "data-barcodes"            => all_barcodes.join("|"),
          "data-sku"                 => p.sku,
          "data-default-supplier-id" => p.default_supplier_id
        } ]
      },
      selected_id
    )
  end
end
