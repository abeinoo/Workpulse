require "rails_helper"

# Characterization (Pilot 4 — Penalty Rules, M1) — CURRENT /api/v1 penalty-rule
# writes (Api::V1::PenaltyRulesController, legacy contract, raw model
# attributes). The index and the foreign-shift 404 are pinned in
# spec/requests/api/v1/characterization/management_spec.rb; web CRUD and
# authorization in spec/requests/security/admin_shifts_and_penalty_rules_authorization_spec.rb.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: penalty rule API writes", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  let!(:shift)         { create(:shift, :fixed_time, business: business) }
  let!(:sibling_shift) { create(:shift, :fixed_time, business: business) }
  let!(:rule)          { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }
  let!(:sibling_rule)  { create(:penalty_rule, shift: sibling_shift, threshold_minutes: 15, deduction_value: 50) }
  let!(:foreign_shift) { create(:shift, :fixed_time, business: other) }
  let!(:foreign_rule)  { create(:penalty_rule, shift: foreign_shift, threshold_minutes: 15, deduction_value: 50) }

  let(:manager)  { api_user_with(business, :manage_shifts) }
  let(:viewer)   { api_user_with(business, :view_shifts) }
  let(:employee) { create(:user, business: business) }

  let(:rule_keys) do
    %w[id shift_id rule_type threshold_minutes deduction_type deduction_value created_at updated_at]
  end
  let(:valid_params) do
    { penalty_rule: { rule_type: "late_arrival", threshold_minutes: 40, deduction_type: "fixed_amount", deduction_value: 75 } }
  end

  def rules_path(shift_id, rule_id = nil) = [ "/api/v1/shifts/#{shift_id}/penalty_rules", rule_id ].compact.join("/")

  describe "create (manage_shifts)" do
    it "creates a rule on the shift and returns 201 with the raw model attributes" do
      sign_in manager
      expect { post rules_path(shift.id), params: valid_params, as: :json }.to change(shift.penalty_rules, :count).by(1)

      expect_legacy_success(:created)
      expect(api_data.keys).to match_array(rule_keys)
      expect(api_data).to include("shift_id" => shift.id, "rule_type" => "late_arrival", "threshold_minutes" => 40,
                                  "deduction_type" => "fixed_amount", "deduction_value" => "75.0")
    end

    it "returns 422 with the model's full messages for an invalid rule" do
      sign_in manager
      params = { penalty_rule: { rule_type: "late_arrival", threshold_minutes: 15, deduction_type: "percentage_of_daily",
                                 deduction_value: 150 } }
      expect { post rules_path(shift.id), params: params, as: :json }.not_to change(PenaltyRule, :count)

      expect_legacy_error(:unprocessable_entity, message: "Failed to create penalty rule")
      expect(api_json["errors"].size).to eq(2) # duplicate threshold + percentage above 100
    end

    it "rejects a late-arrival rule on an hour-based shift (422)" do
      hour_shift = create(:shift, :hour_based, business: business)
      sign_in manager
      post rules_path(hour_shift.id), params: valid_params, as: :json

      expect_legacy_error(:unprocessable_entity, message: "Failed to create penalty rule")
      expect(hour_shift.penalty_rules).to be_empty
    end
  end

  describe "update and destroy (manage_shifts)" do
    it "updates the rule and returns it; shift_id is not assignable" do
      sign_in manager
      patch rules_path(shift.id, rule.id),
            params: { penalty_rule: { deduction_value: 80, shift_id: sibling_shift.id } }, as: :json

      expect_legacy_success
      expect(api_data.keys).to match_array(rule_keys)
      expect(rule.reload).to have_attributes(deduction_value: 80, shift_id: shift.id)
    end

    it "returns 422 for an invalid update and keeps the rule" do
      sign_in manager
      patch rules_path(shift.id, rule.id), params: { penalty_rule: { threshold_minutes: 0 } }, as: :json

      expect_legacy_error(:unprocessable_entity, message: "Failed to update penalty rule")
      expect(rule.reload.threshold_minutes).to eq(15)
    end

    it "deletes the rule and returns a message" do
      sign_in manager
      delete rules_path(shift.id, rule.id), as: :json

      expect_legacy_success
      expect(api_data).to eq("message" => "Penalty rule deleted")
      expect(PenaltyRule).not_to exist(rule.id)
    end
  end

  describe "403 without manage_shifts" do
    it "view_shifts cannot create" do
      sign_in viewer
      expect { post rules_path(shift.id), params: valid_params, as: :json }.not_to change(PenaltyRule, :count)
      expect_legacy_error(:forbidden)
    end

    it "view_shifts cannot update" do
      sign_in viewer
      patch rules_path(shift.id, rule.id), params: valid_params, as: :json
      expect_legacy_error(:forbidden)
      expect(rule.reload.threshold_minutes).to eq(15)
    end

    it "view_shifts cannot delete" do
      sign_in viewer
      delete rules_path(shift.id, rule.id), as: :json
      expect_legacy_error(:forbidden)
      expect(PenaltyRule).to exist(rule.id)
    end

    it "an employee assigned to the shift cannot create" do
      create(:shift_assignment, user: employee, shift: shift, business: business)
      sign_in employee
      post rules_path(shift.id), params: valid_params, as: :json
      expect_legacy_error(:forbidden)
    end
  end

  describe "404 isolation (manage_shifts)" do
    it "cannot create on another business's shift" do
      sign_in manager
      post rules_path(foreign_shift.id), params: valid_params, as: :json
      expect_legacy_error(:not_found)
      expect(foreign_shift.penalty_rules.count).to eq(1)
    end

    it "cannot update another business's rule through an own shift" do
      sign_in manager
      patch rules_path(shift.id, foreign_rule.id), params: valid_params, as: :json
      expect_legacy_error(:not_found)
      expect(foreign_rule.reload.threshold_minutes).to eq(15)
    end

    it "cannot delete another business's rule on its own shift" do
      sign_in manager
      delete rules_path(foreign_shift.id, foreign_rule.id), as: :json
      expect_legacy_error(:not_found)
      expect(PenaltyRule).to exist(foreign_rule.id)
    end

    it "cannot reach another own shift's rule through the wrong shift" do
      sign_in manager
      patch rules_path(shift.id, sibling_rule.id), params: valid_params, as: :json
      expect_legacy_error(:not_found)
      expect(sibling_rule.reload.threshold_minutes).to eq(15)
    end
  end

  describe "read visibility (index authorizes ShiftPolicy#show?)" do
    it "an employee assigned to the shift can list its rules" do
      create(:shift_assignment, user: employee, shift: shift, business: business)
      sign_in employee
      get rules_path(shift.id), as: :json

      expect_legacy_success
      expect(api_data.map { |r| r["id"] }).to eq([ rule.id ])
    end

    it "an unassigned employee without shift permissions is refused (403)" do
      sign_in employee
      get rules_path(shift.id), as: :json
      expect_legacy_error(:forbidden)
    end
  end

  it "writes no audit log for API create, update or delete (TD-P4-1, current behaviour)" do
    sign_in manager
    expect do
      post rules_path(shift.id), params: valid_params, as: :json
      patch rules_path(shift.id, rule.id), params: { penalty_rule: { deduction_value: 60 } }, as: :json
      delete rules_path(shift.id, rule.id), as: :json
    end.not_to change(AuditLog, :count)
    expect(response).to have_http_status(:ok)
  end
end
