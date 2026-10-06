require "rails_helper"

# Pilot 4 — Penalty Rules, M3: Admin::ShiftsController stages the form's rule
# rows only through the Workforce Shifts::PenaltyRuleSettings contract (plain
# row hashes) and the shift's own save persists them. The form behaviour itself
# stays pinned by
# spec/characterization/attendance_payroll/penalty_rule_shift_form_spec.rb and
# authorization by spec/requests/security/admin_shifts_and_penalty_rules_authorization_spec.rb.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Admin shift form routes penalty rules through the contract", type: :request do
  let(:business) { create(:business) }
  let(:manager)  { api_user_with(business, :manage_shifts) }
  let(:viewer)   { api_user_with(business, :view_shifts) }

  let!(:shift)        { create(:shift, :fixed_time, business: business, name: "Morning") }
  let!(:rule)         { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }
  let!(:foreign_rule) { create(:penalty_rule, shift: create(:shift, :fixed_time, business: create(:business))) }

  let(:new_row) do
    { "rule_type" => "early_leave", "threshold_minutes" => "20", "deduction_type" => "fixed_amount", "deduction_value" => "10" }
  end

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = Shifts::PenaltyRuleSettings.instance_variable_get(:@handler)
    Shifts::PenaltyRuleSettings.instance_variable_set(:@handler, handler)
    yield
  ensure
    Shifts::PenaltyRuleSettings.instance_variable_set(:@handler, original)
  end

  def update_shift(rules, name: "Morning")
    patch admin_shift_path(shift), params: { shift: { name: name, penalty_rules_attributes: rules } }
  end

  before { allow(Shifts::PenaltyRuleSettings).to receive(:assign).and_call_original }

  describe "the contract and its payload" do
    before { sign_in manager }

    it "update passes the shift and the permitted rows as plain hashes, in submitted order" do
      update_shift({ "0" => { id: rule.id, deduction_value: "55", _destroy: "0", unexpected: "x" }, "1" => new_row })

      expect(Shifts::PenaltyRuleSettings).to have_received(:assign).once do |shift:, rows:|
        expect(shift).to eq(self.shift)
        expect(rows).to eq([ { "id" => rule.id.to_s, "deduction_value" => "55", "_destroy" => "0" }, new_row ])
        expect(rows).to all(be_an_instance_of(Hash))
      end
      expect(response).to redirect_to(admin_shifts_path)
      expect(rule.reload.deduction_value).to eq(55)
      expect(shift.penalty_rules.count).to eq(2)
    end

    it "create passes the new shift and its rows, and the rules are created with it" do
      post admin_shifts_path, params: { shift: { name: "Night", shift_type: "fixed_time", start_time: "21:00",
                                                 end_time: "23:00", penalty_rules_attributes: { "0" => new_row } } }

      expect(Shifts::PenaltyRuleSettings).to have_received(:assign).with(shift: an_instance_of(Shift), rows: [ new_row ])
      expect(Shift.find_by!(business: business, name: "Night").penalty_rules.sole.threshold_minutes).to eq(20)
    end

    it "is not called when the form sends no rule rows" do
      patch admin_shift_path(shift), params: { shift: { name: "Renamed" } }

      expect(Shifts::PenaltyRuleSettings).not_to have_received(:assign)
      expect(shift.reload.name).to eq("Renamed")
      expect(shift.penalty_rules.count).to eq(1)
    end
  end

  describe "behaviour through the contract" do
    before { sign_in manager }

    it "re-renders 422 and rolls back the shift and every rule on an invalid row" do
      update_shift({ "0" => { id: rule.id, deduction_value: "99" }, "1" => new_row.merge("threshold_minutes" => "0") },
                   name: "Renamed")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(shift.reload.name).to eq("Morning")
      expect(rule.reload.deduction_value).to eq(50)
      expect(shift.penalty_rules.count).to eq(1)
    end

    it "removes a rule marked _destroy" do
      update_shift({ "0" => { id: rule.id, _destroy: "1" } })

      expect(PenaltyRule).not_to exist(rule.id)
    end

    it "returns 404 for another business's rule id through the contract, changing nothing" do
      update_shift({ "0" => { id: foreign_rule.id, deduction_value: "1" } })

      expect(Shifts::PenaltyRuleSettings).to have_received(:assign)
      expect(response).to have_http_status(:not_found)
      expect(foreign_rule.reload.deduction_value).to eq(50)
    end
  end

  describe "authorization is unchanged" do
    it "a view_shifts user is refused before any rule is staged on update" do
      sign_in viewer
      update_shift({ "0" => new_row })

      expect(response).to redirect_to(root_path)
      expect(Shifts::PenaltyRuleSettings).not_to have_received(:assign)
      expect(shift.penalty_rules.count).to eq(1)
    end

    it "a view_shifts user creating a shift is refused and nothing is saved (rows staged before authorize, as before)" do
      sign_in viewer
      expect do
        post admin_shifts_path, params: { shift: { name: "Night", shift_type: "fixed_time", start_time: "21:00",
                                                   end_time: "23:00", penalty_rules_attributes: { "0" => new_row } } }
      end.not_to change { [ Shift.count, PenaltyRule.count ] }
      expect(response).to redirect_to(root_path)
    end
  end

  describe "no direct write to penalty rules on this path" do
    it "writes no rule when the contract handler stages nothing" do
      sign_in manager
      recorder = Module.new { def self.assign(shift:, rows:) = nil }

      with_handler(recorder) { update_shift({ "0" => new_row, "1" => { id: rule.id, deduction_value: "99" } }, name: "Renamed") }

      expect(response).to redirect_to(admin_shifts_path)
      expect(shift.reload.name).to eq("Renamed")
      expect(shift.penalty_rules.count).to eq(1)
      expect(rule.reload.deduction_value).to eq(50)
    end

    it "the controller names neither PenaltyRule nor penalty_rules_attributes in code" do
      source = File.read(Rails.root.join("app/controllers/admin/shifts_controller.rb"))
      code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

      expect(code).not_to match(/\bPenaltyRule\b|penalty_rules_attributes\s*=|\.penalty_rules\.(?:build|create|new|destroy)/)
      expect(code).to include("Shifts::PenaltyRuleSettings.assign")
    end
  end
end
