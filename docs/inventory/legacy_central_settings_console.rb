# Legacy product settings -> Central Warehouse settings (Rails console script).
#
#   products.low_stock_level  -> central ProductWarehouseSetting#low_stock_level  (exact, zeros kept)
#   products.reorder_quantity -> central ProductWarehouseSetting#reorder_quantity (exact, zeros kept)
#   products.receive_low_stock_notification -> the row's receive_low_stock_notification
#                                (kept as it is today, so alerts that are off stay off)
#   products.reorder_level    -> NEVER used
#
# This script adds no write logic of its own. Every rule comes from
# Inventory::LegacyCentralSettingsBackfill (the reviewed transfer service,
# spec/services/inventory/legacy_central_settings_backfill_spec.rb), which writes
# only through Inventory::ProductAvailabilityManager#add_many (authorization by
# ProductWarehouseSettingPolicy, warehouse row lock, model validations, one
# fail-closed audit entry per row with source "legacy_central_backfill"). The
# script only adds the console checks and the plain-language report.
#
# PREREQUISITE: PR #153 is deployed AND migration 20261119100000 is applied in
# this environment. The pre-flight check below stops the script otherwise.
#
# PREVIEW (default): set business_id, paste the whole file into `bin/rails console`.
#   Runs inside a READ ONLY database transaction: PostgreSQL rejects any write.
# APPLY: set apply: true, actor_id, and expect_central_id / expect_count copied
#   from THIS environment's preview, then paste again. All or nothing.
#
# ======================= CONFIG — the only part to edit =======================
legacy_transfer_config = {
  business_id: nil,       # REQUIRED, e.g. 2
  apply: false,           # PREVIEW unless exactly true
  actor_id: nil,          # APPLY: a user of this business allowed to manage product availability (e.g. the owner)
  expect_central_id: nil, # APPLY: "Central warehouse: #<id>" from this environment's preview (a check, not a target)
  expect_count: nil       # APPLY: "Would create: <n>" from this environment's preview
}
# ==============================================================================

legacy_transfer = lambda do |config|
  say = ->(line = "") { puts line }
  number = ->(value) { value.to_d.to_s("F") }

  # ── Pre-flight: the code and the schema this script relies on ──
  unless defined?(Inventory::LegacyCentralSettingsBackfill) && defined?(Inventory::ProductAvailabilityManager) &&
         ProductWarehouseSetting.column_names.include?("status") && Warehouse.column_names.include?("kind")
    say.("[STOPPED] This environment does not have PR #153 deployed and migrated " \
         "(LegacyCentralSettingsBackfill / ProductWarehouseSetting#status / Warehouse#kind missing). Nothing was done.")
    next :stopped
  end

  business = Business.find_by(id: config[:business_id])
  unless business
    say.("[STOPPED] business_id #{config[:business_id].inspect} not found. Nothing was done.")
    next :stopped
  end

  skip_reasons = {
    "matching" => "Central setting already Active with the same values — nothing to do",
    "differing" => "Central setting already Active with different values — kept, never overwritten",
    "inactive_conflict" => "Central setting is Inactive — never reactivated or overwritten",
    "archived" => "Product is archived",
    "untracked" => "Stock tracking is disabled",
    "legacy_alert_only" => "No legacy values to transfer (low stock level and reorder quantity are both 0)",
    "unresolved_central" => "Business has no single active Central Warehouse"
  }
  central_status = ->(row) { row.setting ? row.setting.status.capitalize : "Missing" }

  print_report = lambda do |report, title|
    say.(title)
    say.("Business: ##{business.id} #{business.name}")
    if report.central
      say.("Central warehouse: ##{report.central.id} #{report.central.name}")
    elsif report.ambiguous?
      say.("Central warehouse: AMBIGUOUS — several active central warehouses #{report.central_candidates.map(&:id)}")
    else
      say.("Central warehouse: NONE — no active central warehouse")
    end
    eligible = report.of("to_create")
    skipped  = report.rows - eligible
    say.("Eligible products: #{eligible.size}")
    eligible.each do |row|
      p = row.product
      say.(format("  product #%-6d %-40s legacy low=%s reorder=%s | central setting: %s -> create low=%s reorder=%s notify=%s",
                  p.id, p.name.to_s[0, 40], number.(p.low_stock_level), number.(p.reorder_quantity), central_status.(row),
                  number.(p.low_stock_level), number.(p.reorder_quantity), p.receive_low_stock_notification))
    end
    say.("Skipped products: #{skipped.size}")
    skipped.each do |row|
      p = row.product
      existing = row.setting ? " (row ##{row.setting.id} low=#{number.(row.setting.low_stock_level)} reorder=#{number.(row.setting.reorder_quantity)})" : ""
      say.(format("  product #%-6d %-40s legacy low=%s reorder=%s | central setting: %s%s | SKIPPED: %s",
                  p.id, p.name.to_s[0, 40], number.(p.low_stock_level), number.(p.reorder_quantity), central_status.(row),
                  existing, skip_reasons.fetch(row.category)))
    end
    eligible
  end

  connection = ActiveRecord::Base.connection

  unless config[:apply] == true
    # ── PREVIEW: read-only ──
    report = nil
    if connection.transaction_open?
      # e.g. `rails console --sandbox`: everything is rolled back on exit anyway.
      report = Inventory::LegacyCentralSettingsBackfill.new(business).dry_run
    else
      ActiveRecord::Base.transaction do
        connection.execute("SET TRANSACTION READ ONLY")
        report = Inventory::LegacyCentralSettingsBackfill.new(business).dry_run
        raise ActiveRecord::Rollback
      end
    end
    eligible = print_report.(report, "[PREVIEW — READ ONLY — nothing written]")
    say.("Would create: #{eligible.size} central setting(s)")
    if report.central && eligible.any?
      say.("To apply: apply: true, actor_id: <user id>, expect_central_id: #{report.central.id}, expect_count: #{eligible.size}")
    end
    next :preview
  end

  # ── APPLY ──
  missing = %i[actor_id expect_central_id expect_count].select { |key| config[key].blank? }
  if missing.any?
    say.("[APPLY REFUSED] missing #{missing.join(', ')} (copy them from this environment's preview). Nothing was written.")
    next :refused
  end
  if connection.transaction_open?
    say.("[APPLY REFUSED] a transaction is already open (sandbox console?): the result would be rolled back. Nothing was written.")
    next :refused
  end
  actor = business.users.find_by(id: config[:actor_id])
  unless actor
    say.("[APPLY REFUSED] actor_id #{config[:actor_id]} is not a user of business ##{business.id}. Nothing was written.")
    next :refused
  end

  # One transaction: lock the central warehouse, re-classify, refuse if the
  # preview numbers no longer hold, create every row through
  # ProductAvailabilityManager#add_many, verify every row — or roll back all.
  report = Inventory::LegacyCentralSettingsBackfill.new(business, actor: actor)
             .apply!(expected_central_id: Integer(config[:expect_central_id]), expected_count: Integer(config[:expect_count]))
  if report.error
    print_report.(report, "[APPLY REFUSED: #{report.error}] the whole operation was rolled back, nothing was written. Current state:")
    next :refused
  end

  created_ids = report.created.map(&:product_id).to_set
  say.("[APPLIED] created #{report.created.size} central setting(s) as user ##{actor.id}")
  report.created.each do |setting|
    say.(format("  created setting #%-6d product #%-6d %-40s status=%s low=%s reorder=%s notify=%s",
                setting.id, setting.product_id, setting.product.name.to_s[0, 40], setting.status,
                number.(setting.low_stock_level), number.(setting.reorder_quantity), setting.receive_low_stock_notification))
  end
  audits = AuditLog.where(auditable_type: "ProductWarehouseSetting", auditable_id: report.created.map(&:id), action: "availability_add").count
  say.("Audit entries written: #{audits} (source legacy_central_backfill)")
  not_created = report.rows.reject { |row| created_ids.include?(row.product.id) }
  say.("Skipped products: #{not_created.size}")
  not_created.each do |row|
    say.(format("  product #%-6d %-40s central setting: %s | SKIPPED: %s",
                row.product.id, row.product.name.to_s[0, 40], central_status.(row), skip_reasons.fetch(row.category)))
  end
  :applied
end

legacy_transfer.call(legacy_transfer_config)
