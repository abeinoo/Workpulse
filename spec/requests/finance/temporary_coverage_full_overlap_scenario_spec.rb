require "rails_helper"

# The exact critical scenario: an employee's regular assignment and a
# temporary_coverage assignment share the IDENTICAL clock hours (3 PM-11 PM)
# on different branches, on the coverage date. This must be allowed — the
# whole point of coverage is that it supersedes the regular assignment for
# its window, not that the two coexist in fact. Every downstream system
# (attendance, Daily Reconciliation, cashier handover, custody numbers, POS,
# deposits) must consistently resolve to the covering branch for that date,
# and the regular assignment must remain completely untouched.
RSpec.describe "Temporary coverage — full shift-hour overlap with the regular assignment", type: :request do
  let(:business) { create(:business, timezone: "UTC") }
  let(:home)     { create(:branch, business: business, name: "Shubra") }
  let(:covering) { create(:branch, business: business, name: "Nasr City") }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  # Same 3 PM-11 PM shift definition used for BOTH the regular and the
  # coverage assignment, on purpose — this is the exact case a naive
  # "no overlapping shift time" validation would (wrongly) reject.
  let(:evening_shift) do
    create(:shift, :fixed_time, business: business, name: "Evening Shift",
           start_time: Time.zone.parse("15:00"), end_time: Time.zone.parse("23:00"))
  end

  def role_with(*perms)
    business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
  end

  let(:admin) do
    role = role_with("assign_shifts", "view_shifts", "view_employees", "view_daily_reconciliation")
    create(:user, business: business, first_name: "Manager").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:ahmed) do
    role = role_with("view_daily_reconciliation", "close_till_session", "create_till_deposit", "accept_till_handover")
    create(:user, business: business, first_name: "Ahmed").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:regular_assignment) do
    create(:shift_assignment, user: ahmed, shift: evening_shift, branch: home,
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end

  let(:aug19) { Date.new(2026, 8, 19) }
  let(:aug20) { Date.new(2026, 8, 20) }
  let(:aug21) { Date.new(2026, 8, 21) }

  # ── Test 1 — creation via the actual admin form/controller ────────────────
  describe "Test 1: creating the temporary coverage assignment (admin form)" do
    before { sign_in admin }

    it "lets a manager with assign_shifts create the coverage assignment through the real form, alongside the untouched regular one" do
      expect {
        post shift_assignments_path, params: {
          shift_assignment: {
            user_id: ahmed.id, shift_id: evening_shift.id, branch_id: covering.id,
            effective_from: aug20.iso8601, effective_to: aug20.iso8601,
            assignment_kind: "temporary_coverage", reason: "Covering another employee"
          }
        }
      }.to change(ShiftAssignment, :count).by(1)

      expect(response).to redirect_to(shift_assignments_path)

      coverage = ShiftAssignment.temporary_coverage.find_by(user: ahmed, branch: covering)
      expect(coverage).to be_present
      expect(coverage.reason).to eq("Covering another employee")
      expect(coverage.effective_from).to eq(aug20)
      expect(coverage.effective_to).to eq(aug20)
      expect(coverage.shift).to eq(evening_shift)
      expect(coverage.branch).to eq(covering)

      # Both assignments coexist — creating the coverage assignment did not
      # touch the regular one.
      expect(ShiftAssignment.where(user: ahmed).count).to eq(2)
      expect(regular_assignment.reload.branch).to eq(home)
    end
  end

  # From here on, the coverage assignment is set up directly (already proven
  # creatable above via Test 1) so each scenario can focus on its own
  # downstream check. Scoped to its own nested group (not the outer describe)
  # so it doesn't leak into Test 1, which tests creating this exact record.
  describe "with an existing coverage assignment" do
    let!(:coverage_assignment) do
      create(:shift_assignment, user: ahmed, shift: evening_shift, branch: covering,
             assignment_kind: "temporary_coverage", effective_from: aug20, effective_to: aug20,
             reason: "Covering another employee")
    end

    # ── Test 2 — resolver priority ─────────────────────────────────────────────
    describe "Test 2: effective branch/shift-assignment resolution on the coverage date" do
      it "resolves to Nasr City / the coverage assignment during the coverage shift" do
        resolved = Shifts::AssignmentResolver.for(user: ahmed, date: aug20, time: Time.zone.parse("18:00"))
        expect(resolved).to eq(coverage_assignment)
        expect(resolved.branch).to eq(covering)
      end

      it "resolves to Shubra / the regular assignment outside the coverage date" do
        resolved = Shifts::AssignmentResolver.for(user: ahmed, date: aug21)
        expect(resolved).to eq(regular_assignment)
        expect(resolved.branch).to eq(home)
      end
    end

    # ── Test 3 — regular assignment is completely unchanged ───────────────────
    describe "Test 3: the regular assignment is untouched" do
      it "still exists with every original attribute after the coverage assignment is created" do
        regular_assignment.reload

        expect(regular_assignment).to be_persisted
        expect(regular_assignment.branch).to eq(home)
        expect(regular_assignment.shift).to eq(evening_shift)
        expect(regular_assignment.effective_from).to eq(Date.new(2026, 1, 1))
        expect(regular_assignment.effective_to).to be_nil
        expect(regular_assignment.assignment_kind).to eq("regular")
      end
    end

    # ── Test 4 — Daily Reconciliation inclusion ────────────────────────────────
    describe "Test 4: Ahmed appears in the covering branch's Daily Reconciliation" do
      let!(:nasr_dr) do
        dr = DailyReconciliation.create!(branch: covering, business: business, state: "closed",
                                          opened_at: aug20.to_time + 15.hours, closed_at: aug20.to_time + 23.hours,
                                          business_date: aug20)
        TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                                   payment_method_name: cash_pm.name, collected_amount: 10_500, refund_amount: 500)
        h = TillHandover.create!(daily_reconciliation: dr, from_user: ahmed, self_deposit: true,
                                  created_at: aug20.to_time + 23.hours)
        TillHandoverAmount.create!(till_handover: h, payment_method: cash_pm,
                                    payment_method_name: cash_pm.name, collected_amount: 10_500, refund_amount: 500)
        dr
      end

      it "includes Ahmed exactly like any other employee assigned to that branch that day" do
        summaries = Finance::EmployeeReconciliationSummarizer.new(nasr_dr).summaries
        ahmed_summary = summaries.find { |s| s.user&.id == ahmed.id }

        expect(ahmed_summary).to be_present
        expect(ahmed_summary.grand_total).to eq(10_000) # 10,500 collected - 500 refund
      end
    end

    # ── Test 5 — Cashier Handover / Cash Delivery picker ───────────────────────
    describe "Test 5: Ahmed is selectable in the covering branch's cashier handover" do
      let(:colleague) do
        role = role_with("view_daily_reconciliation", "close_till_session")
        create(:user, business: business, first_name: "Colleague").tap { |u| u.update_column(:permission_role_id, role.id) }
      end

      before do
        create(:shift_assignment, user: colleague, shift: evening_shift, branch: covering,
               effective_from: Date.new(2026, 1, 1), effective_to: nil)
      end

      # Scoped to the actual handover-recipient radio group (till_handover[to_user_id])
      # rather than the whole page body — Ahmed also holds create_till_deposit,
      # which makes him a candidate in the separate, deliberately business-wide
      # (not branch-scoped) "assign depositor" picker on this same page. That's
      # existing, unrelated behavior; this test only cares about the branch
      # colleague/recipient list.
      def recipient_ids
        Nokogiri::HTML(response.body)
          .css('input[name="till_handover[to_user_id]"]')
          .map { |el| el["value"].to_i }
      end

      it "lists Ahmed as a handover recipient at Nasr City on the coverage date" do
        travel_to(aug20.to_time + 16.hours) do
          sign_in colleague
          get new_till_handover_path
        end

        expect(recipient_ids).to include(ahmed.id)
      end

      it "does not list Ahmed as a handover recipient at Nasr City outside the coverage date" do
        travel_to(aug21.to_time + 16.hours) do
          sign_in colleague
          get new_till_handover_path
        end

        expect(recipient_ids).not_to include(ahmed.id)
      end
    end

    # ── Test 6 — cash custody/handover numbers use Nasr City's own activity ───
    describe "Test 6: cash custody calculates against the covering branch's actual activity" do
      let!(:nasr_dr) do
        dr = DailyReconciliation.create!(branch: covering, business: business, state: "closed",
                                          opened_at: aug20.to_time + 15.hours, closed_at: aug20.to_time + 23.hours,
                                          business_date: aug20)
        TillSession.create!(daily_reconciliation: dr, current_holder: ahmed)
        dr
      end

      before do
        # Opening float: 5,000. Cash sales: 10,000. Cash refunds: 500.
        # Expected cash = opening (already part of collected via handover chain)
        # — mirrored here the same way TillSessionAmount/expected_cash_deposit
        # is populated at day close: collected_amount is the day's total cash
        # collected (opening float + sales), refund_amount is refunds.
        TillSessionAmount.create!(daily_reconciliation: nasr_dr, payment_method: cash_pm,
                                   payment_method_name: cash_pm.name, collected_amount: 15_000, refund_amount: 500)
      end

      it "computes expected cash from Nasr City's own session totals (5,000 opening + 10,000 sales - 500 refunds = 14,500)" do
        expect(nasr_dr.expected_cash_deposit).to eq(14_500)
      end

      it "attributes the till session/custody holder to the Nasr City DR" do
        expect(nasr_dr.till_session.current_holder).to eq(ahmed)
        expect(nasr_dr.branch).to eq(covering)
      end
    end

    # ── Test 7 / Section 6 regression — Aug 19 / 20 / 21 ───────────────────────
    describe "Test 7: resolves back to the regular branch immediately after the coverage date" do
      it "matches the exact Aug 19 / 20 / 21 walkthrough from the spec" do
        expect(Shifts::AssignmentResolver.for(user: ahmed, date: aug19)&.branch).to eq(home)
        expect(Shifts::AssignmentResolver.for(user: ahmed, date: aug20)&.branch).to eq(covering)
        expect(Shifts::AssignmentResolver.for(user: ahmed, date: aug21)&.branch).to eq(home)
      end
    end

    # ── Test 8 / 9 — conflict protections remain narrow and kind-aware ────────
    describe "Test 8: regular + regular conflicting shift time is still rejected" do
      it "rejects a second REGULAR assignment at another branch with overlapping hours" do
        other_branch = create(:branch, business: business)
        conflicting = build(:shift_assignment, user: ahmed, shift: evening_shift, branch: other_branch,
                            effective_from: Date.new(2026, 6, 1), effective_to: nil)
        expect(conflicting).not_to be_valid
        expect(conflicting.errors[:base].join).to include("Evening Shift")
      end
    end

    describe "Test 9: temporary coverage + temporary coverage conflicting shift time is still rejected" do
      it "rejects a second, overlapping TEMPORARY_COVERAGE assignment for the same date/time at a different branch" do
        another_covering_branch = create(:branch, business: business)
        conflicting = build(:shift_assignment, user: ahmed, shift: evening_shift, branch: another_covering_branch,
                            assignment_kind: "temporary_coverage", effective_from: aug20, effective_to: aug20,
                            reason: "Conflicting second coverage")
        expect(conflicting).not_to be_valid
      end

      it "still allows the regular + temporary_coverage combination itself (the behavior under test)" do
        expect(regular_assignment).to be_valid
        expect(coverage_assignment).to be_valid
        expect(ShiftAssignment.where(user: ahmed).count).to eq(2)
      end
    end

    # ── Test 10 — historical records survive modification/ending of coverage ──
    describe "Test 10: historical reconciliation/cash records are unaffected by later changes to the coverage assignment" do
      let!(:nasr_dr) do
        DailyReconciliation.create!(branch: covering, business: business, state: "closed",
                                     opened_at: aug20.to_time + 15.hours, closed_at: aug20.to_time + 23.hours,
                                     business_date: aug20)
      end
      let!(:deposit) do
        TillDeposit.create!(daily_reconciliation: nasr_dr, payment_method: cash_pm, deposited_by: ahmed,
                             amount: 14_500, deposited_at: aug20.to_time + 23.hours)
      end

      it "keeps the DR and deposit at Nasr City after the coverage assignment's reason is edited" do
        coverage_assignment.update!(reason: "Updated reason after the fact")

        expect(nasr_dr.reload.branch).to eq(covering)
        expect(deposit.reload.daily_reconciliation.branch).to eq(covering)
      end

      context "when the coverage assignment is later ended early" do
        # A wider window (Aug 20-21) here specifically, so it can be legitimately
        # truncated back to a single day (effective_to must stay > effective_from)
        # while the historical DR/deposit — dated Aug 20, the first day — stay
        # inside the truncated window regardless, proving the point either way:
        # already-created records never move, whether the date they're on is
        # still covered after the edit or not.
        let!(:coverage_assignment) do
          create(:shift_assignment, user: ahmed, shift: evening_shift, branch: covering,
                 assignment_kind: "temporary_coverage", effective_from: aug20, effective_to: aug21,
                 reason: "Covering another employee")
        end

        it "keeps the DR and deposit at Nasr City after the coverage assignment is ended early" do
          coverage_assignment.update!(effective_to: aug20, ended_by: ahmed)

          expect(nasr_dr.reload.branch).to eq(covering)
          expect(deposit.reload.daily_reconciliation.branch).to eq(covering)
        end
      end
    end
  end
end
