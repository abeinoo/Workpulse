require "digest"

module Payroll
  # "إعادة احتساب الوقت الإضافي" — recalculates OVERTIME ONLY for one payroll
  # period that is under review, using the business's CURRENT overtime
  # threshold (Business#overtime_grace_minutes), e.g. after it changed 30 → 60.
  #
  # Why not EntryRecalculator / Regenerator: both rebuild the whole entry from
  # today's data (every line item, deductions, advances, obligations, entry
  # status/notes). This touches nothing but overtime:
  #
  #   - overtime line items (item_type "overtime", one per attendance day):
  #       kept and re-priced in place when the day still qualifies (id, review
  #       fields and any addition-cancellation decision are preserved);
  #       removed when the day no longer qualifies; added when a day newly does.
  #   - the entry's overtime columns: calculated_overtime_minutes,
  #       calculated_overtime_pay, total_overtime, and (for a management override)
  #       approved_overtime_minutes / approved_overtime_pay /
  #       overtime_override_stale — clamped exactly like EntryRecalculator does.
  #   - net_salary moves by EXACTLY the change in payable overtime; every other
  #       column (base, deductions, bonuses, advances, obligations, insurance,
  #       status, notes) is left byte-for-byte as it was.
  #
  # Each day is priced by Payroll::EntryCalculator's own shared inputs
  # (.attendance_records_for / .rate_calculator_for / .overtime_for →
  # Salary::OvertimeCalculator) — no overtime logic lives here. Attendance is
  # only read.
  #
  # #preview never writes. #apply! re-derives the plan under a period row lock,
  # refuses if it no longer matches the confirmed preview (digest), then writes
  # everything plus one PayrollAuditLog row in a single transaction. Idempotent:
  # once applied, a second run finds nothing to change and writes nothing.
  class OvertimeRecalculator
    ALLOWED_STATUSES = %w[under_review].freeze

    Row = Struct.new(:entry, :old_minutes, :new_minutes, :old_calculated_pay, :new_calculated_pay,
                     :old_payable, :new_payable, :line_updates, :line_removals, :line_additions,
                     :override_attrs, keyword_init: true) do
      def changed?
        line_updates.any? || line_removals.any? || line_additions.any? ||
          old_minutes != new_minutes || (old_calculated_pay - new_calculated_pay).abs >= 0.005 ||
          (old_payable - new_payable).abs >= 0.005
      end
    end

    Preview = Struct.new(:period, :threshold, :previous_threshold, :rows, :digest, keyword_init: true) do
      def affected_rows       = rows.select(&:changed?)
      def affected_count      = affected_rows.size
      def old_total_minutes   = rows.sum(&:old_minutes)
      def new_total_minutes   = rows.sum(&:new_minutes)
      def old_total_amount    = rows.sum(&:old_payable).round(2)
      def new_total_amount    = rows.sum(&:new_payable).round(2)
      def nothing_to_change?  = affected_count.zero?
    end

    Result = Struct.new(:ok, :preview, :error, keyword_init: true) { def ok? = ok }

    def initialize(period_id:, actor:)
      @period_id = period_id
      @actor     = actor
    end

    # Read-only. Raises nothing for a locked period — the caller shows the error.
    def preview
      return Result.new(ok: false, error: status_error) unless allowed_status?(period)

      Result.new(ok: true, preview: build_preview)
    end

    def apply!(expected_digest:)
      result = nil
      ActiveRecord::Base.transaction do
        period.lock!
        unless allowed_status?(period)
          result = Result.new(ok: false, error: status_error)
          raise ActiveRecord::Rollback
        end

        plan = build_preview
        if plan.digest != expected_digest.to_s
          result = Result.new(ok: false, preview: plan, error: I18n.t("payroll.overtime_recalculation.errors.preview_changed"))
          raise ActiveRecord::Rollback
        end

        plan.affected_rows.each { |row| apply_row!(row) }
        write_audit!(plan)
        result = Result.new(ok: true, preview: plan)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def period
      @period ||= PayrollPeriod.where(business_id: @actor.business_id).find(@period_id)
    end

    def business = period.business

    def allowed_status?(record)
      !record.locked? && ALLOWED_STATUSES.include?(record.status)
    end

    def status_error
      I18n.t("payroll.overtime_recalculation.errors.not_under_review")
    end

    def build_preview
      entries = period.payroll_entries.includes(:user, :payroll_line_items).order(:id).to_a
      rows = entries.map { |entry| plan_for(entry) }
      Preview.new(period: period, threshold: business.overtime_grace_minutes.to_i,
                  previous_threshold: previous_threshold, rows: rows, digest: digest_for(rows))
    end

    # The desired overtime lines for one entry vs. what it has now.
    def plan_for(entry)
      rate_calc  = Payroll::EntryCalculator.rate_calculator_for(user: entry.user, business: business, period: period)
      daily_rate = rate_calc&.profile ? rate_calc.daily_rate : 0
      multiplier = rate_calc&.profile&.overtime_multiplier

      # No salary profile resolvable now → nothing can be priced; leave the
      # entry exactly as it is rather than stripping its overtime.
      return unchanged_row(entry) unless rate_calc&.profile

      desired = {}
      Payroll::EntryCalculator.attendance_records_for(user: entry.user, period: period).each do |record|
        next unless record.complete?

        result = Payroll::EntryCalculator.overtime_for(record: record, daily_rate: daily_rate,
                                                       multiplier: multiplier, business: business)
        desired[record.id] = [ record, result ] if result.overtime_pay.positive?
      end

      ot_lines   = entry.payroll_line_items.select(&:overtime?)
      day_lines  = ot_lines.select { |li| li.source_type == "AttendanceRecord" }
      other_ot   = ot_lines - day_lines # never produced by attendance; left untouched

      updates = []
      removals = []
      day_lines.each do |line|
        want = desired[line.source_id]
        if want.nil?
          removals << line
        elsif (line.amount.to_f - want.last.overtime_pay).abs >= 0.005
          updates << [ line, want.last.overtime_pay.round(2) ]
        end
      end
      kept_ids  = day_lines.map(&:source_id)
      additions = desired.reject { |record_id, _| kept_ids.include?(record_id) }.values

      # New calculated pay follows PayrollEntry#recalculate_totals!: approved,
      # non-cancelled overtime lines only.
      surviving = (day_lines - removals).map do |line|
        upd = updates.find { |l, _| l.equal?(line) }
        [ line, upd ? upd.last : line.amount.to_f ]
      end
      new_calc_pay = (surviving.select { |l, _| l.approved? && !l.addition_cancelled? }.sum(&:last) +
                      additions.sum { |_, r| r.overtime_pay } +
                      other_ot.select { |l| l.approved? && !l.addition_cancelled? }.sum { |l| l.amount.to_f }).round(2)
      new_minutes  = desired.values.sum { |_, r| r.overtime_minutes.to_i }

      override_attrs, new_payable = reconcile_override(entry, new_minutes, new_calc_pay)

      Row.new(entry: entry,
              old_minutes: entry.calculated_overtime_minutes.to_i, new_minutes: new_minutes,
              old_calculated_pay: entry.calculated_overtime_pay.to_f.round(2), new_calculated_pay: new_calc_pay,
              old_payable: entry.total_overtime.to_f.round(2), new_payable: new_payable,
              line_updates: updates, line_removals: removals,
              line_additions: additions, override_attrs: override_attrs)
    end

    def unchanged_row(entry)
      Row.new(entry: entry,
              old_minutes: entry.calculated_overtime_minutes.to_i, new_minutes: entry.calculated_overtime_minutes.to_i,
              old_calculated_pay: entry.calculated_overtime_pay.to_f.round(2),
              new_calculated_pay: entry.calculated_overtime_pay.to_f.round(2),
              old_payable: entry.total_overtime.to_f.round(2), new_payable: entry.total_overtime.to_f.round(2),
              line_updates: [], line_removals: [], line_additions: [], override_attrs: {})
    end

    # Same clamp rules as Payroll::EntryRecalculator#reapply_overtime_override:
    # an override can never pay more than is now calculated. The decision itself
    # is kept (and flagged stale when the calculation moved), never discarded.
    def reconcile_override(entry, new_minutes, new_calc_pay)
      return [ {}, new_calc_pay ] unless entry.overtime_overridden?

      if new_minutes.zero? || new_calc_pay <= 0
        approved_minutes = 0
        approved_pay     = 0.0
      elsif entry.overtime_override_mode == "amount"
        approved_pay     = [ entry.approved_overtime_pay.to_f, new_calc_pay ].min.round(2)
        approved_minutes = (new_minutes * approved_pay / new_calc_pay).round
      else
        approved_minutes = [ entry.approved_overtime_minutes.to_i, new_minutes ].min
        approved_pay     = (new_calc_pay * approved_minutes / new_minutes).round(2)
      end

      moved = new_minutes != entry.calculated_overtime_minutes.to_i ||
              (new_calc_pay - entry.calculated_overtime_pay.to_f).abs >= 0.01
      [ { approved_overtime_minutes: approved_minutes, approved_overtime_pay: approved_pay,
          overtime_override_stale: entry.overtime_override_stale || moved }, approved_pay ]
    end

    def apply_row!(row)
      entry = row.entry
      entry.lock!
      previous_snapshot = entry.financial_snapshot

      row.line_updates.each { |line, amount| line.update!(amount: amount) }
      row.line_removals.each(&:destroy!)
      row.line_additions.each do |record, result|
        entry.payroll_line_items.create!(item_type: "overtime", amount: result.overtime_pay.round(2),
                                         source_type: "AttendanceRecord", source_id: record.id,
                                         description: "Overtime #{record.work_date}", review_status: "approved")
      end

      delta = (row.new_payable - row.old_payable).round(2)
      entry.update!(row.override_attrs.merge(
        calculated_overtime_minutes: row.new_minutes,
        calculated_overtime_pay:     row.new_calculated_pay,
        total_overtime:              row.new_payable,
        net_salary:                  (entry.net_salary.to_f + delta).round(2)
      ))
      entry.mark_needs_review!(previous_snapshot)
    end

    def write_audit!(plan)
      PayrollAuditLog.create!(
        payroll_period: period,
        actor:          @actor,
        action_type:    :overtime_recalculated,
        from_status:    period.status,
        to_status:      period.status,
        metadata:       JSON.generate(
          new_threshold_minutes:      plan.threshold,
          previous_threshold_minutes: plan.previous_threshold, # nil = never recorded before this action existed
          affected_employee_count:    plan.affected_count,
          old_total_overtime_minutes: plan.old_total_minutes,
          new_total_overtime_minutes: plan.new_total_minutes,
          old_total_overtime_amount:  plan.old_total_amount,
          new_total_overtime_amount:  plan.new_total_amount,
          recalculated_at:            Time.current.iso8601,
          entries: plan.affected_rows.map { |r|
            { entry_id: r.entry.id, user_id: r.entry.user_id,
              old_minutes: r.old_minutes, new_minutes: r.new_minutes,
              old_payable: r.old_payable, new_payable: r.new_payable,
              removed_days: r.line_removals.map(&:source_id),
              added_days: r.line_additions.map { |rec, _| rec.id },
              repriced_days: r.line_updates.map { |l, _| l.source_id } }
          }
        )
      )
    end

    # The threshold applied by the last run of this action on the period. The
    # threshold a period was originally generated with was never stored, so
    # before the first run this is nil ("not recorded").
    def previous_threshold
      last = PayrollAuditLog.where(payroll_period_id: period.id, action_type: "overtime_recalculated")
                            .order(:created_at, :id).last
      last&.metadata_hash&.dig("new_threshold_minutes")
    end

    def digest_for(rows)
      payload = rows.map do |r|
        [ r.entry.id, r.new_minutes, r.new_calculated_pay, r.new_payable,
          r.line_updates.map { |l, a| [ l.id, a ] }, r.line_removals.map(&:id),
          r.line_additions.map { |rec, res| [ rec.id, res.overtime_pay.round(2) ] } ]
      end
      Digest::SHA256.hexdigest([ business.overtime_grace_minutes.to_i, payload ].to_json)
    end
  end
end
