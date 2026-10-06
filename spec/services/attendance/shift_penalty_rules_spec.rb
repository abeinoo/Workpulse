require "rails_helper"

# Pilot 4 — Penalty Rules, M4: Attendance::ShiftPenaltyRules owns the staging of
# the shift form's rule rows (moved from Shift's accepts_nested_attributes_for).
# It writes nothing itself; Shift's autosave association persists the staged
# rules with the shift. The contract is pinned in
# spec/services/shifts/penalty_rule_settings_spec.rb and the form in
# spec/characterization/attendance_payroll/penalty_rule_shift_form_spec.rb.
RSpec.describe Attendance::ShiftPenaltyRules do
  let(:business) { create(:business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let!(:rule)    { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }

  def new_row(threshold, **extra)
    { "rule_type" => "early_leave", "threshold_minutes" => threshold.to_s, "deduction_type" => "fixed_amount",
      "deduction_value" => "10" }.merge(extra.transform_keys(&:to_s))
  end

  def assign(rows, on: shift) = described_class.assign(shift: on, rows: rows)

  it "stages create, update and destroy without writing; the shift's save persists them" do
    extra = create(:penalty_rule, shift: shift, threshold_minutes: 30)

    expect do
      assign([ { "id" => rule.id.to_s, "deduction_value" => "70" }, new_row(20), { "id" => extra.id.to_s, "_destroy" => "1" } ])
    end.not_to(change { PenaltyRule.order(:id).pluck(:id, :deduction_value) })

    expect(shift.save).to be(true)
    expect(rule.reload.deduction_value).to eq(70)
    expect(PenaltyRule).not_to exist(extra.id)
    expect(shift.penalty_rules.reload.map(&:threshold_minutes)).to contain_exactly(15, 20)
  end

  it "skips an all-blank new row and a new row marked _destroy" do
    blank = { "rule_type" => "", "threshold_minutes" => "", "deduction_type" => "", "deduction_value" => "" }
    assign([ blank, new_row(20, _destroy: "1") ])
    shift.save!

    expect(shift.penalty_rules.reload.map(&:id)).to eq([ rule.id ])
  end

  it "accepts an index-keyed Hash, a single row with an id, and permitted parameters" do
    assign({ "0" => new_row(20), "1" => new_row(25) })
    assign({ "id" => rule.id.to_s, "deduction_value" => "60" })
    assign(ActionController::Parameters.new("0" => new_row(35)).permit!)
    shift.save!

    expect(shift.penalty_rules.reload.map(&:threshold_minutes)).to contain_exactly(15, 20, 25, 35)
    expect(rule.reload.deduction_value).to eq(60)
  end

  it "rejects rows that are neither an Array nor a Hash" do
    expect { assign("rows") }.to raise_error(ArgumentError, /Hash or Array expected/)
  end

  it "works on an already loaded association (the form re-render case)" do
    shift.penalty_rules.load
    assign([ { "id" => rule.id.to_s, "deduction_value" => "65" }, new_row(20) ])

    expect(shift.penalty_rules.size).to eq(2)
    expect(shift.penalty_rules.detect(&:persisted?).deduction_value).to eq(65)
    shift.save!
    expect(rule.reload.deduction_value).to eq(65)
  end

  it "puts invalid rule errors on the shift and saves nothing (one transaction)" do
    shift.name = "Renamed"
    assign([ { "id" => rule.id.to_s, "deduction_value" => "70" }, new_row(0) ])

    expect(shift.save).to be(false)
    expect(shift.errors.attribute_names.map(&:to_s)).to include("penalty_rules.threshold_minutes")
    expect(shift.reload.name).not_to eq("Renamed")
    expect(rule.reload.deduction_value).to eq(50)
    expect(shift.penalty_rules.count).to eq(1)
  end

  it "raises RecordNotFound (nested-attributes message) for a rule outside the shift" do
    sibling = create(:penalty_rule, shift: create(:shift, :fixed_time, business: business))
    foreign = create(:penalty_rule, shift: create(:shift, :fixed_time, business: create(:business)))

    [ sibling, foreign ].each do |other|
      expect { assign([ { "id" => other.id.to_s, "_destroy" => "1" } ]) }
        .to raise_error(ActiveRecord::RecordNotFound, "Couldn't find PenaltyRule with ID=#{other.id} for Shift with ID=#{shift.id}")
      expect(PenaltyRule).to exist(other.id)
    end
  end

  describe "ownership after M4" do
    it "Shift no longer has nested-attribute behaviour for penalty rules; the association autosaves" do
      expect(Shift.nested_attributes_options).not_to have_key(:penalty_rules)
      expect(Shift.new).not_to respond_to(:penalty_rules_attributes=)
      expect(Shift.reflect_on_association(:penalty_rules).options).to include(autosave: true, dependent: :destroy)
    end

    it "the Workforce side names no penalty-rule write mechanics" do
      { "app/models/shift.rb" => /accepts_nested_attributes_for|\bPenaltyRule\b|Attendance::/,
        "app/controllers/admin/shifts_controller.rb" => /accepts_nested_attributes_for|\bPenaltyRule\b|Attendance::|penalty_rules_attributes\s*=/ }
        .each do |path, forbidden|
          code = File.read(Rails.root.join(path)).each_line.reject { |line| line.lstrip.start_with?("#") }.join
          expect(code).not_to match(forbidden), path
        end
    end

    it "the registered contract handler is this implementation" do
      expect(Shifts::PenaltyRuleSettings.handler).to equal(described_class)
    end
  end
end
