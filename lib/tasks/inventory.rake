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

  desc <<~DESC
    Warehouse Architecture PR 5 — READ-ONLY impact report for the fail-closed
    switch: per user, today's effective warehouse access (old) vs what the
    new warehouse access resolver would give once activated (new). IDs only.
    Runs inside a READ ONLY database transaction; writes nothing, activates nothing.

      BUSINESS_IDS        optional, comma-separated (default: every business)
      HIGHLIGHT_USER_IDS  optional, comma-separated users to list separately

      bin/rails inventory:warehouse_access_report BUSINESS_IDS=2 HIGHLIGHT_USER_IDS=17
  DESC
  task warehouse_access_report: :environment do
    ids = ->(value) { value.to_s.split(",").map(&:strip).reject(&:empty?).map { |id| Integer(id) } }
    business_ids = ids.(ENV["BUSINESS_IDS"]).presence
    highlight    = ids.(ENV["HIGHLIGHT_USER_IDS"])
    list = ->(values) { "[#{values.join(',')}]" }
    line = lambda do |r|
      format("  user=%-4d active=%-5s role=%s perms=%s old=%s new=%s lost=%s gained=%s flags=%s",
             r.user_id, r.active, r.role_id ? "#{r.role_id}(#{r.role_type || '-'})" : "-",
             r.inventory_permissions.join(",").presence || "-", list.(r.old_ids), list.(r.new_ids),
             list.(r.lost), list.(r.gained), r.flags.join(","))
    end

    sections = nil
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      sections = Inventory::WarehouseAccessReport.new(business_ids: business_ids).sections
      raise ActiveRecord::Rollback # nothing to keep — and nothing could have been written
    end

    puts "Warehouse access impact report — READ ONLY (old = the live rule of each business, new = Inventory::WarehouseAccess)"
    rows = sections.flat_map(&:rows)
    sections.each do |section|
      puts "Business ##{section.business_id} (mode: #{section.mode}) — warehouses #{list.(section.warehouse_ids)}"
      section.rows.each { |row| puts line.(row) }
      next if section.quiet_user_ids.empty?

      old_access = section.mode == "legacy" ? "every warehouse (fail-open)" : "none (fail-closed)"
      puts "  #{section.quiet_user_ids.size} other user(s) with no inventory permission, assignment or branch " \
           "warehouse: old = #{old_access}, new = none — no inventory page either way."
    end

    if highlight.any?
      puts "Highlighted users"
      highlight.each do |user_id|
        row = rows.find { |r| r.user_id == user_id }
        puts(row ? line.(row) : "  user=#{user_id}: not among the reported users")
      end
    end

    # Every count is printed with the user IDs behind it, so it reconciles
    # line by line with the detail above. Counts cover the listed users only;
    # the summarised users are stated separately.
    tally = ->(label, selected) { "  #{label}=#{selected.size} #{list.(selected.map(&:user_id))}" }
    flagged = ->(*flags) { rows.select { |r| flags.all? { |flag| r.flags.include?(flag) } } }
    losing = flagged.("LOSES")
    quiet = sections.sum { |section| section.quiet_user_ids.size }
    puts "Summary (#{rows.size} listed user(s); the counts below cover these only)"
    puts tally.("lose", losing)
    puts tally.("lose_with_inventory_permission", losing.reject { |r| r.flags.include?("NO_INVENTORY_PERMISSION") })
    puts tally.("lose_without_inventory_permission", flagged.("LOSES", "NO_INVENTORY_PERMISSION"))
    puts tally.("gain", flagged.("GAINS"))
    puts tally.("zero_after", flagged.("ZERO_AFTER"))
    puts tally.("fail_open", flagged.("FAIL_OPEN"))
    puts tally.("accountants_losing", flagged.("ACCOUNTANT", "LOSES"))
    puts "  not listed: #{quiet} user(s) with no inventory permission, assignment or branch warehouse " \
         "(old = every warehouse by fail-open in a legacy business, none in a fail-closed one; new = none; " \
         "no inventory page either way)"
  end
end
