namespace :pos do
  desc <<~DESC
    Recompute and overwrite employee_reconciliation_summaries for every closed
    DailyReconciliation that already has a snapshot.

    Runs persist! through EmployeeReconciliationSummarizer, which uses the same
    aggregate_by_employee algorithm as the live display, so the snapshot table,
    exports, and UI all derive from one formula.

    Only processes DRs that already have at least one summary row — open or
    not-yet-snapshotted DRs are left untouched.

    Safe to re-run. Progress is printed to stdout.

    Usage:
      bin/rails pos:recompute_employee_summaries
      bin/rails pos:recompute_employee_summaries BUSINESS_ID=42   # one business only
  DESC
  task recompute_employee_summaries: :environment do
    business_scope = ENV["BUSINESS_ID"].present? ?
      Business.where(id: ENV["BUSINESS_ID"]) :
      Business.all

    total     = 0
    succeeded = 0
    failed    = 0

    business_scope.find_each do |business|
      dr_ids = EmployeeReconciliationSummary
                 .joins(:daily_reconciliation)
                 .where(daily_reconciliations: { business_id: business.id })
                 .distinct
                 .pluck(:daily_reconciliation_id)

      next if dr_ids.empty?

      puts "Business ##{business.id} (#{business.name}): #{dr_ids.size} DR(s) to recompute"

      DailyReconciliation
        .where(id: dr_ids)
        .includes(
          :till_handovers,
          opening_float_source_handover: { amounts: :payment_method, from_user: [] },
          till_handovers: { from_user: [], to_user: [], amounts: :payment_method }
        )
        .find_each do |dr|
          total += 1
          Finance::EmployeeReconciliationSummarizer.new(dr).persist!
          succeeded += 1
          print "."
        rescue => e
          failed += 1
          puts "\n  DR ##{dr.id} failed: #{e.message}"
        end

      puts "" # newline after dots
    end

    puts "\nDone. #{succeeded} recomputed, #{failed} failed, #{total} total."
  end
end
