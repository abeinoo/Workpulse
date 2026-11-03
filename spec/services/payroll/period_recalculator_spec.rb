require "rails_helper"

# Payroll::PeriodRecalculator — "Recalculate Payroll" for an under-review or
# branch-review-completed period. Fixture (October 2026, the reported case):
#   Ahmed — daily 461.54 from Mar 1; a raise to 500 effective Oct 15 is entered
#   AFTER the period was calculated (directly, bypassing the profile updater's
#   own recalculation). 7 days before and 7 days after Oct 15:
#     before: 14 × 461.54 = 6,461.56   after: 7 × 461.54 + 7 × 500 = 6,730.78
#   Sara — monthly 9,000 since January, unaffected (unchanged entry).
RSpec.describe Payroll::PeriodRecalculator do
  around { |ex| travel_to(Time.zone.local(2026, 11, 10, 12, 0, 0)) { ex.run } }

  let(:business) do
    create(:business, working_days_per_month: 26, timezone: "UTC", overtime_grace_minutes: 30)
  end
  let(:north) { create(:branch, business: business, name: "North") }
  let(:south) { create(:branch, business: business, name: "South") }
  let(:north_manager) { create(:user, business: business) }
  let(:south_manager) { create(:user, business: business) }
  let!(:actor) { create(:user, :accountant, business: business) } # eager: never created inside a checksum window
  let(:ahmed) { create(:user, business: business, first_name: "Ahmed", last_name: "Abdallah") }
  let(:sara)  { create(:user, business: business, first_name: "Sara", last_name: "Hassan") }

  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"),
           end_time: Time.zone.parse("17:00"), overtime_rate_multiplier: 1.5)
  end
  let!(:ahmed_assignment) do
    create(:shift_assignment, user: ahmed, branch: north, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let!(:sara_assignment) do
    create(:shift_assignment, user: sara, branch: south, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let!(:late_rule) do
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 50)
  end

  let(:october) { create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26) }

  def oct(day) = Date.new(2026, 10, day)

  def work(user, assignment, date, late: 0, overtime: 0)
    create(:attendance_record, user: user, branch: assignment.branch, shift_assignment: assignment,
           date: date, work_date: date,
           check_in_at:  Time.zone.local(date.year, date.month, date.day, 9, 0) + late.minutes,
           check_out_at: Time.zone.local(date.year, date.month, date.day, 17, 0) + overtime.minutes,
           worked_minutes: 480 - late + overtime, late_minutes: late, early_leave_minutes: 0,
           status: late.positive? ? "late" : "present")
  end

  let!(:ahmed_late_day)     { work(ahmed, ahmed_assignment, oct(14), late: 60) }
  let!(:ahmed_overtime_day) { work(ahmed, ahmed_assignment, oct(20), overtime: 60) }

  before do
    north.update_column(:branch_manager_id, north_manager.id)
    south.update_column(:branch_manager_id, south_manager.id)
    create(:salary_profile, :daily, user: ahmed, base_amount: 461.54, effective_from: Date.new(2026, 3, 1))
    create(:salary_profile, :monthly, user: sara, base_amount: 9_000, effective_from: Date.new(2026, 1, 1))
    [ 1, 4, 6, 7, 8, 11 ].each { |d| work(ahmed, ahmed_assignment, oct(d)) }
    [ 15, 18, 21, 25, 28, 29 ].each { |d| work(ahmed, ahmed_assignment, oct(d)) }
    (1..26).each { |d| work(sara, sara_assignment, oct(d)) }

    [ ahmed, sara ].each { |u| Payroll::EntryCalculator.call(period: october, user: u, business: business) }
    october.payroll_entries.update_all(needs_review: false)
    october.update!(status: "under_review")
    create(:payroll_period_branch_review, payroll_period: october, branch: north, reviewer: north_manager,
                                          status: "completed", completed_at: Time.zone.local(2026, 11, 3, 9, 0))
    create(:payroll_period_branch_review, payroll_period: october, branch: south, reviewer: south_manager,
                                          status: "pending")

    # The raise, entered after the period was calculated.
    create(:salary_profile, :daily, user: ahmed, base_amount: 500, effective_from: oct(15))
  end

  def service(user = actor) = described_class.new(period_id: october.id, actor: user)
  def preview = service.preview.preview
  def apply!(digest = preview.digest, reason: "Date-aware salary fix (PR #111)") = service.apply!(expected_digest: digest, reason: reason)
  def entry_of(user) = october.payroll_entries.find_by!(user: user)
  def row_of(plan, user) = plan.rows.find { |r| r.user_id == user.id }

  # Every row of every table, as one checksum per table.
  def database_checksum
    conn = ActiveRecord::Base.connection
    (conn.tables - %w[schema_migrations ar_internal_metadata]).sort.to_h do |table|
      quoted = conn.quote_table_name(table)
      [ table, conn.select_value("SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t::text), '')) FROM #{quoted} t") ]
    end
  end

  describe "statuses" do
    %w[under_review branch_review_completed].each do |status|
      it "previews and applies a #{status} period, keeping the status" do
        october.update_column(:status, status)

        expect(service.preview).to be_ok
        expect(apply!).to be_ok
        expect(october.reload.status).to eq(status)
      end
    end

    %w[draft finalized paid].each do |status|
      it "refuses a #{status} period without writing anything" do
        october.update_column(:status, status)
        before = database_checksum

        expect(service.preview).not_to be_ok
        result = service.apply!(expected_digest: "anything", reason: "test")
        expect(result).not_to be_ok
        expect(result.error).to eq(I18n.t("payroll.period_recalculation.errors.not_allowed_status"))
        expect(database_checksum).to eq(before)
      end
    end

    it "never finds another business's period" do
      outsider = create(:user, :accountant, business: create(:business))

      expect { described_class.new(period_id: october.id, actor: outsider).preview }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "#preview" do
    it "shows the before/after figures of the date-aware salary fix" do
      plan = preview

      ahmed_row = row_of(plan, ahmed)
      expect(ahmed_row).to be_changed
      expect(ahmed_row.amount(:before, "base_salary")).to eq(BigDecimal("6461.56"))
      expect(ahmed_row.amount(:after, "base_salary")).to eq(BigDecimal("6730.78"))
      expect(ahmed_row.split_salary_after?).to be(true)
      expect(ahmed_row.breakdown_after["portions"].map { |p| p["amount"] }).to eq(%w[3230.78 3500.00])
      expect(row_of(plan, sara)).not_to be_changed

      expect(plan.changed_count).to eq(1)
      expect(plan.unchanged_count).to eq(1)
      expect(plan.totals_after.base_salary - plan.totals_before.base_salary).to eq(BigDecimal("269.22"))
      expect(plan.totals_after.net - plan.totals_before.net).to be > BigDecimal("269.22") # overtime repriced too
    end

    it "identifies the affected branches and their existing sign-offs" do
      branches = preview.branches

      expect(branches.map(&:branch_name)).to eq(%w[North])
      north_impact = branches.sole
      expect(north_impact).to be_signed_off
      expect(north_impact.reviewer_name).to eq(north_manager.full_name)
      expect(north_impact.changed_count).to eq(1)
    end

    it "has zero persistent side effects: no row in any table, no job" do
      ActiveJob::Base.queue_adapter = :test
      before = database_checksum

      expect { 2.times { service.preview } }.not_to have_enqueued_job
      expect(database_checksum).to eq(before)
    end

    it "is repeatable: the same data gives the same digest" do
      expect(preview.digest).to eq(preview.digest)
    end
  end

  describe "#apply!" do
    it "recalculates, flags the changed entry for re-review and leaves the unchanged one alone" do
      expect(apply!).to be_ok

      ahmed_entry = entry_of(ahmed)
      expect(ahmed_entry.base_salary).to eq(BigDecimal("6730.78"))
      expect(ahmed_entry.salary_breakdown_portions.map { |p| p["amount"] }).to eq(%w[3230.78 3500.00])
      expect(ahmed_entry).to have_attributes(needs_review: true, recalculation_review_required: true)
      expect(entry_of(sara)).to have_attributes(needs_review: false, recalculation_review_required: false)
    end

    it "keeps the totals consistent with the line items" do
      apply!
      entry = entry_of(ahmed)
      before = entry.attributes.slice(*Payroll::PeriodRecalculator::MONEY_FIELDS)

      entry.recalculate_totals!
      expect(entry.reload.attributes.slice(*Payroll::PeriodRecalculator::MONEY_FIELDS)).to eq(before)
    end

    it "keeps every branch sign-off exactly as it was" do
      before = october.payroll_period_branch_reviews.order(:id).map(&:attributes)

      apply!
      expect(october.payroll_period_branch_reviews.order(:id).map(&:attributes)).to eq(before)
    end

    it "takes a pre_recalculate snapshot of the figures before the run" do
      apply!

      snapshot = october.payroll_snapshots.sole
      expect(snapshot).to have_attributes(trigger: "pre_recalculate", taken_by_id: actor.id, employee_count: 2)
      ahmed_before = snapshot.employee_details.find { |e| e["user_id"] == ahmed.id }
      expect(ahmed_before["base"]).to eq(6461.56)
    end

    it "records who, when, why and what changed in one recalculated audit entry" do
      apply!

      log = october.payroll_audit_logs.where(action_type: "recalculated").sole
      meta = log.metadata_hash
      expect(log).to have_attributes(actor_id: actor.id, from_status: "under_review", to_status: "under_review")
      expect(meta).to include("reason" => "Date-aware salary fix (PR #111)", "employee_count" => 2,
                              "changed_employee_count" => 1, "snapshot_id" => october.payroll_snapshots.sole.id)
      expect(meta["entries"].sole).to include("user_id" => ahmed.id)
      expect(meta["entries"].sole["before"]["base_salary"]).to eq("6461.56")
      expect(meta["entries"].sole["after"]["base_salary"]).to eq("6730.78")
      expect(meta["affected_branches"].sole).to include("branch_id" => north.id, "review_status" => "completed")
    end

    it "requires a reason" do
      [ nil, "", "   " ].each do |reason|
        result = service.apply!(expected_digest: preview.digest, reason: reason)
        expect(result.error).to eq(I18n.t("payroll.period_recalculation.errors.reason_required"))
      end
      expect(entry_of(ahmed).base_salary).to eq(BigDecimal("6461.56"))
    end
  end

  describe "stale previews" do
    def expect_refused_without_writes(digest)
      before = database_checksum
      result = apply!(digest)
      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("payroll.period_recalculation.errors.preview_changed"))
      expect(database_checksum).to eq(before)
    end

    it "refuses after an attendance change" do
      digest = preview.digest
      work(ahmed, ahmed_assignment, oct(30))
      expect_refused_without_writes(digest)
    end

    it "refuses after a salary profile change, even one that does not change the result" do
      digest = preview.digest
      sara.salary_profiles.sole.update!(overtime_multiplier: 2.0) # Sara has no overtime: same pay, new input
      expect(preview.rows.find { |r| r.user_id == sara.id }).not_to be_changed
      expect_refused_without_writes(digest)
    end

    it "refuses after the overtime setting changes" do
      digest = preview.digest
      business.update!(overtime_grace_minutes: 45)
      expect_refused_without_writes(digest)
    end

    it "refuses after an adjustment is added" do
      digest = preview.digest
      create(:payroll_adjustment, payroll_period: october, user: ahmed, adjustment_type: :cash_incentive,
                                  amount: 100, review_status: :approved)
      expect_refused_without_writes(digest)
    end

    it "refuses after a branch review changes" do
      digest = preview.digest
      october.payroll_period_branch_reviews.find_by!(branch: south).update!(status: "completed", completed_at: Time.current)
      expect_refused_without_writes(digest)
    end

    it "refuses a made-up digest" do
      expect_refused_without_writes("0" * 64)
    end
  end

  describe "atomicity" do
    it "rolls back every entry, the snapshot and the audit when one employee fails" do
      digest = preview.digest
      allow(Payroll::EntryRecalculator).to receive(:call).and_wrap_original do |original, **kwargs|
        raise ActiveRecord::RecordInvalid, PayrollEntry.new if kwargs[:user].id == sara.id

        original.call(**kwargs)
      end
      before = database_checksum

      result = apply!(digest)
      expect(result).not_to be_ok
      expect(database_checksum).to eq(before)
      expect(entry_of(ahmed).base_salary).to eq(BigDecimal("6461.56")) # recalculated first, then rolled back
    end

    it "blocks the whole run when an employee has no salary profile in force during the period" do
      nobody = create(:user, business: business, first_name: "Omar", last_name: "Nasser")
      create(:payroll_entry, payroll_period: october, user: nobody, base_salary: 1_000, net_salary: 1_000)

      plan = preview
      expect(plan).to be_blocked
      expect(plan.blocked_employees).to eq([ nobody.full_name ])

      before = database_checksum
      result = apply!(plan.digest)
      expect(result.error).to eq(I18n.t("payroll.period_recalculation.errors.blocked"))
      expect(database_checksum).to eq(before)
    end
  end

  describe "logging and external side effects" do
    # What reaches the application log at the production level (info).
    def logged_during
      io = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = :info }
      yield
      io.string
    ensure
      Rails.logger = previous
    end

    let(:sensitive) { [ "6461.56", "6730.78", "461.54", "3230.78", "9000", "Ahmed", "Abdallah", "Sara" ] }

    it "logs ids only — no amounts, rates or names — for the preview and the run" do
      log = logged_during do
        digest = service.preview.preview.digest
        apply!(digest)
      end

      expect(log).to include("[Payroll::EntryRecalculator]")
      sensitive.each { |value| expect(log).not_to include(value), "log exposed #{value}" }
    end

    it "sends no mail and enqueues no job, for the preview or the run" do
      ActiveJob::Base.queue_adapter = :test
      deliveries = ActionMailer::Base.deliveries.size

      expect { apply!(preview.digest) }.not_to have_enqueued_job
      expect(ActionMailer::Base.deliveries.size).to eq(deliveries)
    end

    it "keeps a failure's details (which may carry row values) out of the log and the error" do
      digest = preview.digest
      allow(Payroll::EntryRecalculator).to receive(:call)
        .and_raise(ActiveRecord::StatementInvalid, "PG::CheckViolation: DETAIL: Failing row contains (6730.78, Ahmed)")

      result = nil
      log = logged_during { result = apply!(digest) }

      expect(result.error).to eq(I18n.t("payroll.period_recalculation.errors.failed"))
      expect(log).to include("[Payroll::PeriodRecalculator]", "ActiveRecord::StatementInvalid")
      expect(log).not_to include("6730.78")
      expect(log).not_to include("Ahmed")
    end
  end

  describe "idempotency" do
    it "has nothing left to change after one run, and a reused digest is refused" do
      digest = preview.digest
      expect(apply!(digest)).to be_ok

      expect(apply!(digest).error).to eq(I18n.t("payroll.period_recalculation.errors.preview_changed"))
      fresh = preview
      expect(fresh).to be_nothing_to_change
      expect(apply!(fresh.digest).error).to eq(I18n.t("payroll.period_recalculation.errors.nothing_to_change"))
      expect(october.payroll_audit_logs.where(action_type: "recalculated").count).to eq(1)
      expect(october.payroll_snapshots.count).to eq(1)
    end
  end

  describe "preservation" do
    let(:entry) { entry_of(ahmed) }
    let(:reviewer) { create(:user, :accountant, business: business) }

    def line(type, record = nil)
      scope = entry.payroll_line_items.where(item_type: type)
      record ? scope.find_by!(source_type: record.class.name, source_id: record.id) : scope
    end

    it "keeps the entry's notes and status" do
      entry.update_columns(notes: "checked by HR", status: "disputed")
      apply!

      expect(entry.reload).to have_attributes(notes: "checked by HR", status: "disputed")
    end

    it "keeps pending and rejected adjustment line items with their status and review fields" do
      pending = create(:payroll_adjustment, payroll_period: october, user: ahmed, adjustment_type: :manual_deduction,
                                            amount: 120, review_status: :pending_review)
      rejected = create(:payroll_adjustment, payroll_period: october, user: ahmed, adjustment_type: :cash_incentive,
                                             amount: 300, review_status: :rejected)
      pending_line = entry.payroll_line_items.create!(item_type: "manual_deduction", amount: -120, description: pending.reason,
                                                      source_type: "PayrollAdjustment", source_id: pending.id,
                                                      review_status: "pending_review")
      rejected_line = entry.payroll_line_items.create!(item_type: "cash_incentive", amount: 300, description: rejected.reason,
                                                       source_type: "PayrollAdjustment", source_id: rejected.id,
                                                       review_status: "rejected", reviewed_by: reviewer,
                                                       reviewed_at: Time.zone.local(2026, 11, 5, 10), review_notes: "duplicate")
      entry.recalculate_totals!

      expect(apply!).to be_ok

      expect(pending_line.reload).to have_attributes(review_status: "pending_review", amount: BigDecimal("-120"))
      expect(rejected_line.reload).to have_attributes(review_status: "rejected", reviewed_by_id: reviewer.id,
                                                      review_notes: "duplicate")
      # Neither counts toward pay: deductions are the Oct 14 late penalty only
      # (50% of that day's 461.54), and there are no bonuses.
      expect(entry.reload).to have_attributes(total_deductions: BigDecimal("230.77"), total_bonuses: 0)
    end

    it "keeps an approved adjustment's line item (and its review fields) without duplicating it" do
      approved = create(:payroll_adjustment, payroll_period: october, user: ahmed, adjustment_type: :commission,
                                             amount: 200, review_status: :approved)
      Payroll::AdjustmentApplier.call(adjustment: approved)
      line = entry.payroll_line_items.find_by!(source_type: "PayrollAdjustment", source_id: approved.id)
      line.update_columns(reviewed_by_id: reviewer.id, review_notes: "ok")

      expect(apply!).to be_ok

      kept = entry.payroll_line_items.where(source_type: "PayrollAdjustment", source_id: approved.id)
      expect(kept.map(&:id)).to eq([ line.id ])
      expect(kept.sole).to have_attributes(reviewed_by_id: reviewer.id, review_notes: "ok")
      expect(entry.reload.total_bonuses).to eq(BigDecimal("200"))
    end

    it "keeps an API-added cash incentive (same row) and keeps counting it" do
      incentive = entry.payroll_line_items.create!(item_type: "cash_incentive", amount: 250, description: "Manual incentive",
                                                   review_status: "approved", already_paid: false)
      entry.recalculate_totals!

      expect(apply!).to be_ok

      expect(incentive.reload.amount).to eq(BigDecimal("250"))
      expect(entry.reload.total_bonuses).to eq(BigDecimal("250"))
      expect(entry.net_salary).to eq(entry.base_salary + entry.total_overtime + 250 - entry.total_deductions)
    end

    it "keeps an overtime override, a deduction waiver and an addition cancellation" do
      overtime_line = line("overtime", ahmed_overtime_day)
      overtime_line.update!(addition_cancelled: true, addition_cancellation_reason: "not approved",
                            addition_cancelled_by: reviewer, addition_cancelled_at: Time.current)
      late_line = line("late_penalty", ahmed_late_day)
      late_line.update!(deduction_waived: true, deduction_waiver_reason: "traffic", deduction_waived_by: reviewer,
                        deduction_waived_at: Time.current)
      entry.update!(overtime_override_mode: "minutes", approved_overtime_minutes: 30, overtime_override_reason: "cap",
                    overtime_overridden_by_id: reviewer.id, overtime_overridden_at: Time.current)
      entry.recalculate_totals!

      expect(apply!).to be_ok

      entry.reload
      expect(entry).to have_attributes(overtime_override_mode: "minutes", overtime_override_reason: "cap",
                                       overtime_overridden_by_id: reviewer.id)
      expect(line("late_penalty", ahmed_late_day)).to have_attributes(deduction_waived: true, deduction_waiver_reason: "traffic")
      expect(line("overtime", ahmed_overtime_day)).to have_attributes(addition_cancelled: true,
                                                                     addition_cancellation_reason: "not approved")
      expect(entry.total_deductions).to eq(0) # the waived penalty is still excluded
    end
  end

  describe "re-review and finalization" do
    before { october.update_column(:status, "branch_review_completed") }

    def finalize = Payroll::Approver.advance(period: october.reload, by: actor)

    it "refuses to finalize while a recalculated entry awaits review, despite the earlier sign-off" do
      apply!

      result = finalize
      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("payroll.errors.recalculation_review_required_finalize", count: 1))
      expect(october.reload.status).to eq("branch_review_completed")
    end

    it "finalizes once the recalculated entry is marked reviewed, with the acknowledgement audited" do
      apply!
      expect(Payroll::EntryReviewClearer.call(entry: entry_of(ahmed), actor: actor)).to be_success

      expect(entry_of(ahmed)).to have_attributes(needs_review: false, recalculation_review_required: false)
      cleared = october.payroll_audit_logs.where(action_type: "entry_review_cleared").sole
      expect(cleared.metadata_hash).to include("employee_id" => ahmed.id, "recalculation_reviewed" => true)
      expect(finalize).to be_success
      expect(october.reload).to be_finalized
    end

    it "does not let the flag clear without its audit entry" do
      apply!
      allow(PayrollAuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "audit down")

      expect(Payroll::EntryReviewClearer.call(entry: entry_of(ahmed), actor: actor)).not_to be_success
      expect(entry_of(ahmed).recalculation_review_required).to be(true)
    end

    it "stays blocked until EVERY changed entry is reviewed" do
      create(:salary_profile, :monthly, user: sara, base_amount: 9_600, effective_from: oct(15))
      expect(apply!).to be_ok
      expect(october.payroll_entries.where(recalculation_review_required: true).count).to eq(2)

      Payroll::EntryReviewClearer.call(entry: entry_of(ahmed), actor: actor)
      result = finalize
      expect(result.error).to eq(I18n.t("payroll.errors.recalculation_review_required_finalize", count: 1))
      expect(october.reload.status).to eq("branch_review_completed")

      Payroll::EntryReviewClearer.call(entry: entry_of(sara), actor: actor)
      expect(finalize).to be_success
    end

    it "needs no re-review when nothing changed" do
      SalaryProfile.where(user: ahmed, base_amount: 500).delete_all
      expect(preview).to be_nothing_to_change
      expect(finalize).to be_success
    end
  end
end
