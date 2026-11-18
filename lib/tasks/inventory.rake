namespace :inventory do
  desc <<~DESC
    Normalize goods receipts that were cancelled/voided while their approval was
    still undecided (draft / pending_approval) — they show "awaiting approval"
    next to a "voided" receiving status. Moves approval_status → cancelled (the
    same transition Inventory::GoodsReceiptVoider now performs), one audit row
    each. Nothing else on the receipt changes.

    DRY RUN BY DEFAULT — lists the affected receipts and writes nothing.

    Options (all via ENV):
      APPLY=1          Actually write the changes.
      BUSINESS_ID=42   Restrict to one business.
      ACTOR_ID=7       Audit-log actor. Defaults to the user who voided each receipt.

    Usage:
      bin/rails inventory:normalize_cancelled_goods_receipt_approvals
      bin/rails inventory:normalize_cancelled_goods_receipt_approvals APPLY=1 ACTOR_ID=7
  DESC
  task normalize_cancelled_goods_receipt_approvals: :environment do
    apply  = ENV["APPLY"] == "1"
    actor  = ENV["ACTOR_ID"].presence && User.find(ENV["ACTOR_ID"])
    result = Inventory::GoodsReceiptCancelledApprovalNormalizer
               .new(apply: apply, business_id: ENV["BUSINESS_ID"].presence, actor: actor).call

    puts "[#{apply ? "APPLY" : "DRY RUN"}] #{result.candidates.size} voided goods receipt(s) with an undecided approval status:"
    result.candidates.each do |r|
      puts "  ##{r.id} #{r.receipt_number} business=#{r.business_id} approval=#{r.approval_status_before_type_cast} " \
           "status=#{r.status} voided_at=#{r.voided_at&.iso8601} reason=#{r.void_reason.inspect}"
    end
    puts "---"
    if apply
      puts "Updated: #{result.updated.size}"
      result.failed.each { |r, msg| puts "  FAILED ##{r.id} #{r.receipt_number}: #{msg}" }
    else
      puts "Nothing written. Re-run with APPLY=1 to apply."
    end
  end

  desc <<~DESC
    Report (product, warehouse) pairs whose approved-but-not-yet-issued stock
    issues reserve more than is physically on hand — the issues that can't be
    confirmed until stock is received or one of them is cancelled (see
    Inventory::StockAvailability). Also lists issues pending approval that
    couldn't be approved right now.

    READ-ONLY — never writes anything.

    Options (via ENV):
      BUSINESS_ID=42   Restrict to one business.

    Usage:
      bin/rails inventory:reservation_audit
  DESC
  task reservation_audit: :environment do
    scope = StockIssue.active.where(status: %w[approved pending_approval]).includes(:warehouse, items: :product)
    scope = scope.where(business_id: ENV["BUSINESS_ID"]) if ENV["BUSINESS_ID"].present?
    issues = scope.order(:id).to_a
    fmt = ->(q) { Inventory::StockAvailability.format_quantity(q) }

    over = issues.select(&:approved?).group_by(&:warehouse_id).flat_map do |warehouse_id, approved|
      product_ids = approved.flat_map { |i| i.items.map(&:product_id) }.uniq
      on_hand  = Inventory::StockAvailability.on_hand_by(warehouse_ids: warehouse_id, product_ids: product_ids)
      reserved = Inventory::StockAvailability.reserved_by(warehouse_ids: warehouse_id, product_ids: product_ids)
      product_ids.filter_map do |product_id|
        key = [ warehouse_id, product_id ]
        next if reserved[key].to_d <= on_hand[key].to_d

        holders = approved.select { |i| i.items.any? { |item| item.product_id == product_id } }
        product = holders.first.items.find { |item| item.product_id == product_id }.product
        "  business=#{holders.first.business_id} warehouse=#{holders.first.warehouse.name} product=#{product.sku} #{product.name} " \
          "on_hand=#{fmt.(on_hand[key].to_d)} reserved=#{fmt.(reserved[key].to_d)} issues=#{holders.map(&:issue_number).join(",")}"
      end
    end
    puts "#{issues.count(&:approved?)} approved-unissued issue(s); #{over.size} over-committed product/warehouse pair(s):"
    puts over

    blocked = Inventory::StockAvailability.unfulfillable_issue_ids(issues.select(&:pending_approval?))
    puts "#{issues.count(&:pending_approval?)} issue(s) pending approval; #{blocked.size} can't be approved right now:"
    issues.select { |i| blocked.include?(i.id) }.each { |i| puts "  #{i.issue_number} business=#{i.business_id}" }
  end

  desc <<~DESC
    Warehouse Architecture PR 4 — give EXISTING sales branches their branch
    warehouse ("<Branch Name> – المخزن", kind branch, empty) through the
    existing provisioning path (Inventory::BranchWarehouseBackfill).

    DRY RUN by default: prints the classification of every branch of the
    actor's own business (no other business is planned or shown) and writes
    nothing. Writes only with EXECUTE=1 exactly, and only for the listed
    BRANCH_IDS, one transaction per branch; every branch ends CREATED,
    ALREADY_PROVISIONED or FAILED (exit status 1 if any failed).

      ACTOR_ID               the active user the audit entries name (must manage branches)
      APPROVED_BUSINESS_IDS  comma-separated; the actor's business, if not listed, is REQUIRES_MANUAL_REVIEW
      BRANCH_IDS             comma-separated (required with EXECUTE=1)
      EXECUTE=1              actually provision (any other value is a dry run)

      bin/rails inventory:branch_warehouse_backfill ACTOR_ID=12 APPROVED_BUSINESS_IDS=2
      bin/rails inventory:branch_warehouse_backfill ACTOR_ID=12 APPROVED_BUSINESS_IDS=2 BRANCH_IDS=3,4,5 EXECUTE=1

    Never touches existing warehouses (an unclassified one stays unclassified),
    stock, movements or documents.
  DESC
  task branch_warehouse_backfill: :environment do
    ids = ->(value) { value.to_s.split(",").map(&:strip).reject(&:empty?).map { |id| Integer(id) } }

    actor    = User.find(Integer(ENV.fetch("ACTOR_ID")))
    approved = ids.(ENV.fetch("APPROVED_BUSINESS_IDS"))
    abort "APPROVED_BUSINESS_IDS is empty" if approved.empty?

    backfill = Inventory::BranchWarehouseBackfill.new(actor: actor, approved_business_ids: approved)
    begin
      plan = backfill.plan
    rescue Inventory::BranchWarehouseBackfill::Refused => e
      abort e.message
    end
    puts "Branch warehouse backfill — plan (actor ##{actor.id}, business ##{actor.business_id}; approved businesses #{approved.join(',')})"
    (approved - [ actor.business_id ]).each do |other|
      puts "  business ##{other}: outside the actor's business — not planned or shown"
    end
    plan.each do |c|
      puts format("  %-22s business=%d branch=%d %-8s active=%-5s existing=%-6s proposed=%s  — %s",
                  c.status, c.business_id, c.branch_id, c.branch_type, c.active, c.existing_warehouse_id || "-",
                  c.proposed_name || "-", c.reason)
    end

    unless ENV["EXECUTE"] == "1"
      puts "DRY RUN — nothing was written. Re-run with BRANCH_IDS=… EXECUTE=1 to provision."
      next
    end

    branch_ids = ids.(ENV.fetch("BRANCH_IDS"))
    abort "BRANCH_IDS is empty" if branch_ids.empty?
    abort "the actor's business ##{actor.business_id} is not in APPROVED_BUSINESS_IDS" unless approved.include?(actor.business_id)

    outcomes = backfill.execute(branch_ids: branch_ids)
    puts "Branch warehouse backfill — results"
    outcomes.each do |o|
      puts format("  %-20s branch=%d warehouse=%-6s %s", o.status, o.branch_id, o.warehouse_id || "-", o.reason)
    end
    abort "#{outcomes.count(&:failed?)} branch(es) FAILED — see above" if outcomes.any?(&:failed?)
  end
end
