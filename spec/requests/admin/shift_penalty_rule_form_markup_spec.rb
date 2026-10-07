require "rails_helper"

# Pilot 4 — Penalty Rules, M4: with Shift's nested attributes gone, the shift
# form still renders the rule rows under shift[penalty_rules_attributes][i][…]
# (the names the controller, the contract and the Stimulus controllers use),
# both on edit and on the 422 re-render.
RSpec.describe "Admin shift form penalty-rule markup", type: :request do
  let(:business) { create(:business) }
  let(:manager)  { api_user_with(business, :manage_shifts) }
  let!(:shift)   { create(:shift, :fixed_time, business: business) }
  let!(:first)   { create(:penalty_rule, shift: shift, threshold_minutes: 15) }
  let!(:second)  { create(:penalty_rule, shift: shift, rule_type: "early_leave", threshold_minutes: 30) }

  before { sign_in manager }

  it "renders each existing rule with indexed nested names and its id" do
    get edit_admin_shift_path(shift)

    expect(response).to have_http_status(:ok)
    [ first, second ].each_with_index do |rule, index|
      expect(response.body).to include(%(value="#{rule.id}" name="shift[penalty_rules_attributes][#{index}][id]"))
      expect(response.body).to include(%(id="shift_penalty_rules_attributes_#{index}_threshold_minutes"))
    end
    expect(response.body.scan(/name="shift\[penalty_rules_attributes\]\[\d+\]\[id\]"/).size).to eq(2)
  end

  it "re-renders the submitted rows, including a new invalid one, after a 422" do
    patch admin_shift_path(shift), params: { shift: { name: shift.name, penalty_rules_attributes: {
      "0" => { id: first.id, deduction_value: "77" },
      "1" => { rule_type: "late_arrival", threshold_minutes: "0", deduction_type: "fixed_amount", deduction_value: "5" }
    } } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include(%(value="77" name="shift[penalty_rules_attributes][0][deduction_value]"))
    expect(response.body).to include(%(value="0" name="shift[penalty_rules_attributes][2][threshold_minutes]"))
  end
end
