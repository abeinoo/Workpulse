module InventoryHelper
  # Badge colour for a stock-count session status.
  STOCK_COUNT_STATUS_BADGES = {
    "draft" => "badge-neutral", "in_progress" => "badge-warning",
    "completed" => "badge-accent", "approved" => "badge-success"
  }.freeze

  # Links a ledger movement's source document by its number — the document a
  # report row came from. Falls back to plain text when there is no route.
  INVENTORY_SOURCE_PATHS = {
    "GoodsReceipt"    => :inventory_goods_receipt_path,
    "StockIssue"      => :inventory_stock_issue_path,
    "StockTransfer"   => :inventory_stock_transfer_path,
    "StockAdjustment" => :inventory_stock_adjustment_path,
    "LaundryBatch"    => :laundry_laundry_batch_path
  }.freeze

  def inventory_source_document_link(source, number)
    return "—" if source.nil?

    label = number.presence ||
            "#{t("inventory.reports.source_types.#{source.class.name}", default: source.class.name)} ##{source.id}"
    path  = INVENTORY_SOURCE_PATHS[source.class.name]
    path ? link_to(label, public_send(path, source), class: "link") : label
  end

  # Operational kind of a ledger movement for dashboard badges.
  MOVEMENT_KINDS = {
    "goods_receipt" => [ :receipt, "badge-success" ], "opening_balance" => [ :adjustment, "badge-neutral" ],
    "stock_issue" => [ :issue, "badge-warning" ], "laundry_consumption" => [ :issue, "badge-warning" ],
    "transfer_in" => [ :transfer, "badge-accent" ], "transfer_out" => [ :transfer, "badge-accent" ],
    "adjustment" => [ :adjustment, "badge-neutral" ], "reversal" => [ :reversal, "badge-danger" ]
  }.freeze

  def inventory_movement_badge(reason)
    kind, css = MOVEMENT_KINDS.fetch(reason.to_s, [ :adjustment, "badge-neutral" ])
    content_tag(:span, t("inventory.dashboard.overview.kinds.#{kind}"), class: "badge #{css}")
  end

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

  # Badge colour for a goods receipt's financial_status (Settleable, derived
  # from its FinancialSettlement ledger).
  GOODS_RECEIPT_FINANCIAL_STATUS_BADGES = {
    "pending_settlement" => "badge-warning", "partially_settled" => "badge-accent", "settled" => "badge-success"
  }.freeze

  def goods_receipt_financial_status_class(financial_status)
    GOODS_RECEIPT_FINANCIAL_STATUS_BADGES.fetch(financial_status.to_s, "badge-neutral")
  end

  # Marker colour + icon for one Activity Timeline entry (built by
  # Inventory::GoodsReceiptsController#build_timeline_events). Kept together
  # as presentation-only lookups so the view never branches on event type.
  GOODS_RECEIPT_TIMELINE_MARKER_CLASSES = {
    created: "activity-timeline__marker--neutral", submitted: "activity-timeline__marker--warning",
    approved: "activity-timeline__marker--success", rejected: "activity-timeline__marker--danger",
    settled: "activity-timeline__marker--accent", received: "activity-timeline__marker--success",
    voided: "activity-timeline__marker--danger", settlement_reversed: "activity-timeline__marker--warning"
  }.freeze

  def goods_receipt_timeline_marker_class(type)
    GOODS_RECEIPT_TIMELINE_MARKER_CLASSES.fetch(type, "activity-timeline__marker--neutral")
  end

  # Heroicons-outline (24x24, stroke-based) paths — inherits marker colour via
  # stroke="currentColor", matching the stroke-icon convention used elsewhere.
  GOODS_RECEIPT_TIMELINE_ICONS = {
    created:   "M12 9v6m3-3H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
    submitted: "M6 12 3.269 3.125A59.769 59.769 0 0 1 21.485 12 59.768 59.768 0 0 1 3.27 20.875L5.999 12Zm0 0h7.5",
    approved:  "M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
    rejected:  "m9.75 9.75 4.5 4.5m0-4.5-4.5 4.5M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
    settled:   "M2.25 8.25h19.5M2.25 9h19.5m-16.5 5.25h6m-9.75 4.5h15a2.25 2.25 0 0 0 2.25-2.25V6.75A2.25 2.25 0 0 0 19.5 4.5h-15a2.25 2.25 0 0 0-2.25 2.25v10.5A2.25 2.25 0 0 0 4.5 19.5Z",
    received:  "M20.25 7.5l-.625 10.632a2.25 2.25 0 0 1-2.247 2.118H6.622a2.25 2.25 0 0 1-2.247-2.118L3.75 7.5M10 11.25h4M3.375 7.5h17.25c.621 0 1.125-.504 1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125Z",
    voided:    "M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166M18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.02-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0"
  }.freeze

  def goods_receipt_timeline_icon(type)
    icon_type = type == :settlement_reversed ? :settled : type
    GOODS_RECEIPT_TIMELINE_ICONS.fetch(icon_type, GOODS_RECEIPT_TIMELINE_ICONS[:created])
  end

  # "Where did this payment come from?" for one FinancialSettlement row —
  # reuses the funding-source labels. A NIL source_kind is a legacy payment
  # through an untracked means (cash vs. bank unknown).
  def financial_settlement_source_label(settlement)
    return t("inventory.goods_receipts.settlements.unlinked_source") if settlement.source_kind.blank?

    t("inventory.goods_receipts.funding_source_kinds.#{settlement.source_kind}")
  end

  # Badge colour for a stock issue's workflow status. Voided is a separate,
  # terminal axis (Voidable#voided_at) checked first by the view, exactly like
  # goods receipts' receiving_status — a voided issue never shows its
  # underlying workflow-status badge.
  STOCK_ISSUE_STATUS_BADGES = {
    "draft" => "badge-neutral", "pending_approval" => "badge-warning",
    "approved" => "badge-accent", "rejected" => "badge-danger",
    "issued" => "badge-success", "cancelled" => "badge-neutral"
  }.freeze

  def stock_issue_status_class(status)
    STOCK_ISSUE_STATUS_BADGES.fetch(status.to_s, "badge-neutral")
  end

  # Badge colour for a purchase request's status.
  PURCHASE_REQUEST_STATUS_BADGES = {
    "draft" => "badge-neutral", "pending_approval" => "badge-warning",
    "approved" => "badge-accent", "partially_closed" => "badge-neutral",
    "rejected" => "badge-danger", "cancelled" => "badge-neutral"
  }.freeze

  def purchase_request_status_class(status)
    PURCHASE_REQUEST_STATUS_BADGES.fetch(status.to_s, "badge-neutral")
  end

  # Receiving state is derived from the same status column (see
  # PurchaseRequest#status) rather than stored separately — this just gives
  # the list/show pages a distinct label+badge for it, so approval status and
  # receiving status never read as the same concept even though they share a
  # column today.
  PURCHASE_REQUEST_RECEIVING_BADGES = {
    "not_started" => "badge-neutral", "partial" => "badge-warning",
    "closed" => "badge-neutral", "full" => "badge-success"
  }.freeze

  def purchase_request_receiving_status(pr)
    case pr.status
    when "partially_received" then "partial"
    when "partially_closed"   then "closed"
    when "fully_received"     then "full"
    when "approved"           then "not_started"
    end
  end

  def purchase_request_receiving_status_class(pr)
    key = purchase_request_receiving_status(pr)
    key ? PURCHASE_REQUEST_RECEIVING_BADGES.fetch(key, "badge-neutral") : "badge-neutral"
  end

  # "الإجراء التالي" — a pure presentation mapping from the request's current
  # status to what a user should do next, reusing the exact same policy
  # checks and routes as the full action set elsewhere on this page (see
  # PurchaseRequestPolicy). No business logic lives here: a nil/false policy
  # check just means the label renders without a link.
  def purchase_request_next_action(pr)
    label = t("inventory.purchase_requests.next_actions.#{pr.status}", default: nil)
    return nil unless label

    url, http_method =
      case pr.status
      when "draft"
        [ (edit_inventory_purchase_request_path(pr) if policy(pr).update?), :get ]
      when "pending_approval"
        [ (approve_inventory_purchase_request_path(pr) if policy(pr).approve?), :post ]
      when "approved", "partially_received"
        [ (new_inventory_goods_receipt_path(purchase_request_id: pr.id) if policy(pr).create_goods_receipt?), :get ]
      else
        [ nil, :get ]
      end

    { label: label, url: url, http_method: http_method }
  end

  # Marker colour + icon for one Activity Timeline entry (built by
  # Inventory::StockIssuesController#build_timeline_events). Reuses the exact
  # same icon set as goods receipts for the events they share.
  STOCK_ISSUE_TIMELINE_MARKER_CLASSES = {
    created: "activity-timeline__marker--neutral", submitted: "activity-timeline__marker--warning",
    approved: "activity-timeline__marker--success", rejected: "activity-timeline__marker--danger",
    issued: "activity-timeline__marker--success", issued_legacy: "activity-timeline__marker--success",
    cancelled: "activity-timeline__marker--neutral", voided: "activity-timeline__marker--danger"
  }.freeze

  def stock_issue_timeline_marker_class(type)
    STOCK_ISSUE_TIMELINE_MARKER_CLASSES.fetch(type, "activity-timeline__marker--neutral")
  end

  STOCK_ISSUE_TIMELINE_ICONS = {
    created:   "M12 9v6m3-3H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
    submitted: "M6 12 3.269 3.125A59.769 59.769 0 0 1 21.485 12 59.768 59.768 0 0 1 3.27 20.875L5.999 12Zm0 0h7.5",
    approved:  "M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
    rejected:  "m9.75 9.75 4.5 4.5m0-4.5-4.5 4.5M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
    issued:    "M20.25 7.5l-.625 10.632a2.25 2.25 0 0 1-2.247 2.118H6.622a2.25 2.25 0 0 1-2.247-2.118L3.75 7.5M10 11.25h4M3.375 7.5h17.25c.621 0 1.125-.504 1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125Z",
    cancelled: "M6 18 18 6M6 6l12 12",
    voided:    "M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166M18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.02-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0"
  }
  # issued_legacy reuses the exact same icon as issued (see #stock_issue_timeline_icon) —
  # only the label differs (see the timeline.issued_legacy locale key).
  STOCK_ISSUE_TIMELINE_ICONS[:issued_legacy] = STOCK_ISSUE_TIMELINE_ICONS[:issued]
  STOCK_ISSUE_TIMELINE_ICONS.freeze

  def stock_issue_timeline_icon(type)
    STOCK_ISSUE_TIMELINE_ICONS.fetch(type, STOCK_ISSUE_TIMELINE_ICONS[:created])
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
