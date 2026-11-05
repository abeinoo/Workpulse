require "digest"

module Payroll
  # "Recalculate Payroll" — recalculates EVERY entry of a payroll period that
  # is under review (or whose branch reviews are complete) from today's data:
  # date-aware salary (Salary::ProfileTimeline), attendance, penalties,
  # overtime, absence, adjustments, advances, obligations and insurance —
  # exactly as Payroll::EntryRecalculator does for one employee. Regenerate
  # stays draft-only; finalized and paid periods are never recalculated.
  #
  # What is kept: the period status (except that changed floating-employee
  # figures reopen a completed central review — Payroll::CentralReview), branch
  # sign-offs, the audit history, each
  # entry's id and notes, payroll adjustment line items (any status, with their
  # review fields), API-added cash incentives, overtime overrides, deduction
  # waivers and addition cancellations (EntryRecalculator / EntryCalculator).
  #
  # Employees who became eligible after the period was calculated — listed by
  # Payroll::EligibleEmployees, with no entry yet, and with a salary profile in
  # force on at least one day of the period (typically a profile entered after
  # generation) — are added: their entry is created by the same calculation
  # (EntryRecalculator), shown in the preview as added, and treated as changed.
  # Eligible employees still without any salary in the period are left out
  # (the period page lists them — Payroll::UnsalariedAttendance); they never
  # block the run. An added employee whose branch has no review slot gets a
  # pending one (branch_review_completed returns to under_review); a floating
  # one is picked up by Payroll::CentralReview#sync!. This is the only path
  # that adds an employee to a period under review: the automatic paths
  # (salary profile, attendance) recalculate existing entries only.
  #
  # A changed entry is flagged needs_review AND recalculation_review_required:
  # an earlier sign-off is never approval of the new figures, so finalization
  # is refused (Payroll::Approver) until a reviewer marks each one reviewed
  # (Payroll::EntryReviewClearer).
  #
  # #preview runs the real recalculation inside a transaction that is always
  # rolled back — the same code apply! runs, so the preview cannot drift from
  # it, and nothing persists (the path writes database rows only: no jobs, no
  # notifications, no audit or snapshot). Its digest covers the planned result
  # of every entry and a fingerprint of the calculation inputs.
  #
  # #apply! runs in ONE transaction: period row lock, entry row locks, status
  # re-check, input fingerprint check, PayrollSnapshot (pre_recalculate, which
  # also records the employees about to be added as not in payroll), the
  # recalculation, the result digest check, the re-review flags, the new review
  # slots and one PayrollAuditLog (recalculated). Any refusal or failure rolls
  # all of it back.
  class PeriodRecalculator
    ALLOWED_STATUSES = %w[under_review branch_review_completed].freeze
    SNAPSHOT_TRIGGER = "pre_recalculate".freeze
    MONEY_FIELDS = %w[base_salary total_overtime total_bonuses total_deductions already_paid_total
                      advances_deducted obligations_deducted net_salary].freeze

    # salary_starts_on: the first day of the period with a salary profile in
    # force (pay starts there); hire_date: the employee's recorded hire date;
    # first_attendance_on: the first attendance day in the period.
    Row = Struct.new(:entry_id, :user_id, :employee_name, :branch_ids, :before, :after,
                     :breakdown_before, :breakdown_after, :line_items_after,
                     :salary_starts_on, :hire_date, :first_attendance_on, keyword_init: true) do
      # A change of the payroll-visible result (PayrollEntry#financial_snapshot)
      # or of a recorded salary breakdown. A breakdown recorded for the first
      # time on an entry calculated before breakdowns existed is not a change.
      def changed?
        before != after || (!breakdown_before.nil? && breakdown_before != breakdown_after)
      end

      # An employee added by this run had no entry before (before is nil).
      def added? = before.nil?

      def amount(state, field)
        values = send(state)
        values ? BigDecimal(values.fetch(field).to_s) : BigDecimal("0")
      end
      def gross(state) = amount(state, "base_salary") + amount(state, "total_overtime") + amount(state, "total_bonuses")
      # Everything net salary subtracts from gross (PayrollEntry#recalculate_totals!).
      def deductions(state)
        %w[total_deductions already_paid_total advances_deducted obligations_deducted].sum { |f| amount(state, f) }
      end
      def delta(field) = amount(:after, field) - amount(:before, field)
      def split_salary_after? = Array(breakdown_after&.dig("portions")).size > 1

      # Payroll pays from the salary profile's effective date and never reads
      # the hire date, so a profile dated before the hire date pays days the
      # employee was not yet employed (retroactive salary). Exposed, not
      # blocked: the reviewer decides.
      def starts_before_hire?
        !hire_date.nil? && !salary_starts_on.nil? && salary_starts_on < hire_date
      end

      # An added employee without a recorded hire date: the salary start
      # cannot be checked against it.
      def hire_date_missing? = added? && hire_date.nil?

      def salary_start_alert? = changed? && (starts_before_hire? || hire_date_missing?)
    end

    Totals = Struct.new(:base_salary, :gross, :deductions, :net, keyword_init: true)

    # opens_slot: the run opens this review slot (an added employee's branch
    # with no slot yet, or the central review for an added floating employee).
    BranchImpact = Struct.new(:branch_id, :branch_name, :review_status, :reviewer_name, :completed_at,
                              :changed_count, :opens_slot, keyword_init: true) do
      def signed_off? = review_status == "completed"
    end

    Preview = Struct.new(:period, :rows, :totals_before, :totals_after, :branches, :blocked_employees,
                         :new_review_slots, :digest, keyword_init: true) do
      def changed_rows        = rows.select(&:changed?)
      def added_rows          = rows.select(&:added?)
      def changed_count       = changed_rows.size
      def unchanged_count     = rows.size - changed_count
      def nothing_to_change?  = changed_count.zero?
      def blocked?            = blocked_employees.any?
      # Changed employees whose pay starts before their hire date, or added
      # ones with no hire date — to be checked before confirming.
      def salary_start_alerts = rows.select(&:salary_start_alert?)
      # A new review slot sends a period whose reviews were complete back to
      # under_review.
      def reopens_period?     = period.branch_review_completed? && branches.any?(&:opens_slot)
    end

    # Eligible employees with no entry (candidates) and those of them with a
    # salary profile in force during the period (newcomers: the ones added).
    Discovery = Struct.new(:candidates, :newcomers, keyword_init: true)

    Result = Struct.new(:ok, :preview, :error, keyword_init: true) { def ok? = ok }

    def initialize(period_id:, actor:)
      @period_id = period_id
      @actor     = actor
    end

    def preview
      return Result.new(ok: false, error: status_error) unless allowed_status?(period)

      plan = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        plan = build_plan
        raise ActiveRecord::Rollback
      end
      Result.new(ok: true, preview: plan)
    end

    def apply!(expected_digest:, reason:)
      return Result.new(ok: false, error: t("errors.reason_required")) if reason.to_s.strip.empty?

      result = nil
      ActiveRecord::Base.transaction do
        period.lock!
        unless allowed_status?(period)
          result = Result.new(ok: false, error: status_error)
          raise ActiveRecord::Rollback
        end
        period.payroll_entries.lock.load

        # The figures before the run, kept for the record (and the audit entry),
        # with the employees about to be added recorded as not in payroll.
        discovery = discover
        snapshot = SnapshotService.call(period: period, taken_by: @actor, trigger: SNAPSHOT_TRIGGER,
                                        absent_user_ids: discovery.newcomers.map(&:id))
        unless snapshot.success?
          result = Result.new(ok: false, error: snapshot.error)
          raise ActiveRecord::Rollback
        end

        plan = build_plan(discovery)
        refusal = refusal_for(plan, expected_digest)
        if refusal
          result = Result.new(ok: false, preview: plan, error: refusal)
          raise ActiveRecord::Rollback
        end

        from_status = period.status
        flag_for_re_review!(plan)
        open_review_slots!(plan)
        write_audit!(plan, reason.to_s.strip, snapshot.snapshot, from_status)
        # New figures for floating employees reopen a completed central review
        # (and return a branch-review-completed period to review).
        Payroll::CentralReview.new(period).sync!(actor: @actor)
        result = Result.new(ok: true, preview: plan)
      end
      result
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid => e
      # The transaction is already rolled back: no entry, snapshot, flag or
      # audit row of this run persists. Neither the log nor the user sees the
      # exception message: a database error's message can carry row values
      # (salary figures), so only class and attribute names are logged.
      Rails.logger.error("[Payroll::PeriodRecalculator] period=#{@period_id} actor=#{@actor.id} failed: #{failure_summary(e)}")
      Result.new(ok: false, error: t("errors.failed"))
    end

    private

    def period
      @period ||= PayrollPeriod.where(business_id: @actor.business_id).find(@period_id)
    end

    def allowed_status?(record)
      !record.locked? && ALLOWED_STATUSES.include?(record.status)
    end

    def status_error = t("errors.not_allowed_status")

    def refusal_for(plan, expected_digest)
      return t("errors.preview_changed") if plan.digest != expected_digest.to_s
      return t("errors.blocked") if plan.blocked?
      return t("errors.nothing_to_change") if plan.nothing_to_change?

      nil
    end

    # Reads the current state, recalculates every entry and adds the newly
    # eligible employees (inside the caller's transaction), and reads the new
    # state. Employees with no salary profile in force during the period would
    # lose their entry's figures half-way, so any such employee blocks the
    # whole run — nothing is recalculated or added.
    def build_plan(discovery = discover)
      entries  = period.payroll_entries.includes(user: :salary_profiles).order(:id).to_a
      inputs   = input_fingerprint(entries, discovery.candidates)
      before   = entries.to_h { |e| [ e.id, state_of(e) ] }
      totals_0 = totals_for(entries.map(&:id))

      blocked = entries.select { |e| unsalaried?(e.user) }.map { |e| e.user.full_name }
      newcomers = blocked.any? ? [] : discovery.newcomers
      unless blocked.any?
        entries.each do |entry|
          EntryRecalculator.call(user: entry.user, period: period, triggered_by: @actor)
        end
        newcomers.each do |user|
          EntryRecalculator.call(user: user, period: period, triggered_by: @actor)
        end
      end

      added    = period.payroll_entries.where(user_id: newcomers.map(&:id))
                        .includes(user: :salary_profiles).order(:id).to_a
      all_ids  = entries.map(&:id) + added.map(&:id)
      after_entries = PayrollEntry.where(id: all_ids).includes(:payroll_line_items).index_by(&:id)
      obligation_of = period.obligation_deductions.pluck(:id, :employee_obligation_id).to_h
      branches_by_user = branch_ids_by_user((entries + added).map(&:user_id))
      first_attendance = AttendanceRecord.active
                                         .where(user_id: (entries + added).map(&:user_id),
                                                work_date: period.period_start..period.period_end)
                                         .group(:user_id).minimum(:work_date)
      rows = (entries + added).map do |entry|
        now  = after_entries.fetch(entry.id)
        prev = before[entry.id] || {} # nothing before: added by this run
        Row.new(entry_id: entry.id, user_id: entry.user_id, employee_name: entry.user.full_name,
                branch_ids: branches_by_user.fetch(entry.user_id, []),
                before: prev[:financial], after: state_of(now)[:financial],
                breakdown_before: prev[:breakdown], breakdown_after: now.salary_breakdown,
                line_items_after: line_item_signature(now, obligation_of),
                salary_starts_on: salary_starts_on(entry.user), hire_date: entry.user.hire_date,
                first_attendance_on: first_attendance[entry.user_id])
      end

      new_slots = review_slots_to_open(added.map(&:user_id))
      Preview.new(period: period, rows: rows, totals_before: totals_0, totals_after: totals_for(all_ids),
                  branches: branch_impacts(rows, new_slots), blocked_employees: blocked,
                  new_review_slots: new_slots, digest: digest_for(inputs, rows, new_slots))
    end

    # Read-only: the eligible employees without an entry in this period, and
    # those of them who have a salary profile in force during it.
    def discover
      candidates = EligibleEmployees.for(business: period.business, year: period.period_year,
                                         month: period.period_month)
                                    .where.not(id: period.payroll_entries.select(:user_id))
                                    .includes(:salary_profiles).order(:id).to_a
      Discovery.new(candidates: candidates, newcomers: candidates.reject { |user| unsalaried?(user) })
    end

    # The branches of the added employees that have no review slot yet — the
    # rule Payroll::SubmitForReview opens slots by (a branch the employee worked
    # at during the period, with a manager to review it). Floating employees
    # have no branch: Payroll::CentralReview#sync! covers them.
    def review_slots_to_open(added_user_ids)
      return [] if added_user_ids.empty?

      branch_ids = ShiftAssignment.branch_ids_for_users(added_user_ids, from: period.period_start,
                                                                        to: period.period_end).compact
      with_slot  = period.payroll_period_branch_reviews.where.not(branch_id: nil).pluck(:branch_id)
      Branch.where(id: branch_ids - with_slot).where.not(branch_manager_id: nil)
            .includes(:branch_manager).order(:name, :id).to_a
    end

    def open_review_slots!(plan)
      plan.new_review_slots.each do |branch|
        PayrollPeriodBranchReview.create!(payroll_period: period, branch: branch,
                                          reviewer: branch.branch_manager, status: :pending)
      end
      period.update!(status: :under_review) if plan.new_review_slots.any? && period.branch_review_completed?
    end

    def salary_starts_on(user)
      Salary::ProfileTimeline.for(user).segments(period.period_start, period.period_end).first&.starts_on
    end

    def unsalaried?(user)
      Salary::ProfileTimeline.for(user).segments(period.period_start, period.period_end).empty?
    end

    def state_of(entry)
      { financial: entry.financial_snapshot.transform_values { |v| v.is_a?(BigDecimal) ? v.to_s("F") : v },
        breakdown: entry.salary_breakdown }
    end

    # The planned line items, by identities that are stable across runs. Every
    # source is an existing row, except an obligation deduction's: the run
    # destroys and recreates its ObligationDeduction snapshot, so its id is a new
    # sequence value each time (the rolled-back preview's and the confirmation's
    # differ) — it is identified by its obligation instead.
    def line_item_signature(entry, obligation_of)
      entry.payroll_line_items.map do |li|
        source = li.source_type == "ObligationDeduction" ? [ :obligation, obligation_of.fetch(li.source_id) ] : li.source_id
        [ li.item_type, li.amount.to_s, li.source_type, source, li.review_status,
          li.deduction_waived?, li.addition_cancelled?, li.already_paid? ]
      end.sort_by(&:to_s)
    end

    # The period page's figures (Payroll::PeriodFinancialSummary) plus base.
    def totals_for(entry_ids)
      entries = PayrollEntry.where(id: entry_ids)
      summary = PeriodFinancialSummary.new(entries)
      Totals.new(base_salary: BigDecimal(entries.sum(:base_salary).to_s), gross: BigDecimal(summary.gross_payroll.to_s),
                 deductions: BigDecimal(summary.total_deductions.to_s), net: BigDecimal(summary.net_payroll.to_s))
    end

    # The branches an employee worked at during the period — the same rule
    # Payroll::SubmitForReview uses to open the branch review slots. A floating
    # assignment counts as nil: the central review slot (branch_id NULL).
    def branch_ids_by_user(user_ids)
      ShiftAssignment.active_during(period.period_start, period.period_end)
                     .where(user_id: user_ids).distinct.pluck(:user_id, :branch_id, :assignment_kind)
                     .reject { |_, branch_id, kind| branch_id.nil? && kind != "floating" }
                     .group_by(&:first).transform_values { |rows| rows.map(&:second).uniq }
    end

    def branch_impacts(rows, new_slots)
      changed  = rows.select(&:changed?)
      opening  = new_slots.map(&:id)
      reviews  = period.payroll_period_branch_reviews.includes(:branch, :reviewer).index_by(&:branch_id)
      ids      = (changed.flat_map(&:branch_ids) + reviews.keys).uniq
      names    = Branch.where(id: ids).pluck(:id, :name).to_h

      ids.filter_map do |branch_id|
        count = changed.count { |r| r.branch_ids.include?(branch_id) }
        next if count.zero?

        review = reviews[branch_id]
        name   = branch_id ? names[branch_id] : I18n.t("payroll.central_review.label")
        # The central slot is opened by CentralReview#sync! for any floating
        # employee in the period — here, only an added one can lack it.
        opens  = review.nil? && (branch_id ? opening.include?(branch_id) : true)
        BranchImpact.new(branch_id: branch_id, branch_name: name, review_status: review&.status,
                         reviewer_name: review&.reviewer&.full_name, completed_at: review&.completed_at,
                         changed_count: count, opens_slot: opens)
      end.sort_by { |b| b.branch_name.to_s }
    end

    # The calculation inputs of this period's employees, as a checksum of the
    # full rows of each source (any column change, insertion or deletion moves
    # it — independent of timestamps): salary profiles, attendance, penalty
    # rules, payroll adjustments, obligations and their deductions, advances,
    # the entries and line items themselves (overrides, waivers, cancellations,
    # reviews), the branch reviews, the period and the business's overtime and
    # working-day settings. Inputs owned by other domains that reach the
    # calculation (insurance, permission requests, shift assignments) are
    # covered by the planned result in the digest: the recalculation reads them,
    # so any change to them that affects pay changes the plan. The employees
    # who could be added (eligible, no entry) are covered by their ids and the
    # same sources, so e.g. a salary profile entered after the preview moves it.
    def input_fingerprint(entries, candidates)
      user_ids  = entries.map(&:user_id) + candidates.map(&:id)
      entry_ids = entries.map(&:id)
      range     = period.period_start..period.period_end
      business  = period.business

      sources = {
        salary_profiles:   SalaryProfile.where(user_id: user_ids),
        attendance:        AttendanceRecord.where(user_id: user_ids, work_date: range),
        penalty_rules:     PenaltyRule.joins(:shift).where(shifts: { business_id: business.id }),
        adjustments:       PayrollAdjustment.where(business_id: business.id, period_year: period.period_year,
                                                   period_month: period.period_month),
        obligations:       EmployeeObligation.where(user_id: user_ids),
        obligation_deductions: period.obligation_deductions,
        advances:          Advance.where(user_id: user_ids),
        entries:           PayrollEntry.where(id: entry_ids),
        line_items:        PayrollLineItem.where(payroll_entry_id: entry_ids),
        branch_reviews:    period.payroll_period_branch_reviews,
        period:            PayrollPeriod.where(id: period.id)
      }
      sources.transform_values { |scope| rows_checksum(scope) }.merge(
        settings:   [ business.overtime_grace_minutes, business.working_days_per_month, business.timezone ],
        candidates: candidates.map(&:id).sort
      )
    end

    def rows_checksum(scope)
      table = scope.table_name
      sql   = scope.select("#{table}.*").to_sql
      ActiveRecord::Base.connection.select_value(
        "SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t.id), '')) FROM (#{sql}) t"
      )
    end

    # An added row is identified by its employee: its entry is created by the
    # run, so its id differs between the rolled-back preview and the
    # confirmation (never put ids of rows the run creates into the digest).
    def digest_for(inputs, rows, new_slots)
      payload = rows.map do |r|
        [ r.added? ? [ :added, r.user_id ] : r.entry_id, r.before, r.after, r.breakdown_after, r.line_items_after ]
      end
      Digest::SHA256.hexdigest(JSON.generate([ inputs, payload, new_slots.map(&:id) ]))
    end

    # The new figures are not covered by any earlier review: flag them for a
    # fresh one. Unchanged entries keep their review state.
    def flag_for_re_review!(plan)
      ids = plan.changed_rows.map(&:entry_id)
      PayrollEntry.where(id: ids).update_all(needs_review: true, recalculation_review_required: true,
                                             updated_at: Time.current)
    end

    def write_audit!(plan, reason, snapshot, from_status)
      PayrollAuditLog.create!(
        payroll_period: period,
        actor:          @actor,
        action_type:    :recalculated,
        from_status:    from_status,
        to_status:      period.status,
        metadata:       JSON.generate(
          reason:                 reason,
          recalculated_at:        Time.current.iso8601,
          snapshot_id:            snapshot.id,
          employee_count:         plan.rows.size,
          changed_employee_count: plan.changed_count,
          added_employee_count:   plan.added_rows.size,
          review_slots_opened:    plan.new_review_slots.map { |b| { branch_id: b.id, branch_name: b.name } },
          period_reopened:        from_status != period.status,
          totals_before:          plan.totals_before.to_h.transform_values { |v| v.to_s("F") },
          totals_after:           plan.totals_after.to_h.transform_values { |v| v.to_s("F") },
          affected_branches:      plan.branches.map { |b|
            { branch_id: b.branch_id, review_status: b.review_status, changed_count: b.changed_count }
          },
          entries:                plan.changed_rows.map { |r|
            { entry_id: r.entry_id, user_id: r.user_id, added: r.added?,
              before: r.before&.slice(*MONEY_FIELDS), after: r.after.slice(*MONEY_FIELDS) }
          },
          # What the reviewer was shown and confirmed past (dates only).
          salary_start_alerts:    plan.salary_start_alerts.map { |r|
            { user_id: r.user_id, salary_starts_on: r.salary_starts_on&.iso8601, hire_date: r.hire_date&.iso8601,
              first_attendance_on: r.first_attendance_on&.iso8601 }
          }
        )
      )
    end

    def failure_summary(error)
      case error
      when ActiveRecord::RecordInvalid
        "#{error.class} #{error.record.class.name}##{error.record.id} attributes=#{error.record.errors.attribute_names.inspect}"
      else
        [ error.class.name, error.cause&.class&.name ].compact.join(" < ")
      end
    end

    def t(key, **) = I18n.t("payroll.period_recalculation.#{key}", **)
  end
end
