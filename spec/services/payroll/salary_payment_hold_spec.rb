require "rails_helper"

# Salary Payment Hold — a hold blocks PAYMENT only, never payroll calculation.
#
# Fixture: Ahmed (held) and Sara (normal), net 5,000 and 4,000 in each finalized
# period; paying a period goes through Payroll::Approver (finalized → paid), as
# the Mark Paid action does. Required scenarios are numbered as in the spec
# (§8, 1–15); D1–D4 are the owner's decisions of 2026-11-05.
RSpec.describe "Salary Payment Hold" do
  around { |ex| travel_to(Time.zone.local(2026, 11, 10, 12, 0, 0)) { ex.run } }

  let(:business)   { create(:business, working_days_per_month: 26, timezone: "UTC") }
  let(:branch)     { create(:branch, business: business) }
  let!(:accountant) { create(:user, :accountant, business: business) }
  let(:hr) do
    role = business.permission_roles.create!(
      name: "HR", permissions: %w[view_payroll view_salary_payment_holds manage_salary_payment_holds],
      permission_scopes: { "view_payroll" => "business", "view_salary_payment_holds" => "business",
                           "manage_salary_payment_holds" => "business" }
    )
    create(:user, business: business, permission_role: role)
  end
  let(:ahmed) { create(:user, business: business, first_name: "Ahmed", last_name: "Held") }
  let(:sara)  { create(:user, business: business, first_name: "Sara", last_name: "Normal") }

  def finalized_period(month, year: 2026)
    create(:payroll_period, business: business, period_year: year, period_month: month, status: :finalized).tap do |period|
      create(:payroll_entry, payroll_period: period, user: ahmed, base_salary: 5_000, net_salary: 5_000)
      create(:payroll_entry, payroll_period: period, user: sara,  base_salary: 4_000, net_salary: 4_000)
    end
  end

  def pay!(period) = Payroll::Approver.advance(period: period.reload, by: accountant)
  def entry(period, user) = period.payroll_entries.find_by!(user: user)
  def status(period, user) = Payroll::SalaryPaymentStatus.new(period: period.reload, entries: period.payroll_entries).for(entry(period, user))

  def place_hold!(user = ahmed, effective_from: Date.new(2026, 10, 1), actor: hr, reason: "missing_documents")
    Payroll::SalaryHoldCreator.new(actor: actor, user_id: user.id, reason: reason, effective_from: effective_from).call
  end

  def release!(hold, actor: hr, reason: "Documents received")
    Payroll::SalaryHoldReleaser.new(actor: actor, hold_id: hold.id, release_reason: reason).call
  end

  def pay_released!(period, user, actor: accountant, note: "Bank transfer ref 77")
    withholding = entry(period, user).salary_payment_withholdings.live.sole
    Payroll::ReleasedSalaryPayer.new(actor: actor, withholding_id: withholding.id, note: note).call
  end

  describe "placing a hold" do
    it "records who, why, from when, with an audit entry" do
      result = place_hold!
      expect(result).to be_ok
      expect(result.record).to have_attributes(user: ahmed, created_by: hr, reason: "missing_documents",
                                               effective_from: Date.new(2026, 10, 1), released_at: nil)
      log = AuditLog.where(auditable: result.record, action: "salary_hold_created").sole
      expect(log.actor).to eq(hr)
      expect(log.metadata).to include("user_id" => ahmed.id, "reason" => "missing_documents", "effective_from" => "2026-10-01")
    end

    it "13. prevents a second active hold — in the service and in the database" do
      place_hold!
      expect(place_hold!(reason: "other").error).to eq(I18n.t("salary_payment_holds.errors.already_active"))
      expect {
        SalaryPaymentHold.new(business: business, user: ahmed, created_by: hr, reason: "other", notes: "x",
                              effective_from: Date.new(2026, 10, 1)).save!(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "requires a known reason, and notes for Other" do
      expect(place_hold!(reason: "whim")).not_to be_ok
      expect(place_hold!(reason: "other")).not_to be_ok
    end

    it "12. never places a hold on another business's employee" do
      outsider = create(:user)
      expect { place_hold!(outsider) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(SalaryPaymentHold.count).to eq(0)
    end
  end

  describe "payroll calculation is unaffected" do
    let(:shift) { create(:shift, :fixed_time, business: business) }
    let(:october) { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

    before do
      assignment = create(:shift_assignment, user: ahmed, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
      [ 5, 6, 7 ].each do |d|
        date = Date.new(2026, 10, d)
        create(:attendance_record, user: ahmed, branch: branch, shift_assignment: assignment, date: date, work_date: date,
               check_in_at: Time.zone.local(2026, 10, d, 9) + 30.minutes, check_out_at: Time.zone.local(2026, 10, d, 17),
               worked_minutes: 450, late_minutes: 30, early_leave_minutes: 0, status: "late")
      end
      create(:salary_profile, :daily, user: ahmed, base_amount: 400, effective_from: Date.new(2026, 1, 1))
    end

    def calculated
      october.payroll_entries.find_by!(user: ahmed).reload.financial_snapshot
    end

    it "1. calculates the held employee's salary exactly as without a hold" do
      Payroll::EntryCalculator.call(period: october, user: ahmed, business: business)
      without_hold = calculated

      place_hold!
      Payroll::EntryRecalculator.call(user: ahmed, period: october, triggered_by: hr)
      expect(calculated).to eq(without_hold)
      expect(calculated["base_salary"]).to eq(BigDecimal("1200"))
    end

    it "2. keeps the held employee in payroll generation" do
      place_hold!
      period = Payroll::PeriodGenerator.call(business: business, year: 2026, month: 10, generated_by: accountant)
      expect(period.payroll_entries.where(user: ahmed)).to exist
      expect(status(period, ahmed).state).to eq(:on_hold)
    end

    it "9. recalculation neither removes nor bypasses the hold" do
      Payroll::EntryCalculator.call(period: october, user: ahmed, business: business)
      hold = place_hold!.record
      october.update!(status: "under_review")
      plan = Payroll::PeriodRecalculator.new(period_id: october.id, actor: accountant).preview.preview
      Payroll::PeriodRecalculator.new(period_id: october.id, actor: accountant).apply!(expected_digest: plan.digest, reason: "r")

      expect(hold.reload).to be_active
      expect(status(october, ahmed).state).to eq(:on_hold)
    end

    it "10. a salary profile change neither removes the hold nor touches it" do
      hold = place_hold!.record
      Salary::ProfileUpdater.call(user: ahmed, actor: hr,
                                  params: { salary_type: "daily", base_amount: 450, effective_from: Date.new(2026, 10, 20) })
      expect(hold.reload).to have_attributes(released_at: nil, reason: "missing_documents")
      expect(SalaryPaymentHold.active.where(user: ahmed).count).to eq(1)
    end

    it "draft regeneration keeps the hold in force" do
      hold = place_hold!.record
      Payroll::PeriodGenerator.call(business: business, year: 2026, month: 10, generated_by: accountant)
      Payroll::PeriodGenerator.call(business: business, year: 2026, month: 10, generated_by: accountant)
      expect(hold.reload).to be_active
    end
  end

  describe "Mark Paid (D1)" do
    let(:october) { finalized_period(10) }

    it "3. pays everyone else and withholds the held employee's entry — with its figures untouched" do
      hold = place_hold!.record
      before = entry(october, ahmed).attributes

      expect(pay!(october)).to be_success
      expect(october.reload).to be_paid
      expect(status(october, sara).state).to eq(:paid)
      expect(status(october, ahmed).state).to eq(:held)
      expect(status(october, ahmed).held).to eq(BigDecimal("5000"))
      expect(status(october, ahmed).paid).to eq(0)
      expect(entry(october, ahmed).attributes).to eq(before)

      withholding = SalaryPaymentWithholding.sole
      expect(withholding).to have_attributes(salary_payment_hold: hold, withheld_by: accountant, disbursed_at: nil)
      log = october.payroll_audit_logs.where(action_type: "paid").sole
      expect(log.metadata_hash).to eq("withheld_entry_ids" => [ entry(october, ahmed).id ], "withheld_total" => "5000.0")
      expect(AuditLog.where(auditable: hold, action: "salary_payment_withheld").count).to eq(1)
    end

    it "pays a period with no hold exactly as before (no withholding, no metadata)" do
      pay!(october)
      expect(SalaryPaymentWithholding.count).to eq(0)
      expect(october.payroll_audit_logs.where(action_type: "paid").sole.metadata).to be_nil
    end

    it "does not withhold for a hold effective after the period" do
      place_hold!(effective_from: Date.new(2026, 11, 1))
      pay!(october)
      expect(status(october, ahmed).state).to eq(:paid)
    end

    it "does not withhold an entry with nothing to pay" do
      entry(october, ahmed).update_columns(net_salary: 0)
      place_hold!
      pay!(october)
      expect(SalaryPaymentWithholding.count).to eq(0)
    end

    it "D2. settles advance deductions as always; the held amount is the net after recovery" do
      request = create(:employee_request, :salary_advance, :approved, user: ahmed, amount: 1_000)
      Requests::Approver.pay(request: request, paid_by: accountant)
      advance = Advance.find_by!(user: ahmed)
      held_entry = entry(october, ahmed)
      held_entry.payroll_line_items.create!(item_type: "advance_deduction", amount: -1_000, source_type: "Advance",
                                            source_id: advance.id, description: "Advance", review_status: "approved")
      held_entry.update_columns(advances_deducted: 1_000, net_salary: 4_000)
      place_hold!

      pay!(october)
      expect(advance.reload).to be_fully_repaid
      expect(status(october, ahmed).held).to eq(BigDecimal("4000"))
    end

    it "12. ignores another business's holds" do
      other = create(:salary_payment_hold) # another business, another employee
      place_hold!
      pay!(october)
      expect(SalaryPaymentWithholding.pluck(:salary_payment_hold_id)).not_to include(other.id)
    end
  end

  describe "continuation across periods" do
    it "5./6. stays active and withholds every period until released" do
      hold = place_hold!.record
      periods = [ 10, 11, 12 ].map { |m| finalized_period(m) } + [ finalized_period(1, year: 2027) ]
      periods.each { |p| pay!(p) }

      expect(hold.reload).to be_active
      expect(hold.salary_payment_withholdings.outstanding.count).to eq(4)
      expect(periods.map { |p| status(p, ahmed).state }).to all(eq(:held))
      expect(periods.map { |p| status(p, sara).state }).to all(eq(:paid))
      expect(periods.sum { |p| status(p, ahmed).held }).to eq(BigDecimal("20000"))
    end
  end

  describe "release" do
    let(:october)  { finalized_period(10) }
    let(:november) { finalized_period(11) }
    let!(:hold) { place_hold!.record }

    before { [ october, november ].each { |p| pay!(p) } }

    it "records who released it, when and why, audited" do
      expect(release!(hold)).to be_ok
      expect(hold.reload).to have_attributes(released_by: hr, release_reason: "Documents received")
      expect(hold.released_at).to be_within(1.second).of(Time.current)
      expect(AuditLog.where(auditable: hold, action: "salary_hold_released").sole.metadata)
        .to include("outstanding_withholding_ids" => hold.salary_payment_withholdings.order(:id).ids)
    end

    it "7./8. pays nothing and recalculates nothing: the held amounts become payable and stay intact" do
      before = [ october, november ].flat_map { |p| p.payroll_entries.map(&:attributes) }
      release!(hold)

      expect(SalaryPaymentWithholding.disbursed.count).to eq(0)
      expect([ october, november ].map { |p| status(p, ahmed).state }).to eq(%i[released released])
      expect([ october, november ].sum { |p| status(p, ahmed).payable }).to eq(BigDecimal("10000"))
      expect([ october, november ].flat_map { |p| p.reload.payroll_entries.map(&:attributes) }).to eq(before)
      expect([ october.reload, november.reload ].map(&:status)).to eq(%w[paid paid])
    end

    it "releases once; a second release is refused" do
      release!(hold)
      expect(release!(hold).error).to eq(I18n.t("salary_payment_holds.errors.already_released"))
    end

    it "14. keeps the hold and its history after release; holds are never deleted" do
      release!(hold)
      expect(SalaryPaymentHold.where(user: ahmed).sole).to be_released
      expect { hold.reload.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { SalaryPaymentWithholding.first.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(hold.reload.update(release_reason: "changed")).to be(false)
      expect(hold.reload.update(reason: "other")).to be(false)
    end

    it "a new hold may be placed after the release (the history keeps both)" do
      release!(hold)
      expect(place_hold!(reason: "pending_hr_review")).to be_ok
      expect(SalaryPaymentHold.where(user: ahmed).count).to eq(2)
    end
  end

  describe "Pay Released Salary (D5)" do
    let(:october) { finalized_period(10) }
    let!(:hold) { place_hold!.record }

    before { pay!(october) }

    it "3. is refused while the hold is active, and the attempt is audited" do
      result = pay_released!(october, ahmed)
      expect(result.error).to eq(I18n.t("salary_payment_holds.pay_released.errors.hold_active",
                                        reason: I18n.t("salary_payment_holds.reasons.missing_documents")))
      expect(SalaryPaymentWithholding.sole).not_to be_disbursed
      expect(AuditLog.where(auditable: hold, action: "salary_payment_blocked").sole.metadata)
        .to include("path" => "pay_released_salary")
    end

    it "4. records the payment after the release — once, with who, when and how, audited" do
      release!(hold)
      expect(pay_released!(october, ahmed)).to be_ok

      withholding = SalaryPaymentWithholding.sole
      expect(withholding).to have_attributes(disbursed_by: accountant, disbursement_note: "Bank transfer ref 77")
      expect(status(october, ahmed).state).to eq(:disbursed)
      expect(status(october, ahmed).paid).to eq(BigDecimal("5000"))
      expect(AuditLog.where(auditable: hold, action: "released_salary_paid").sole.metadata)
        .to include("amount" => "5000.0", "withholding_id" => withholding.id)
      expect(pay_released!(october, ahmed).error).to eq(I18n.t("salary_payment_holds.pay_released.errors.already_disbursed"))
    end

    it "requires a note on how it was paid" do
      release!(hold)
      expect(pay_released!(october, ahmed, note: " ").error).to eq(I18n.t("salary_payment_holds.pay_released.errors.note_required"))
    end

    it "12. never pays another business's withholding" do
      release!(hold)
      outsider = create(:user, :accountant)
      withholding = SalaryPaymentWithholding.sole
      expect {
        Payroll::ReleasedSalaryPayer.new(actor: outsider, withholding_id: withholding.id, note: "x").call
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "the bank-transfer file" do
    let(:october) { finalized_period(10) }

    before do
      [ ahmed, sara ].each { |u| u.update_columns(identity_card_number: "ID#{u.id}") }
      place_hold!
    end

    def exported(period) = Reports::BankTransferCsvExporter.new(period: period.reload).rows.map(&:full_name)

    it "leaves the held employee out before and after Mark Paid, and after the release until paid in WorkPulse" do
      expect(exported(october)).to eq([ sara.full_name ])
      pay!(october)
      expect(exported(october)).to eq([ sara.full_name ])
      expect(Reports::BankTransferCsvExporter.new(period: october).summary).to include(held_employees: 1, held_amount: 5_000)

      release!(SalaryPaymentHold.sole)
      expect(exported(october)).to eq([ sara.full_name ])
    end
  end

  describe "salary advances (D2)" do
    let(:request) { create(:employee_request, :salary_advance, :approved, user: ahmed, amount: 800) }

    it "3. refuses to pay out an advance while the hold is active, and audits the attempt" do
      place_hold!
      result = Requests::Approver.pay(request: request, paid_by: accountant)

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("salary_payment_holds.errors.advance_blocked",
                                        reason: I18n.t("salary_payment_holds.reasons.missing_documents")))
      expect(request.reload.status).to eq("approved")
      expect(Advance.where(user: ahmed)).to be_empty
      expect(AuditLog.where(auditable: request, action: "pay_blocked").count).to eq(1)
    end

    it "refuses it in a bulk payment too, paying the others" do
      place_hold!
      other = create(:employee_request, :salary_advance, :approved, user: sara, amount: 300)
      result = Requests::BulkPaymentService.call(requests: [ request, other ], paid_by: accountant)

      expect(result.paid).to eq([ other ])
      expect(result.skipped.map(&:request)).to eq([ request ])
      expect(Advance.where(user: ahmed)).to be_empty
    end

    it "pays it after the release" do
      hold = place_hold!.record
      release!(hold)
      expect(Requests::Approver.pay(request: request, paid_by: accountant)).to be_success
    end

    it "blocks even when the hold is effective in the future (any active hold)" do
      place_hold!(effective_from: Date.new(2027, 1, 1))
      expect(Requests::Approver.pay(request: request, paid_by: accountant)).not_to be_success
    end
  end

  describe "an already-paid cash incentive during a hold (D3)" do
    let(:november) { create(:payroll_period, business: business, period_year: 2026, period_month: 11) }
    let!(:hold) { place_hold!.record }

    def incentive(paid_at:)
      PayrollAdjustment.new(business: business, user: ahmed, created_by: accountant, payroll_period: november,
                            period_month: 11, period_year: 2026, adjustment_type: "cash_incentive", amount: 200,
                            reason: "Cash bonus handed over at the branch", already_paid: true,
                            payment_method: "cash", paid_at: paid_at, review_status: "pending_review")
    end

    it "is recorded as a historical payment with its date, audited with the hold" do
      adjustment = incentive(paid_at: Time.zone.local(2026, 11, 8, 15))
      expect(adjustment.save).to be(true)
      log = AuditLog.where(auditable: adjustment, action: "already_paid_recorded_during_salary_hold").sole
      expect(log.metadata).to include("salary_payment_hold_id" => hold.id, "amount" => "200.0", "payment_method" => "cash")
    end

    it "requires the actual payment date, never in the future" do
      expect(incentive(paid_at: nil).save).to be(false)
      expect(incentive(paid_at: 1.day.from_now).save).to be(false)
    end

    it "neither releases the hold nor makes held amounts payable" do
      october = finalized_period(10)
      pay!(october)
      incentive(paid_at: 1.day.ago).save!
      expect(hold.reload).to be_active
      expect(status(october, ahmed).state).to eq(:held)
    end
  end

  describe "reopening a paid period (D4)" do
    let(:october) { finalized_period(10) }
    let!(:hold) { place_hold!.record }

    before { pay!(october) }

    def reopen! = Payroll::Reopener.call(period: october.reload, by: accountant, reason: "Bank file error")

    it "voids the outstanding withholdings with the reason; the next Mark Paid decides again" do
      expect(reopen!).to be_success
      withholding = SalaryPaymentWithholding.sole
      expect(withholding).to have_attributes(voided_by: accountant, void_reason: "Bank file error")
      expect(october.reload).to be_finalized
      expect(october.payroll_audit_logs.where(action_type: "reopened").sole.metadata_hash)
        .to include("voided_withholding_ids" => [ withholding.id ])

      release!(hold)
      pay!(october)
      expect(status(october, ahmed).state).to eq(:paid)
    end

    it "re-withholds when paid again while the hold is still active" do
      reopen!
      pay!(october)
      expect(SalaryPaymentWithholding.live.count).to eq(1)
      expect(SalaryPaymentWithholding.count).to eq(2)
      expect(status(october, ahmed).state).to eq(:held)
    end

    it "is refused once a released withholding was paid — financial history is kept" do
      release!(hold)
      pay_released!(october, ahmed)

      result = reopen!
      expect(result.error).to eq(I18n.t("salary_payment_holds.errors.reopen_disbursed"))
      expect(october.reload).to be_paid
      expect(SalaryPaymentWithholding.sole).to have_attributes(voided_at: nil)
    end
  end
end
