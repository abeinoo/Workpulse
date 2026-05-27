namespace :attendance do
  # ── Historical backfill ─────────────────────────────────────────────────────
  #
  # Corrects attendance records that were imported via CsvImporter before the
  # canonical-pipeline fix (late_minutes / early_leave_minutes / status were
  # incorrectly zeroed/defaulted on import).
  #
  # Usage:
  #
  #   # Fix all businesses
  #   bundle exec rake attendance:backfill_import_penalties
  #
  #   # Fix one business
  #   bundle exec rake attendance:backfill_import_penalties BUSINESS_ID=42
  #
  #   # Fix one business within a date window
  #   bundle exec rake attendance:backfill_import_penalties BUSINESS_ID=42 FROM=2026-01-01 TO=2026-05-31
  #
  # The task runs as the first super-admin user found; supply ACTOR_ID to
  # override (used as the "generated_by" actor on any regenerated payroll periods).
  #
  desc "Recompute penalty fields on CSV-imported attendance records and regenerate affected draft payrolls"
  task backfill_import_penalties: :environment do
    business_id = ENV["BUSINESS_ID"].presence
    from_str    = ENV["FROM"].presence
    to_str      = ENV["TO"].presence
    actor_id    = ENV["ACTOR_ID"].presence

    business = business_id ? Business.find(business_id) : nil
    from     = from_str ? Date.parse(from_str) : nil
    to       = to_str   ? Date.parse(to_str)   : nil

    actor = if actor_id
      User.find(actor_id)
    else
      User.joins(:permission_role)
          .where(permission_roles: { role: "super_admin" })
          .first || User.order(:id).first
    end

    raise "No actor user found. Supply ACTOR_ID=<user_id>." unless actor

    scope_desc = [
      business ? "business=#{business.id}" : "all businesses",
      from      ? "from=#{from}"           : nil,
      to        ? "to=#{to}"               : nil
    ].compact.join(", ")

    puts "Starting HistoricalBackfill (#{scope_desc}) as user=#{actor.id} …"

    result = Attendance::HistoricalBackfill.call(
      business:     business,
      from:         from,
      to:           to,
      performed_by: actor
    )

    puts result.summary

    if result.errors.any?
      puts "\nErrors (#{result.errors.size}):"
      result.errors.each { |e| puts "  #{e.inspect}" }
      exit 1
    end
  end
end
