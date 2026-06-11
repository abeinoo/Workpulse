module InventoryHelper
  # Badge colour for a stock-count session status.
  STOCK_COUNT_STATUS_BADGES = {
    "draft" => "badge-neutral", "in_progress" => "badge-warning",
    "completed" => "badge-accent", "approved" => "badge-success"
  }.freeze

  def stock_count_status_class(status)
    STOCK_COUNT_STATUS_BADGES.fetch(status.to_s, "badge-neutral")
  end

  # Product <option>s for document line-item selects. Embeds barcode/SKU as data
  # attributes so the barcode-scanner Stimulus controller can resolve a scan
  # client-side without a server round-trip; default supplier is carried for the
  # goods-receipt supplier prefill. Shared by every document form so scanning
  # behaves identically everywhere.
  def inventory_product_options(products, selected_id)
    options_for_select(
      products.map { |p|
        [ "#{p.name} (#{p.sku})", p.id, {
          "data-barcode"             => p.barcode,
          "data-sku"                 => p.sku,
          "data-default-supplier-id" => p.default_supplier_id
        } ]
      },
      selected_id
    )
  end
end
