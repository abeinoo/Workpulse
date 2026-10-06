require "rails_helper"

# Pilot 4 — Penalty Rules, M2: the Workforce contract Shifts::PenaltyRuleSettings
# and its Attendance & Payroll implementation Attendance::ShiftPenaltyRules
# (delegating to Shift's nested attributes). Admin::ShiftsController is routed
# through the contract in M3; the form behaviour stays pinned by
# spec/characterization/attendance_payroll/penalty_rule_shift_form_spec.rb.
RSpec.describe Shifts::PenaltyRuleSettings do
  let(:business) { create(:business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let!(:rule)    { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  def new_row(threshold, type: "early_leave", value: 10)
    { "rule_type" => type, "threshold_minutes" => threshold, "deduction_type" => "fixed_amount", "deduction_value" => value }
  end

  describe "registration" do
    it "has the Attendance & Payroll implementation registered at boot" do
      expect(described_class.handler).to equal(Attendance::ShiftPenaltyRules)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /assign/)
      expect(described_class.handler).to equal(Attendance::ShiftPenaltyRules)
    end

    it "raises NotRegistered instead of silently dropping rules when no handler is registered" do
      with_handler(nil) do
        expect { described_class.assign(shift: shift, rows: [ new_row(20) ]) }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    let(:handler) { double("handler", assign: :assigned) }
    let(:rows)    { [ new_row(20) ] }

    it "passes the shift and rows to the handler and returns its result" do
      with_handler(handler) { expect(described_class.assign(shift: shift, rows: rows)).to eq(:assigned) }

      expect(handler).to have_received(:assign).with(shift: shift, rows: rows)
    end

    it "propagates a handler error to the caller" do
      allow(handler).to receive(:assign).and_raise(ActiveRecord::RecordNotFound)

      with_handler(handler) do
        expect { described_class.assign(shift: shift, rows: rows) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "through the Attendance & Payroll implementation" do
    it "only stages the changes; the shift's save persists them" do
      described_class.assign(shift: shift, rows: [ { "id" => rule.id, "deduction_value" => 70 }, new_row(20) ])

      expect(rule.reload.deduction_value).to eq(50)
      expect(shift.penalty_rules.count).to eq(1)

      expect(shift.save).to be(true)
      expect(rule.reload.deduction_value).to eq(70)
      expect(shift.penalty_rules.reload.map(&:threshold_minutes)).to contain_exactly(15, 20)
    end

    it "removes a rule marked _destroy and ignores an all-blank new row" do
      blank = { "rule_type" => "", "threshold_minutes" => "", "deduction_type" => "", "deduction_value" => "" }
      described_class.assign(shift: shift, rows: { "0" => { "id" => rule.id, "_destroy" => "1" }, "1" => blank })
      shift.save!

      expect(shift.penalty_rules.reload).to be_empty
    end

    it "fails the shift's save on an invalid rule and persists nothing (one transaction)" do
      shift.name = "Renamed"
      described_class.assign(shift: shift, rows: [ { "id" => rule.id, "deduction_value" => 70 }, new_row(0) ])

      expect(shift.save).to be(false)
      expect(shift.errors.attribute_names.map(&:to_s)).to include(a_string_starting_with("penalty_rules"))
      expect(shift.reload.name).not_to eq("Renamed")
      expect(rule.reload.deduction_value).to eq(50)
      expect(shift.penalty_rules.count).to eq(1)
    end

    it "rolls back with an enclosing transaction" do
      ActiveRecord::Base.transaction do
        described_class.assign(shift: shift, rows: [ new_row(20) ])
        shift.save!
        raise ActiveRecord::Rollback
      end

      expect(shift.penalty_rules.reload.map(&:threshold_minutes)).to eq([ 15 ])
    end

    it "raises RecordNotFound for another shift's rule and another business's rule" do
      sibling = create(:penalty_rule, shift: create(:shift, :fixed_time, business: business))
      foreign = create(:penalty_rule, shift: create(:shift, :fixed_time, business: create(:business)))

      [ sibling, foreign ].each do |other|
        expect { described_class.assign(shift: shift, rows: [ { "id" => other.id, "deduction_value" => 1 } ]) }
          .to raise_error(ActiveRecord::RecordNotFound)
        expect(other.reload.deduction_value).to eq(50)
      end
    end
  end

  it "keeps the Workforce contract free of Attendance & Payroll references" do
    source = File.read(Rails.root.join("app/services/shifts/penalty_rule_settings.rb"))
    code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

    expect(code).not_to match(/\bAttendance::|\bPayroll::|\bPenaltyRule\b|penalty_rules/)
  end
end
