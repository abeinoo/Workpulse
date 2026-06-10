# spec/scenarios/multi_branch_payroll_cycle_spec.rb
#
# End-to-end scenario: Al-Noor Group — March 2025 payroll cycle
#
# Two branches (Riyadh + Jeddah), five salaried employees with mixed deductions:
#
#   sara   (Riyadh) monthly  9 900  22/22 present                  → net  9 900
#   farid  (Riyadh) monthly  6 600  20/22 present, 1 late (−75)    → net  5 325
#                            advance 600 remaining                        (−675 deductions, −600 advance)
#   layla  (Riyadh) monthly  4 400  22/22 present                  → net  4 000
#                            obligation 400 SAR/month                     (−400 obligation)
#   noor   (Jeddah) monthly  8 800  22/22 present, bonus 400       → net  9 200
#   hassan (Jeddah) monthly  5 500  19/22 present (3 absent)       → net  4 750
#                                                                          (−750 absence)
#
# Total net payroll = 33 175
#
# Workflow tested:
#   generate → submit → dual branch review → finalize → paid
#
# Also tests: regeneration after attendance edit, advance settlement, scope isolation.

require "rails_helper"

RSpec.describe "Multi-branch payroll cycle — Al-Noor Group", type: :service do
  # ── Business ────────────────────────────────────────────────────────────────

  let(:business) { create(:business, working_days_per_month: 22) }

  # ── Branches ────────────────────────────────────────────────────────────────

  let(:riyadh) { create(:branch, business: business) }
  let(:jeddah) { create(:branch, business: business) }

  # Branch managers — no salary profiles, so PeriodGenerator produces no entry for them.
  let!(:admin)  { create(:user, :owner,  business: business) }
  let!(:khalid) { create(:user, business: business) }
  let!(:saeed)  { create(:user, business: business) }

  let(:manager_role) do
    create(:permission_role, business: business,
           permissions: %w[view_payroll view_employees view_attendance view_requests approve_requests],
           permission_scopes: {})
  end

  before do
    riyadh.update!(branch_manager_id: khalid.id)
    jeddah.update!(branch_manager_id: saeed.id)
    # Permission-driven: branch managers need view_payroll (or relevant) permissions.
    # Scope still resolved by branch_manager_id relationship via EmployeeScope.
    khalid.update_column(:permission_role_id, manager_role.id)
    saeed.update_column(:permission_role_id, manager_role.id)
  end

  # ── Shared shift (09:00–17:00) with late-arrival penalty rule ───────────────

  let!(:shift) { create(:shift, :fixed_time, business: business) }

  # 25% of daily rate per late occurrence (triggered after 15 min threshold)
  let!(:late_rule) do
    create(:penalty_rule, shift: shift,
           rule_type:         "late_arrival",
           deduction_type:    "percentage_of_daily",
           threshold_minutes: 15,
           deduction_value:   25)
  end

  # ── Riyadh employees ────────────────────────────────────────────────────────

  # sara: monthly 9 900, all 22 days present → net = 9 900
  let!(:sara)         { create(:user, business: business) }
  let!(:sara_salary)  { create(:salary_profile, :monthly, user: sara, base_amount: 9_900.0, effective_from: Date.new(2024, 1, 1)) }
  let!(:sara_sa)      { create(:shift_assignment, user: sara, branch: riyadh, shift: shift, effective_from: Date.new(2024, 1, 1)) }

  # farid: monthly 6 600 (daily = 300), 20/22 days, day 5 late 60 min, advance 600 → net = 5 325
  let!(:farid)        { create(:user, business: business) }
  let!(:farid_salary) { create(:salary_profile, :monthly, user: farid, base_amount: 6_600.0, effective_from: Date.new(2024, 1, 1)) }
  let!(:farid_sa)     { create(:shift_assignment, user: farid, branch: riyadh, shift: shift, effective_from: Date.new(2024, 1, 1)) }

  let!(:farid_advance) do
    req = create(:employee_request, :salary_advance, :approved,
                 user: farid, amount: 600.0,
                 requested_for_date: Date.new(2024, 12, 1))
    create(:advance, user: farid, employee_request: req,
           total_amount: 600.0, remaining_amount: 600.0,
           issued_at: Date.new(2024, 12, 15), status: :active)
  end

  # layla: monthly 4 400 (daily = 200), all 22 days present, obligation 400/month → net = 4 000
  let!(:layla)           { create(:user, business: business) }
  let!(:layla_salary)    { create(:salary_profile, :monthly, user: layla, base_amount: 4_400.0, effective_from: Date.new(2024, 1, 1)) }
  let!(:layla_sa)        { create(:shift_assignment, user: layla, branch: riyadh, shift: shift, effective_from: Date.new(2024, 1, 1)) }
  let!(:layla_obligation) do
    create(:employee_obligation, user: layla, business: business, created_by: admin,
           total_amount: 3_000.0, remaining_amount: 3_000.0,
           installment_amount: 400.0,
           start_month: 3, start_year: 2025,
           status: "active", auto_deduct: true)
  end

  # ── Jeddah employees ────────────────────────────────────────────────────────

  # noor: monthly 8 800, all 22 days present, approved bonus 400 → net = 9 200
  let!(:noor)        { create(:user, business: business) }
  let!(:noor_salary) { create(:salary_profile, :monthly, user: noor, base_amount: 8_800.0, effective_from: Date.new(2024, 1, 1)) }
  let!(:noor_sa)     { create(:shift_assignment, user: noor, branch: jeddah, shift: shift, effective_from: Date.new(2024, 1, 1)) }

  let!(:noor_bonus) do
    PayrollAdjustment.create!(
      business:        business,
      user:            noor,
      created_by:      admin,
      period_month:    3,
      period_year:     2025,
      adjustment_type: "cash_incentive",
      amount:          400.0,
      reason:          "Q1 performance bonus",
      review_status:   "approved"
    )
  end

  # hassan: monthly 5 500 (daily = 250), 19/22 present (3 absent) → net = 4 750
  let!(:hassan)        { create(:user, business: business) }
  let!(:hassan_salary) { create(:salary_profile, :monthly, user: hassan, base_amount: 5_500.0, effective_from: Date.new(2024, 1, 1)) }
  let!(:hassan_sa)     { create(:shift_assignment, user: hassan, branch: jeddah, shift: shift, effective_from: Date.new(2024, 1, 1)) }

  # ── Attendance records for March 2025 ───────────────────────────────────────

  def att(user, sa, day, status: "present", late: 0, early_leave: 0, worked: 480)
    date = Date.new(2025, 3, day)
    create(:attendance_record,
           user:                user,
           shift_assignment:    sa,
           date:                date,
           work_date:           date,
           check_in_at:         Time.zone.local(2025, 3, day, 9, 0) + late.minutes,
           check_out_at:        Time.zone.local(2025, 3, day, 17, 0) - early_leave.minutes,
           worked_minutes:      worked,
           late_minutes:        late,
           early_leave_minutes: early_leave,
           status:              status)
  end

  before do
    # sara — 22 present
    (1..22).each { |d| att(sara, sara_sa, d) }

    # farid — 20 present (days 1–20), day 5 is late 60 min; days 21–22 = absent (no records)
    (1..4).each  { |d| att(farid, farid_sa, d) }
    att(farid, farid_sa, 5, status: "late", late: 60, worked: 420)
    (6..20).each { |d| att(farid, farid_sa, d) }

    # layla — 22 present
    (1..22).each { |d| att(layla, layla_sa, d) }

    # noor — 22 present
    (1..22).each { |d| att(noor, noor_sa, d) }

    # hassan — 19 present (days 1–19); days 20–22 = absent (no records)
    (1..19).each { |d| att(hassan, hassan_sa, d) }
  end

  # ── Period generator helper ──────────────────────────────────────────────────

  def generate
    Payroll::PeriodGenerator.call(
      business:     business,
      year:         2025,
      month:        3,
      generated_by: admin
    )
  end

  # ============================================================================
  # Layer 1: Period generation — math, line items, components
  # ============================================================================

  describe "period generation — March 2025" do
    let!(:period) { generate }

    # ── Entry counts ────────────────────────────────────────────────────────

    it "creates exactly 5 entries (one per employee with a salary profile)" do
      expect(period.payroll_entries.count).to eq(5)
    end

    it "creates no entry for khalid (branch manager with no salary profile)" do
      expect(period.payroll_entries.where(user: khalid)).to be_empty
    end

    it "creates no entry for saeed (branch manager with no salary profile)" do
      expect(period.payroll_entries.where(user: saeed)).to be_empty
    end

    # ── Individual net salaries ──────────────────────────────────────────────

    it "computes sara's net salary as 9 900 (full month, no deductions)" do
      expect(period.payroll_entries.find_by(user: sara).net_salary).to eq(9_900.0)
    end

    it "computes farid's net salary as 5 325 (base − 675 deductions − 600 advance)" do
      # 6600 − (600 absence + 75 late) − 600 advance = 5 325
      expect(period.payroll_entries.find_by(user: farid).net_salary).to eq(5_325.0)
    end

    it "computes layla's net salary as 4 000 (base − 400 obligation installment)" do
      expect(period.payroll_entries.find_by(user: layla).net_salary).to eq(4_000.0)
    end

    it "computes noor's net salary as 9 200 (base + 400 performance bonus)" do
      expect(period.payroll_entries.find_by(user: noor).net_salary).to eq(9_200.0)
    end

    it "computes hassan's net salary as 4 750 (base − 750 absence deduction)" do
      # 5500 − (3 × 250) = 4 750
      expect(period.payroll_entries.find_by(user: hassan).net_salary).to eq(4_750.0)
    end

    it "business total net payroll is 33 175" do
      expect(period.payroll_entries.sum(:net_salary)).to eq(33_175.0)
    end

    # ── Attendance component verification ────────────────────────────────────

    it "farid has 20 days_worked and 2 absent days" do
      entry = period.payroll_entries.find_by(user: farid)
      expect(entry.days_worked).to eq(20)
      expect(entry.working_days - entry.days_worked).to eq(2)
    end

    it "hassan has 19 days_worked and 3 absent days" do
      entry = period.payroll_entries.find_by(user: hassan)
      expect(entry.days_worked).to eq(19)
      expect(entry.working_days - entry.days_worked).to eq(3)
    end

    it "farid has a late_penalty line item of −75 SAR (25% of daily rate 300)" do
      item = period.payroll_entries.find_by(user: farid)
                   .payroll_line_items.find_by(item_type: "late_penalty")
      expect(item).to be_present
      expect(item.amount).to eq(-75.0)
    end

    it "farid has an advance_deduction line item of −600 SAR" do
      item = period.payroll_entries.find_by(user: farid)
                   .payroll_line_items.find_by(item_type: "advance_deduction")
      expect(item).to be_present
      expect(item.amount).to eq(-600.0)
    end

    it "farid's advance is not yet repaid at generation time (repayment happens at paid)" do
      expect(farid_advance.reload.remaining_amount).to eq(600.0)
      expect(farid_advance.reload.status).to eq("active")
    end

    it "layla's obligation balance is decremented to 2 600 after generation" do
      expect(layla_obligation.reload.remaining_amount).to eq(2_600.0)
    end

    it "noor has a cash_incentive line item of +400 SAR" do
      item = period.payroll_entries.find_by(user: noor)
                   .payroll_line_items.find_by(item_type: "cash_incentive")
      expect(item).to be_present
      expect(item.amount).to eq(400.0)
    end

    it "hassan has an absence deduction of −750 SAR (3 days × 250)" do
      item = period.payroll_entries.find_by(user: hassan)
                   .payroll_line_items.find_by(item_type: "manual_adjustment")
      expect(item).to be_present
      expect(item.amount).to eq(-750.0)
    end
  end

  # ============================================================================
  # Layer 2: Full workflow cycle (nested state machine)
  # ============================================================================

  describe "full workflow cycle" do
    let!(:period) { generate }

    describe "step 1: submit for review" do
      let!(:submit_result) { Payroll::SubmitForReview.call(period: period, by: admin) }

      it "succeeds" do
        expect(submit_result.success?).to be true
      end

      it "transitions period to under_review" do
        expect(period.reload.status).to eq("under_review")
      end

      it "creates a branch review slot for riyadh" do
        expect(period.payroll_period_branch_reviews.where(branch: riyadh)).to exist
      end

      it "creates a branch review slot for jeddah" do
        expect(period.payroll_period_branch_reviews.where(branch: jeddah)).to exist
      end

      it "both branch review slots start as pending" do
        statuses = period.payroll_period_branch_reviews.pluck(:status)
        expect(statuses).to all(eq("pending"))
      end

      it "assigns khalid as the riyadh reviewer" do
        review = period.payroll_period_branch_reviews.find_by(branch: riyadh)
        expect(review.reviewer).to eq(khalid)
      end

      it "assigns saeed as the jeddah reviewer" do
        review = period.payroll_period_branch_reviews.find_by(branch: jeddah)
        expect(review.reviewer).to eq(saeed)
      end

      describe "step 2: khalid completes riyadh branch review" do
        let!(:riyadh_result) do
          Payroll::BranchReviewCompleter.call(
            period: period, branch: riyadh, reviewer: khalid, notes: "All good"
          )
        end

        it "succeeds" do
          expect(riyadh_result.success?).to be true
        end

        it "marks riyadh review as completed" do
          review = period.payroll_period_branch_reviews.find_by(branch: riyadh)
          expect(review.reload.status).to eq("completed")
        end

        it "leaves period in under_review because jeddah review is still pending" do
          expect(period.reload.status).to eq("under_review")
        end

        it "jeddah review is still pending" do
          review = period.payroll_period_branch_reviews.find_by(branch: jeddah)
          expect(review.reload.status).to eq("pending")
        end

        describe "step 3: saeed completes jeddah branch review" do
          let!(:jeddah_result) do
            Payroll::BranchReviewCompleter.call(
              period: period, branch: jeddah, reviewer: saeed, notes: "Approved"
            )
          end

          it "succeeds" do
            expect(jeddah_result.success?).to be true
          end

          it "marks jeddah review as completed" do
            review = period.payroll_period_branch_reviews.find_by(branch: jeddah)
            expect(review.reload.status).to eq("completed")
          end

          it "auto-advances period to branch_review_completed when all branches are done" do
            expect(period.reload.status).to eq("branch_review_completed")
          end

          it "logs a branch_review_completed audit event" do
            log = PayrollAuditLog.find_by(
              payroll_period: period,
              action_type:    "branch_review_completed"
            )
            expect(log).to be_present
            expect(log.from_status).to eq("under_review")
            expect(log.to_status).to eq("branch_review_completed")
          end

          describe "step 4: admin finalizes the period" do
            let!(:finalize_result) { Payroll::Approver.advance(period: period, by: admin) }

            it "succeeds" do
              expect(finalize_result.success?).to be true
            end

            it "transitions period to finalized" do
              expect(period.reload.status).to eq("finalized")
            end

            it "records finalized_by as admin" do
              expect(period.reload.finalized_by).to eq(admin)
            end

            it "logs a finalized audit event with actor = admin" do
              log = PayrollAuditLog.find_by(payroll_period: period, action_type: "finalized")
              expect(log).to be_present
              expect(log.actor).to eq(admin)
            end

            describe "step 5: admin marks period as paid" do
              let!(:paid_result) { Payroll::Approver.advance(period: period, by: admin) }

              it "succeeds" do
                expect(paid_result.success?).to be true
              end

              it "transitions period to paid" do
                expect(period.reload.status).to eq("paid")
              end

              it "settles farid's advance — remaining_amount drops to 0" do
                expect(farid_advance.reload.remaining_amount).to eq(0.0)
              end

              it "settles farid's advance — status becomes fully_repaid" do
                expect(farid_advance.reload.status).to eq("fully_repaid")
              end

              it "logs a paid audit event" do
                log = PayrollAuditLog.find_by(payroll_period: period, action_type: "paid")
                expect(log).to be_present
              end
            end
          end
        end
      end
    end
  end

  # ============================================================================
  # Layer 3: Regeneration after attendance edit
  # ============================================================================

  describe "regeneration after attending an extra day" do
    # First run: 20 days for farid (days 21-22 absent) → net = 5 325
    let(:period) { generate }

    before do
      period   # force evaluation — first generation with 20 records for farid
      att(farid, farid_sa, 21)  # farid attends day 21 (was absent)
      generate  # regenerates the draft period — returns updated period
    end

    it "farid's days_worked increases from 20 to 21" do
      expect(period.reload.payroll_entries.find_by(user: farid).days_worked).to eq(21)
    end

    it "farid has only 1 absent day after the edit" do
      entry = period.reload.payroll_entries.find_by(user: farid)
      expect(entry.working_days - entry.days_worked).to eq(1)
    end

    it "farid's total_deductions decreases from 675 to 375 (300 absence + 75 late)" do
      entry = period.reload.payroll_entries.find_by(user: farid)
      expect(entry.total_deductions).to eq(375.0)
    end

    it "farid's net salary increases from 5 325 to 5 625" do
      # 6600 − 375 − 600 = 5 625
      expect(period.reload.payroll_entries.find_by(user: farid).net_salary).to eq(5_625.0)
    end

    it "sara's net salary is unaffected" do
      expect(period.reload.payroll_entries.find_by(user: sara).net_salary).to eq(9_900.0)
    end

    it "layla's obligation balance is the same after regeneration (snapshot restored, then re-deducted)" do
      # PeriodGenerator destroys ObligationDeductions first (restores balance to 3 000),
      # then re-runs EntryCalculator which deducts 400 again → still 2 600.
      expect(layla_obligation.reload.remaining_amount).to eq(2_600.0)
    end

    it "the total payroll increases by 300 (farid's restored absent day)" do
      # Was 33 175; farid's net is now 5 625 (+300)
      expect(period.reload.payroll_entries.sum(:net_salary)).to eq(33_475.0)
    end
  end

  # ============================================================================
  # Layer 4: Scope isolation — managers see only their branch's entries
  # ============================================================================

  describe "scope isolation" do
    let!(:period) { generate }

    def entry_scope(user)
      PayrollEntryPolicy::Scope.new(user, PayrollEntry.all).resolve
                               .where(payroll_period: period)
    end

    it "admin (business owner) can see all 5 entries" do
      expect(entry_scope(admin).count).to eq(5)
    end

    it "khalid (riyadh branch manager) sees all 3 riyadh employees" do
      visible = entry_scope(khalid).pluck(:user_id)
      expect(visible).to include(sara.id, farid.id, layla.id)
    end

    it "khalid cannot see jeddah employees (noor, hassan)" do
      visible = entry_scope(khalid).pluck(:user_id)
      expect(visible).not_to include(noor.id, hassan.id)
    end

    it "saeed (jeddah branch manager) sees both jeddah employees" do
      visible = entry_scope(saeed).pluck(:user_id)
      expect(visible).to include(noor.id, hassan.id)
    end

    it "saeed cannot see riyadh employees (sara, farid, layla)" do
      visible = entry_scope(saeed).pluck(:user_id)
      expect(visible).not_to include(sara.id, farid.id, layla.id)
    end
  end
end
