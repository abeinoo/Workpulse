require "rails_helper"

# Characterization (Pilot 4 — Penalty Rules, M1) — CURRENT penalty-rule writes
# that go through the Workforce Shift (module-boundaries.md §14.2 #9): the
# Admin::ShiftsController form's penalty_rules_attributes, and Shift's
# dependent: :destroy. Authorization of these paths (SEC-M2-3 / SEC-M2-9) is in
# spec/requests/security/admin_shifts_and_penalty_rules_authorization_spec.rb.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: penalty rules through the shift", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :manage_shifts) }

  let!(:shift)         { create(:shift, :fixed_time, business: business, name: "Morning") }
  let!(:rule)          { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }
  let!(:sibling_shift) { create(:shift, :fixed_time, business: business, name: "Evening") }
  let!(:sibling_rule)  { create(:penalty_rule, shift: sibling_shift, threshold_minutes: 15, deduction_value: 50) }
  let!(:foreign_shift) { create(:shift, :fixed_time, business: other) }
  let!(:foreign_rule)  { create(:penalty_rule, shift: foreign_shift, threshold_minutes: 15, deduction_value: 50) }

  def update_shift(rules) = patch(admin_shift_path(shift), params: { shift: { name: "Morning", penalty_rules_attributes: rules } })

  describe "nested penalty_rules_attributes on the shift update" do
    before { sign_in manager }

    it "updates the shift's own rule, adds a new one and removes one in a single save" do
      extra = create(:penalty_rule, shift: shift, threshold_minutes: 30, deduction_value: 70)

      update_shift(
        "0" => { id: rule.id, deduction_value: 55 },
        "1" => { rule_type: "early_leave", threshold_minutes: 20, deduction_type: "fixed_amount", deduction_value: 10 },
        "2" => { id: extra.id, _destroy: "1" }
      )

      expect(response).to redirect_to(admin_shifts_path)
      expect(rule.reload.deduction_value).to eq(55)
      expect(PenaltyRule).not_to exist(extra.id)
      expect(shift.penalty_rules.reload.map { |r| [ r.rule_type, r.threshold_minutes ] })
        .to contain_exactly([ "late_arrival", 15 ], [ "early_leave", 20 ])
    end

    it "ignores an all-blank new row" do
      expect { update_shift("0" => { rule_type: "", threshold_minutes: "", deduction_type: "", deduction_value: "" }) }
        .not_to change(PenaltyRule, :count)
      expect(response).to redirect_to(admin_shifts_path)
    end

    it "re-renders the form (422) and saves nothing when a nested rule is invalid" do
      update_shift(
        "0" => { id: rule.id, deduction_value: 99 },
        "1" => { rule_type: "late_arrival", threshold_minutes: 0, deduction_type: "fixed_amount", deduction_value: 5 }
      )

      expect(response).to have_http_status(:unprocessable_entity)
      expect(rule.reload.deduction_value).to eq(50)
      expect(shift.penalty_rules.count).to eq(1)
    end

    it "returns 404 for another shift's rule id and changes nothing" do
      update_shift("0" => { id: sibling_rule.id, deduction_value: 1 })

      expect(response).to have_http_status(:not_found)
      expect(sibling_rule.reload).to have_attributes(deduction_value: 50, shift_id: sibling_shift.id)
    end

    it "returns 404 for another business's rule id and changes nothing" do
      update_shift("0" => { id: foreign_rule.id, deduction_value: 1 })

      expect(response).to have_http_status(:not_found)
      expect(foreign_rule.reload).to have_attributes(deduction_value: 50, shift_id: foreign_shift.id)
    end

    it "cannot destroy another shift's rule through _destroy (404)" do
      update_shift("0" => { id: sibling_rule.id, _destroy: "1" })

      expect(response).to have_http_status(:not_found)
      expect(PenaltyRule).to exist(sibling_rule.id)
    end
  end

  describe "shift creation with nested rules" do
    it "creates the shift and its rules together" do
      sign_in manager
      post admin_shifts_path, params: { shift: {
        name: "Night", shift_type: "fixed_time", start_time: "21:00", end_time: "23:00",
        penalty_rules_attributes: { "0" => { rule_type: "late_arrival", threshold_minutes: 10, deduction_type: "fixed_amount", deduction_value: 20 } }
      } }

      created = Shift.find_by!(business: business, name: "Night")
      expect(created.penalty_rules.sole).to have_attributes(threshold_minutes: 10, deduction_value: 20)
    end
  end

  describe "shift deletion (Shift has_many :penalty_rules, dependent: :destroy)" do
    before { sign_in manager }

    it "deletes the shift's rules with an unassigned shift, leaving none behind" do
      delete admin_shift_path(shift)

      expect(Shift).not_to exist(shift.id)
      expect(PenaltyRule.where(shift_id: shift.id)).to be_empty
      expect(PenaltyRule).to exist(sibling_rule.id)
    end

    it "keeps a shift with assignments and its rules (restrict_with_error), " \
       "while the controller still redirects with the 'removed' notice (P4-D1, current behaviour)" do
      create(:shift_assignment, shift: shift, business: business)

      delete admin_shift_path(shift)

      expect(Shift).to exist(shift.id)
      expect(PenaltyRule).to exist(rule.id)
      expect(response).to redirect_to(admin_shifts_path)
      expect(flash[:notice]).to eq(I18n.t("flash.shift_removed"))
    end
  end

  describe "no audit log (TD-P4-1, current behaviour)" do
    before { sign_in manager }

    it "writes none for rule changes through the shift form" do
      expect { update_shift("0" => { id: rule.id, deduction_value: 60 }) }.not_to change(AuditLog, :count)
      expect(rule.reload.deduction_value).to eq(60)
    end

    it "writes none for create, update and delete through Admin::PenaltyRulesController" do
      params = { penalty_rule: { rule_type: "early_leave", threshold_minutes: 25, deduction_type: "fixed_amount", deduction_value: 5 } }

      expect do
        post admin_shift_penalty_rules_path(shift), params: params
        patch admin_shift_penalty_rule_path(shift, rule), params: { penalty_rule: { deduction_value: 65 } }
        delete admin_shift_penalty_rule_path(shift, rule)
      end.not_to change(AuditLog, :count)
      expect(response).to redirect_to(admin_shift_path(shift))
    end
  end
end
