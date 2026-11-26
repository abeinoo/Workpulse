module InventoryHelper
  STOCK_TRANSFER_BADGE_CLASSES = {
    "draft" => "badge-neutral", "pending_approval" => "badge-warning", "approved" => "badge-success",
    "posted_direct" => "badge-success", "awaiting_dispatch" => "badge-accent", "in_transit" => "badge-warning",
    "partially_received" => "badge-warning", "discrepancy" => "badge-danger", "received" => "badge-success",
    "rejected" => "badge-danger", "cancelled" => "badge-neutral"
  }.freeze

  # The Stock Transfers index status navigation: every filter of
  # Inventory::StockTransferHistory::STATUS_FILTERS, in lifecycle order, split
  # into still-moving and finished. Presentation only — the statuses, their
  # transitions and the filtering stay in StockTransfer / StockTransferHistory.
  STOCK_TRANSFER_STATUS_GROUPS = {
    "open"   => %w[draft pending_approval awaiting_dispatch in_transit partially_received discrepancy],
    "closed" => %w[received approved rejected cancelled]
  }.freeze

  # A transfer's warehouse for the index route: its name, with the owning
  # branch (if any) as the secondary line.
  def transfer_route_end(warehouse, role)
    branch = warehouse.owning_branch
    tag.span(class: "stt-route__end stt-route__end--#{role}") do
      safe_join([ tag.span(warehouse.display_name, class: "stt-route__name", dir: "auto", title: transfer_warehouse_label(warehouse)),
                  (tag.span(branch.name, class: "stt-route__branch", dir: "auto") if branch) ].compact)
    end
  end

  # A warehouse as offered on the transfer form: its name with the owning
  # branch's ("North Store — North Branch"); central / unclassified by name only.
  def transfer_warehouse_label(warehouse)
    branch = warehouse.owning_branch
    branch ? "#{warehouse.display_name} — #{branch.name}" : warehouse.display_name
  end

  def transfer_warehouse_options(warehouses, selected_id)
    options_for_select(warehouses.map { |w| [ transfer_warehouse_label(w), w.id ] }, selected_id)
  end

  # A transfer's workflow status — a voided (reversed) posted transfer shows as voided.
  def stock_transfer_status_badge(transfer)
    if transfer.voided?
      return tag.span(t("inventory.void.status_voided"), class: "badge badge-danger")
    end

    key = transfer.status
    key = "partially_received" if transfer.in_transit? && transfer.receipts.any?
    key = "posted_direct" if transfer.approved? && transfer.direct?
    tag.span(t("inventory.stock_transfers.statuses.#{key}"),
             class: "badge #{STOCK_TRANSFER_BADGE_CLASSES.fetch(key, 'badge-neutral')}",
             data: { transfer_status: key })
  end

  # Badge colour for a stock-count session status.
  STOCK_COUNT_STATUS_BADGES = {
    "draft" => "badge-neutral", "in_progress" => "badge-warning",
    "completed" => "badge-accent", "approved" => "badge-success", "cancelled" => "badge-danger"
  }.freeze

  # Badge colour for a warehouse type (kind; NULL = unclassified).
  WAREHOUSE_KIND_BADGES = {
    "central" => "badge-accent", "branch" => "badge-neutral", "unclassified" => "badge-warning",
    "transit" => "badge-neutral"
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

    # A stock count's adjustment (or its reversal) is referenced by the count:
    # SC-xxxx links to the count, with the ADJ number alongside.
    if (count = Inventory::Reports::Movements.stock_count_for(source))
      return safe_join([
        link_to(count.count_number, inventory_stock_count_path(count), class: "link"),
        content_tag(:span, " · ", class: "td-secondary"),
        link_to(source.adjustment_number, inventory_stock_adjustment_path(source), class: "link td-secondary")
      ])
    end

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

  def inventory_movement_badge(reason, source: nil)
    kind, css = MOVEMENT_KINDS.fetch(reason.to_s, [ :adjustment, "badge-neutral" ])
    if Inventory::Reports::Movements.stock_count_for(source)
      kind, css = reason.to_s == "reversal" ? [ :stock_count_reversal, "badge-danger" ] : [ :stock_count, "badge-accent" ]
    end
    content_tag(:span, t("inventory.dashboard.overview.kinds.#{kind}"), class: "badge #{css}")
  end

  # Movement type text: a stock count's adjustment and its reversal are named
  # as such, never as an anonymous manual adjustment.
  def inventory_movement_reason_label(reason, source: nil)
    if Inventory::Reports::Movements.stock_count_for(source)
      t("inventory.movements.stock_count_reasons.#{reason}", default: t("inventory.movements.reasons.#{reason}"))
    else
      t("inventory.movements.reasons.#{reason}")
    end
  end

  # Badge colour for a product's availability in one warehouse.
  AVAILABILITY_STATE_BADGES = {
    "active" => "badge-success", "inactive" => "badge-neutral", "not_configured" => "badge-warning",
    "included" => "badge-success", "excluded" => "badge-neutral"
  }.freeze

  # Active / Inactive / Not Configured, for a ProductWarehouseSetting status
  # (or "not_configured" when there is no row).
  def availability_state_badge(state)
    tag.span(t("product_availability.states.#{state}"), class: "badge #{AVAILABILITY_STATE_BADGES.fetch(state.to_s)}",
                                                        style: "white-space: nowrap;", data: { availability_state: state })
  end

  # A stock quantity or threshold without trailing zeros (2, 2.5, 0.125).
  def availability_quantity(value)
    number_with_precision(value.to_d, precision: 3, strip_insignificant_zeros: true)
  end

  # The warehouse type, from its stored kind only (never inferred from the name).
  def warehouse_kind_badge(warehouse)
    key = warehouse.kind.presence || "unclassified"
    tag.span(t("inventory.warehouses.kinds.#{key}"), class: "badge #{WAREHOUSE_KIND_BADGES.fetch(key)}")
  end

  # The owning branch's name ("—" for central / unclassified), marked when inactive.
  def warehouse_branch_label(warehouse)
    branch = warehouse.owning_branch
    return "—" unless branch
    return branch.name if branch.active?

    "#{branch.name} #{t('inventory.warehouses.branch_inactive')}"
  end

  # Inventory quantities exactly as stored (4.004 stays 4.004; 7.000 shows 7).
  def inventory_quantity(value) = Inventory::QuantityFormat.plain(value)

  # ── Measure (Product#unit_of_measure) — informational only ──────────────
  # It describes the contents of one inventory unit; it is never shown as the
  # unit of an inventory quantity (those are plain numbers of units).
  # "Millilitres (ml)" — the dropdown label.
  def measure_name(code) = t("inventory.measures.#{code.presence || Product::DEFAULT_UNIT_OF_MEASURE}.name")
  # "ml" / "مل" — beside the product's Amount.
  def measure_short(product_or_code)
    code = product_or_code.respond_to?(:unit_of_measure) ? product_or_code.unit_of_measure : product_or_code
    t("inventory.measures.#{code.presence || Product::DEFAULT_UNIT_OF_MEASURE}.short")
  end

  # The short label rides along for the form's Amount suffix (product_measure_controller.js).
  def measure_options = Product::UNITS_OF_MEASURE.map { |code| [ measure_name(code), code, { "data-short" => measure_short(code) } ] }

  # The contents of one unit: Amount + Measure ("355 ml", "0.5 kg"), or nil
  # without an amount.
  def product_measurement(product)
    return nil if product&.measure_amount.blank?

    "#{inventory_quantity(product.measure_amount)} #{measure_short(product)}"
  end

  def inventory_signed_quantity(value) = Inventory::QuantityFormat.signed(value)

  # Unit cost for display (Decisions 11, 18): up to 8 dp, trailing zeros and
  # point removed, never scientific — 25.00000000 → "25", 0.70400000 → "0.704".
  def format_unit_cost(value)
    CostFormat.unit(value)
  end

  def stock_count_status_class(status)
    STOCK_COUNT_STATUS_BADGES.fetch(status.to_s, "badge-neutral")
  end

  # Badge colour for a goods receipt's approval_status (purchasing decision —
  # independent of whether the goods have physically arrived).
  GOODS_RECEIPT_APPROVAL_STATUS_BADGES = {
    "draft" => "badge-neutral", "pending_approval" => "badge-warning",
    "approved" => "badge-accent", "rejected" => "badge-danger", "cancelled" => "badge-danger"
  }.freeze

  def goods_receipt_approval_status_class(approval_status)
    GOODS_RECEIPT_APPROVAL_STATUS_BADGES.fetch(approval_status.to_s, "badge-neutral")
  end

  # Receipt (inventory) status for a goods receipt — derived in the model
  # (GoodsReceipt#receiving_status), mirrored by its for_receiving_status scope.
  def goods_receipt_receipt_status(receipt)
    receipt.receiving_status
  end

  GOODS_RECEIPT_RECEIPT_STATUS_BADGES = {
    "not_received" => "badge-neutral", "received" => "badge-success", "voided" => "badge-danger",
    "not_receivable" => "badge-danger"
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
    reopened: "activity-timeline__marker--neutral",
    approved: "activity-timeline__marker--success", rejected: "activity-timeline__marker--danger",
    quick_issue_approved: "activity-timeline__marker--warning",
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

  # Small decorative icons for document action buttons (heroicons-outline
  # paths). The button's visible text is its accessible name.
  ACTION_ICONS = {
    approve: "m4.5 12.75 6 6 9-13.5",
    reject:  "M6 18 18 6M6 6l12 12",
    view:    "M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178ZM15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
    receive: GOODS_RECEIPT_TIMELINE_ICONS[:received],
    submit:  GOODS_RECEIPT_TIMELINE_ICONS[:submitted],
    cancel:  GOODS_RECEIPT_TIMELINE_ICONS[:voided],
    edit:    "m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Z",
    back:    "M15.75 19.5 8.25 12l7.5-7.5"
  }.freeze

  def action_icon(name)
    tag.svg(tag.path(d: ACTION_ICONS.fetch(name)),
            class: "action-icon", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
            "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true")
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

  # Stock quantity with insignificant zeros dropped ("2", "2.5") — the same
  # format the insufficient-stock messages use.
  def stock_quantity(quantity)
    Inventory::StockAvailability.format_quantity(quantity)
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

  # A Purchase Request's supplier: the legacy request-level one, else its
  # lines' — the name when they share one, "عدة موردين" when they differ, and
  # "بدون مورد" when none is set. Preload items: :supplier for lists.
  def purchase_request_supplier_name(pr)
    suppliers = pr.suppliers_on_items
    return t("inventory.purchase_requests.no_supplier") if suppliers.empty?
    return suppliers.first.name if suppliers.one?

    t("inventory.purchase_requests.multiple_suppliers")
  end

  # The approval decision alone, for the "الحالة" badge: the status column also
  # carries receiving progress (partially/fully received, partially closed),
  # which the list shows separately under "الاستلام" — so those read "معتمد"
  # here instead of repeating the receiving label. Display only.
  def purchase_request_approval_status(pr)
    purchase_request_receiving_status(pr) ? "approved" : pr.status
  end

  # Received share of the requested quantity, 0–100, for the progress bar.
  def purchase_request_received_percent(requested, received)
    return 0 unless requested.to_d.positive?

    [ (received.to_d / requested.to_d * 100).round, 100 ].min
  end

  # Marker colour + icon for one Activity Timeline entry (built by
  # Inventory::StockIssuesController#build_timeline_events). Reuses the exact
  # same icon set as goods receipts for the events they share.
  STOCK_TRANSFER_TIMELINE_MARKER_CLASSES = {
    submitted: "warning", edited: "warning", draft_edited: "neutral", approved: "success", approved_posted: "success",
    rejected: "danger", cancelled: "neutral", dispatched: "warning", received_partially: "warning",
    received_in_full: "success", received_with_shortfall: "danger", resolved: "warning", voided: "danger",
    posted: "success", legacy_posted: "success"
  }.freeze

  def stock_transfer_timeline_marker_class(type)
    "activity-timeline__marker--#{STOCK_TRANSFER_TIMELINE_MARKER_CLASSES.fetch(type, 'neutral')}"
  end

  STOCK_ISSUE_TIMELINE_MARKER_CLASSES = {
    created: "activity-timeline__marker--neutral", submitted: "activity-timeline__marker--warning",
    reopened: "activity-timeline__marker--neutral",
    approval_revoked: "activity-timeline__marker--warning",
    approved: "activity-timeline__marker--success", rejected: "activity-timeline__marker--danger",
    issued: "activity-timeline__marker--success", issued_legacy: "activity-timeline__marker--success",
    cancelled: "activity-timeline__marker--neutral", voided: "activity-timeline__marker--danger"
  }.freeze

  def stock_issue_timeline_marker_class(type)
    STOCK_ISSUE_TIMELINE_MARKER_CLASSES.fetch(type, "activity-timeline__marker--neutral")
  end

  # A Quick Issue's fixed reason (and the description of "other"), for the
  # issue page, its timeline and the reports. nil when no reason was recorded.
  def stock_issue_reason_text(issue)
    return nil if issue.issue_reason.blank?

    label = t("inventory.stock_issues.reasons.#{issue.issue_reason}")
    issue.issue_reason_note.present? ? "#{label} — #{issue.issue_reason_note}" : label
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
  # A quick-issue self-approval keeps the approval tick; the warning marker
  # and its own label set it apart from an independent approval.
  STOCK_ISSUE_TIMELINE_ICONS[:quick_issue_approved] = STOCK_ISSUE_TIMELINE_ICONS[:approved]
  # Pencil — returned to draft for editing.
  STOCK_ISSUE_TIMELINE_ICONS[:approval_revoked] = STOCK_ISSUE_TIMELINE_ICONS[:rejected]
  STOCK_ISSUE_TIMELINE_ICONS[:reopened] = "m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125"
  STOCK_ISSUE_TIMELINE_ICONS.freeze

  # Edit-form warning for an issue that saving will return to draft: an
  # approved issue also loses its approval and stock reservation.
  def stock_issue_edit_warning_key(stock_issue)
    stock_issue.approved? ? "inventory.stock_issues.edit_approved_warning" : "inventory.stock_issues.edit_request_warning"
  end

  def stock_issue_timeline_icon(type)
    STOCK_ISSUE_TIMELINE_ICONS.fetch(type, STOCK_ISSUE_TIMELINE_ICONS[:created])
  end

  # Product <option>s for document line-item selects. Embeds barcode/SKU as data
  # attributes so the barcode-scanner Stimulus controller can resolve a scan
  # client-side without a server round-trip; default supplier is carried for the
  # goods-receipt supplier prefill. Shared by every document form so scanning
  # behaves identically everywhere.
  # The same <option>s as #inventory_product_options, rendered ONCE for a form
  # with many line-item rows (every row lists the whole catalog): barcodes come
  # from a bulk Product.barcode_lookup (same primary/first rule as
  # Product#barcode) instead of one or two queries per product per row. Each
  # row then takes this HTML through #inventory_product_select_options.
  def inventory_product_options_html(products, barcodes:)
    options_for_select(
      products.map { |p|
        barcode = barcodes[p.id]
        # Every barcode of the product when they were loaded (scanning any of
        # them matches this line), else the one from the bulk lookup.
        all = p.association(:product_barcodes).loaded? ? p.product_barcodes.map(&:barcode) : [ barcode ].compact
        [ "#{p.name} (#{p.sku})", p.id, {
          "data-barcode"             => barcode,
          "data-barcodes"            => all.join("|"),
          "data-sku"                 => p.sku,
          "data-default-supplier-id" => p.default_supplier_id
        } ]
      }
    )
  end

  # Marks one row's selected product in the pre-rendered option list — the
  # exact markup options_for_select(rows, selected_id) produces. Safe as a
  # string edit: `value` is always an option's last attribute, and every quote
  # inside labels/attribute values is escaped, so ` value="ID">` can only be
  # that option's own value attribute.
  def inventory_product_select_options(options_html, selected_id)
    return options_html if selected_id.blank?

    value = %( value="#{ERB::Util.html_escape(selected_id)}">)
    options_html.sub(value) { %( selected="selected"#{value}) }.html_safe
  end

  # Reference implementation only — retained so specs can prove the batched
  # path (#inventory_product_options_html + #inventory_product_select_options)
  # renders identical markup. Do not use it in application views/controllers:
  # it runs one or two barcode queries per product, per call.
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
