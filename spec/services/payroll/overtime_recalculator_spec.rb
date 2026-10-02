require "rails_helper"

# Figures (same fixture shape as entry_recalculator_spec):
#   8 800 / month, 22 working days → daily 400; shift 09:00–17:00 (480 min)
#   hourly 50 × 1.5 → 75 per overtime hour
#   45 min OT = 56.25   |   90 min OT = 112.50   |   20 min OT = never
RSpec.describe Payroll::OvertimeRecalculator do
  around { |ex| travel_to(Time.zone.local(2026, 10, 2, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22, timezone: "UTC", overtime_grace_minutes: 30) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }

  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"),
           end_time: Time.zone.parse("17:00"), overtime_rate_multiplier: 1.5)
  end
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let!(:salary_profile) do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
  end
  let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 9, working_days: 22) }

  def record_on(day, overtime:)
    date = Date.new(2026, 9, day)
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: date, work_date: date,
           check_in_at: Time.zone.local(2026, 9, day, 9, 0),
           check_out_at: Time.zone.local(2026, 9, day, 17, 0) + overtime.minutes,
           worked_minutes: 480 + overtime, late_minutes: 0, early_leave_minutes: 0, status: "present")
  end

  let!(:day_45) { record_on(1, overtime: 45) }  # counts at 30, not at 60
  let!(:day_90) { record_on(2, overtime: 90) }  # counts under both
  let!(:day_20) { record_on(3, overtime: 20) }  # never counts

  # September generated with the OLD 30-minute threshold, then sent for review,
  # then the setting changes to 60.
  def generate_under_review!
    create(:payroll_adjustment, payroll_period: period, user: employee, adjustment_type: :cash_incentive,
           amount: 300, review_status: :approved)
    create(:payroll_adjustment, payroll_period: period, user: employee, adjustment_type: :manual_deduction,
           amount: 120, review_status: :approved)
    Payroll::EntryCalculator.call(period: period, user: employee, business: business)
    period.update!(status: "under_review")
    entry.update_columns(needs_review: false, notes: "checked by HR")
    business.update!(overtime_grace_minutes: 60)
  end

  def entry = period.payroll_entries.find_by!(user: employee)
  def service = described_class.new(period_id: period.id, actor: actor)
  def ot_lines = entry.payroll_line_items.where(item_type: "overtime").order(:source_id)

  def apply!
    digest = service.preview.preview.digest
    service.apply!(expected_digest: digest)
  end

  NON_OT_COLUMNS = %w[base_salary salary_type working_days days_worked total_deductions total_bonuses
                      already_paid_total advances_deducted obligations_deducted insured
                      employee_insurance_amount employer_insurance_amount insurance_number status notes].freeze

  describe "the old 30-minute data under the new 60-minute rule" do
    before { generate_under_review! }

    it "starts from the 30-minute result: 45 and 90 minute days are paid" do
      expect(ot_lines.map { |l| [ l.source_id, l.amount.to_f ] }).to eq([ [ day_45.id, 56.25 ], [ day_90.id, 112.5 ] ])
      expect(entry.calculated_overtime_minutes).to eq(135)
      expect(entry.total_overtime.to_f).to eq(168.75)
    end

    it "previews the change without writing anything" do
      before_entry = entry.attributes
      before_lines = entry.payroll_line_items.order(:id).map(&:attributes)

      result = service.preview
      preview = result.preview

      expect(result).to be_ok
      expect(preview.threshold).to eq(60)
      expect(preview.affected_count).to eq(1)
      expect([ preview.old_total_minutes, preview.new_total_minutes ]).to eq([ 135, 90 ])
      expect([ preview.old_total_amount, preview.new_total_amount ]).to eq([ 168.75, 112.5 ])

      expect(entry.attributes).to eq(before_entry)
      expect(entry.payroll_line_items.order(:id).map(&:attributes)).to eq(before_lines)
      expect(PayrollAuditLog.where(action_type: "overtime_recalculated")).to be_empty
    end

    it "removes 0–59 minute days, keeps 60+ days exactly, and moves net salary by the overtime difference only" do
      before         = entry.attributes.slice(*NON_OT_COLUMNS)
      net_before     = entry.net_salary.to_f
      kept_line      = ot_lines.find_by(source_id: day_90.id)
      non_ot_before  = entry.payroll_line_items.where.not(item_type: "overtime").order(:id).map(&:attributes)

      expect(apply!).to be_ok

      fresh = entry
      expect(ot_lines.pluck(:source_id)).to eq([ day_90.id ])
      expect(ot_lines.sole.id).to eq(kept_line.id) # re-used in place, not recreated
      expect(ot_lines.sole.amount.to_f).to eq(112.5)
      expect(fresh.calculated_overtime_minutes).to eq(90)
      expect(fresh.calculated_overtime_pay.to_f).to eq(112.5)
      expect(fresh.total_overtime.to_f).to eq(112.5)
      expect(fresh.net_salary.to_f).to eq((net_before - 56.25).round(2))
      # Salary, allowances, deductions, advances, insurance, status, notes: untouched.
      expect(fresh.attributes.slice(*NON_OT_COLUMNS)).to eq(before)
      expect(fresh.payroll_line_items.where.not(item_type: "overtime").order(:id).map(&:attributes)).to eq(non_ot_before)
      expect(fresh.needs_review).to be(true)
    end

    it "prices 60+ minute days exactly as the existing overtime calculator does" do
      apply!
      expected = Salary::OvertimeCalculator.calculate(record: day_90, daily_rate: 400, multiplier: salary_profile.overtime_multiplier,
                                                      grace_minutes: 60, rule_profile: nil)
      expect(ot_lines.sole.amount.to_f).to eq(expected.overtime_pay)
      expect(entry.calculated_overtime_minutes).to eq(expected.overtime_minutes)
    end

    it "never modifies attendance — including a manual correction, which it reads as-is" do
      # A manual correction after generation: day 1 now has 120 min overtime.
      day_45.update_columns(check_out_at: Time.zone.local(2026, 9, 1, 19, 0), worked_minutes: 600)
      attendance_before = AttendanceRecord.where(user: employee).order(:id).map(&:attributes)

      apply!

      expect(AttendanceRecord.where(user: employee).order(:id).map(&:attributes)).to eq(attendance_before)
      expect(ot_lines.map { |l| [ l.source_id, l.amount.to_f ] }).to eq([ [ day_45.id, 150.0 ], [ day_90.id, 112.5 ] ])
    end

    it "is idempotent: a second run changes nothing and duplicates nothing" do
      apply!
      snapshot = [ entry.attributes.except("updated_at"), entry.payroll_line_items.order(:id).map(&:attributes) ]

      second = service.preview.preview
      expect(second.nothing_to_change?).to be(true)
      expect(service.apply!(expected_digest: second.digest)).to be_ok

      expect([ entry.attributes.except("updated_at"), entry.payroll_line_items.order(:id).map(&:attributes) ]).to eq(snapshot)
    end

    it "records an audit entry with period, thresholds, user, time and affected count" do
      apply!
      log = PayrollAuditLog.where(action_type: "overtime_recalculated").sole
      meta = log.metadata_hash

      expect(log.payroll_period).to eq(period)
      expect(log.actor).to eq(actor)
      expect([ log.from_status, log.to_status ]).to eq(%w[under_review under_review])
      expect(meta).to include("new_threshold_minutes" => 60, "previous_threshold_minutes" => nil,
                              "affected_employee_count" => 1, "old_total_overtime_minutes" => 135,
                              "new_total_overtime_minutes" => 90)
      expect(meta["entries"].sole).to include("user_id" => employee.id, "removed_days" => [ day_45.id ])

      # A later run records what it replaced.
      business.update!(overtime_grace_minutes: 30)
      apply!
      expect(PayrollAuditLog.where(action_type: "overtime_recalculated").order(:id).last.metadata_hash)
        .to include("previous_threshold_minutes" => 60, "new_threshold_minutes" => 30)
      expect(ot_lines.pluck(:source_id)).to eq([ day_45.id, day_90.id ]) # lowering the threshold adds days back
    end

    it "keeps a manager override, clamped to the new calculation and flagged stale" do
      entry.update_columns(overtime_override_mode: "amount", approved_overtime_pay: 150, approved_overtime_minutes: 120,
                           total_overtime: 150, overtime_override_reason: "agreed", overtime_overridden_at: Time.current)
      net_before = entry.net_salary.to_f

      apply!

      fresh = entry
      expect(fresh.overtime_override_mode).to eq("amount")
      expect(fresh.approved_overtime_pay.to_f).to eq(112.5)
      expect(fresh.overtime_override_stale).to be(true)
      expect(fresh.total_overtime.to_f).to eq(112.5)
      expect(fresh.net_salary.to_f).to eq((net_before - 37.5).round(2)) # 150 → 112.5
      expect(fresh.overtime_override_reason).to eq("agreed")
    end

    it "keeps a cancelled overtime line cancelled" do
      line = ot_lines.find_by(source_id: day_90.id)
      line.update_columns(addition_cancelled: true, addition_cancellation_reason: "not approved")

      apply!

      expect(ot_lines.find_by(source_id: day_90.id)).to have_attributes(id: line.id, addition_cancelled: true)
    end

    it "is all-or-nothing: if the audit write fails, nothing is changed" do
      before = [ entry.attributes, entry.payroll_line_items.order(:id).map(&:attributes) ]
      allow(PayrollAuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(PayrollAuditLog.new))

      result = apply!

      expect(result).not_to be_ok
      expect([ entry.attributes, entry.payroll_line_items.order(:id).map(&:attributes) ]).to eq(before)
    end

    it "refuses to apply when the data changed after the preview" do
      digest = service.preview.preview.digest
      day_45.update_columns(worked_minutes: 600) # new 120-minute day appears

      result = service.apply!(expected_digest: digest)

      expect(result.error).to eq(I18n.t("payroll.overtime_recalculation.errors.preview_changed"))
      expect(ot_lines.count).to eq(2)
    end
  end

  describe "period status guard (server side)" do
    before { generate_under_review! }

    %w[draft branch_review_completed finalized paid].each do |status|
      it "rejects a #{status} period and changes nothing" do
        period.update_column(:status, status)
        before = [ entry.attributes, entry.payroll_line_items.order(:id).map(&:attributes) ]

        expect(service.preview.error).to eq(I18n.t("payroll.overtime_recalculation.errors.not_under_review"))
        expect(service.apply!(expected_digest: "anything").error)
          .to eq(I18n.t("payroll.overtime_recalculation.errors.not_under_review"))
        expect([ entry.attributes, entry.payroll_line_items.order(:id).map(&:attributes) ]).to eq(before)
      end
    end

    it "cannot reach another business's period" do
      outsider = create(:user, :accountant, business: create(:business))
      expect { described_class.new(period_id: period.id, actor: outsider).preview }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
