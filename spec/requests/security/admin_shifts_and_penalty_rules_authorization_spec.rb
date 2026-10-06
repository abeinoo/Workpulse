require "rails_helper"

# SEC-M2-3 / SEC-M2-9: Admin::PenaltyRulesController and Admin::ShiftsController
# called no policy, so any user past Admin::BaseController's broad gate
# (view_employees, view_payroll …) could create, change or delete shifts and
# penalty rules — directly, or through PATCH /admin/shifts/:id with
# penalty_rules_attributes. Shift times and penalty rules drive lateness and
# payroll deductions. Both controllers now authorize every action with the
# existing ShiftPolicy / PenaltyRulePolicy (manage_shifts to change anything).
#
# Requests that end in a rescued 404 are kept one per example: the signed-in
# test session is not carried into a following request.
RSpec.describe "Security: shift and penalty rule administration", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  let!(:shift)        { create(:shift, :fixed_time, business: business, name: "Morning") }
  let!(:rule)         { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }
  let!(:foreign)      { create(:shift, :fixed_time, business: other, name: "Foreign") }
  let!(:foreign_rule) { create(:penalty_rule, shift: foreign, threshold_minutes: 15, deduction_value: 50) }

  let(:view_employees_only) { api_user_with(business, :view_employees) }
  let(:shift_viewer)        { api_user_with(business, :view_employees, :view_shifts) }
  let(:shift_manager)       { api_user_with(business, :manage_shifts) }

  let(:nested_rule_params) do
    { "0" => { rule_type: "late_arrival", threshold_minutes: 1, deduction_type: "fixed_amount", deduction_value: 999 } }
  end
  let(:rule_params) do
    { penalty_rule: { rule_type: "late_arrival", threshold_minutes: 30, deduction_type: "fixed_amount", deduction_value: 75 } }
  end
  let(:new_shift_params) do
    { shift: { name: "Night", shift_type: "fixed_time", start_time: "21:00", end_time: "23:00",
               penalty_rules_attributes: nested_rule_params } }
  end

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  # ── SEC-M2-9: shifts ────────────────────────────────────────────────────────
  describe "shifts without manage_shifts (view_employees only)" do
    before { sign_in view_employees_only }

    it "cannot modify a shift through PATCH /admin/shifts/:id (the demonstrated attack)" do
      patch admin_shift_path(shift), params: { shift: { name: "Renamed", start_time: "03:00" } }
      expect_denied
      shift.reload
      expect(shift.name).to eq("Morning")
      expect(shift.start_time.strftime("%H:%M")).to eq("09:00")
    end

    it "cannot add penalty rules through penalty_rules_attributes on the shift update path" do
      expect {
        patch admin_shift_path(shift), params: { shift: { penalty_rules_attributes: nested_rule_params } }
      }.not_to change(PenaltyRule, :count)
      expect_denied
    end

    it "cannot change or remove an existing rule through penalty_rules_attributes" do
      patch admin_shift_path(shift), params: { shift: { penalty_rules_attributes: {
        "0" => { id: rule.id, deduction_value: 999 }, "1" => { id: rule.id, _destroy: "1" }
      } } }
      expect_denied
      expect(rule.reload.deduction_value).to eq(50)
    end

    it "cannot create a shift (nor its nested penalty rules)" do
      expect { post admin_shifts_path, params: new_shift_params }
        .to not_change(Shift, :count).and not_change(PenaltyRule, :count)
      expect_denied
    end

    it "cannot delete a shift" do
      expect { delete admin_shift_path(shift) }.not_to change(Shift, :count)
      expect_denied
    end

    it "cannot open the shift pages or forms" do
      [ admin_shifts_path, admin_shift_path(shift), new_admin_shift_path, edit_admin_shift_path(shift) ].each do |path|
        get path
        expect_denied
      end
    end
  end

  describe "shifts with view_shifts only" do
    before { sign_in shift_viewer }

    it "can view a shift (existing ShiftPolicy#show?) without the change actions" do
      get admin_shift_path(shift)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(edit_admin_shift_path(shift))
      expect(response.body).not_to include(new_admin_shift_penalty_rule_path(shift))
    end

    it "still cannot update the shift" do
      patch admin_shift_path(shift), params: { shift: { name: "Renamed" } }
      expect_denied
      expect(shift.reload.name).to eq("Morning")
    end
  end

  describe "shifts with manage_shifts (same business)" do
    before { sign_in shift_manager }

    it "lists and shows shifts with the change actions" do
      get admin_shifts_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Morning")
      expect(response.body).not_to include("Foreign")

      get admin_shift_path(shift)
      expect(response.body).to include(edit_admin_shift_path(shift))
    end

    it "creates a shift with nested penalty rules" do
      expect { post admin_shifts_path, params: new_shift_params }
        .to change(business.shifts, :count).by(1).and change(PenaltyRule, :count).by(1)
      expect(response).to redirect_to(admin_shifts_path)
    end

    it "updates a shift and its penalty rules through the shift form" do
      patch admin_shift_path(shift), params: { shift: { name: "Early", penalty_rules_attributes: {
        "0" => { id: rule.id, deduction_value: 60 }
      } } }
      expect(response).to redirect_to(admin_shifts_path)
      expect(shift.reload.name).to eq("Early")
      expect(rule.reload.deduction_value).to eq(60)
    end

    it "deletes a shift" do
      disposable = create(:shift, :fixed_time, business: business, name: "Disposable")
      expect { delete admin_shift_path(disposable) }.to change(Shift, :count).by(-1)
      expect(response).to redirect_to(admin_shifts_path)
    end
  end

  describe "shift cross-business isolation (manage_shifts)" do
    before { sign_in shift_manager }

    it "cannot view another business's shift" do
      get admin_shift_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot update another business's shift or its rules" do
      patch admin_shift_path(foreign), params: { shift: { name: "Hijacked", penalty_rules_attributes: {
        "0" => { id: foreign_rule.id, deduction_value: 999 }
      } } }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.name).to eq("Foreign")
      expect(foreign_rule.reload.deduction_value).to eq(50)
    end

    it "cannot delete another business's shift" do
      expect { delete admin_shift_path(foreign) }.not_to change(Shift, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── SEC-M2-3: penalty rules ─────────────────────────────────────────────────
  describe "penalty rules without manage_shifts" do
    # view_shifts may view a shift, but changing its rules needs manage_shifts.
    before { sign_in shift_viewer }

    it "cannot open the new or edit forms" do
      get new_admin_shift_penalty_rule_path(shift)
      expect_denied
      get edit_admin_shift_penalty_rule_path(shift, rule)
      expect_denied
    end

    it "cannot create a rule" do
      expect { post admin_shift_penalty_rules_path(shift), params: rule_params }.not_to change(PenaltyRule, :count)
      expect_denied
    end

    it "cannot update a rule" do
      patch admin_shift_penalty_rule_path(shift, rule), params: { penalty_rule: { deduction_value: 999 } }
      expect_denied
      expect(rule.reload.deduction_value).to eq(50)
    end

    it "cannot delete a rule" do
      expect { delete admin_shift_penalty_rule_path(shift, rule) }.not_to change(PenaltyRule, :count)
      expect_denied
    end

    it "is denied with view_employees only as well" do
      sign_in view_employees_only
      expect { post admin_shift_penalty_rules_path(shift), params: rule_params }.not_to change(PenaltyRule, :count)
      expect_denied
    end
  end

  describe "penalty rules with manage_shifts (same business)" do
    before { sign_in shift_manager }

    it "creates, updates and deletes a rule" do
      expect { post admin_shift_penalty_rules_path(shift), params: rule_params }.to change(shift.penalty_rules, :count).by(1)
      expect(response).to redirect_to(admin_shift_path(shift))

      patch admin_shift_penalty_rule_path(shift, rule), params: { penalty_rule: { deduction_value: 80 } }
      expect(response).to redirect_to(admin_shift_path(shift))
      expect(rule.reload.deduction_value).to eq(80)

      expect { delete admin_shift_penalty_rule_path(shift, rule) }.to change(PenaltyRule, :count).by(-1)
      expect(response).to redirect_to(admin_shift_path(shift))
    end
  end

  describe "penalty rule cross-business isolation (manage_shifts)" do
    before { sign_in shift_manager }

    it "cannot add a rule to another business's shift" do
      expect { post admin_shift_penalty_rules_path(foreign), params: rule_params }.not_to change(PenaltyRule, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot update another business's rule" do
      patch admin_shift_penalty_rule_path(foreign, foreign_rule), params: { penalty_rule: { deduction_value: 999 } }
      expect(response).to have_http_status(:not_found)
      expect(foreign_rule.reload.deduction_value).to eq(50)
    end

    it "cannot reach another business's rule through an own shift" do
      patch admin_shift_penalty_rule_path(shift, foreign_rule), params: { penalty_rule: { deduction_value: 999 } }
      expect(response).to have_http_status(:not_found)
      expect(foreign_rule.reload.deduction_value).to eq(50)
    end

    it "cannot delete another business's rule" do
      expect { delete admin_shift_penalty_rule_path(foreign, foreign_rule) }.not_to change(PenaltyRule, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "the owner keeps full access to shifts and rules" do
    sign_in owner
    patch admin_shift_path(shift), params: { shift: { name: "Owner edit" } }
    expect(shift.reload.name).to eq("Owner edit")
    expect { post admin_shift_penalty_rules_path(shift), params: rule_params }.to change(PenaltyRule, :count).by(1)
  end
end
