require "rails_helper"

# Pilot 4 — Penalty Rules (M7): PenaltyRule lives physically in Attendance &
# Payroll (app/models/attendance_payroll/, the collapsed directory from
# config/initializers/attendance_payroll_autoload.rb) but keeps its top-level
# constant, its table and its associations. Guards against an accidental
# un-collapse, namespace, table or association change.
RSpec.describe "Architecture: Attendance & Payroll penalty rule model location" do
  it "loads as a top-level constant from app/models/attendance_payroll/" do
    expect(PenaltyRule.name).to eq("PenaltyRule") # resolving the constant also triggers the autoload
    path = Object.const_source_location("PenaltyRule").first
    expect(path).to eq(Rails.root.join("app/models/attendance_payroll/penalty_rule.rb").to_s)
  end

  it "no longer has a top-level model file" do
    expect(File).not_to exist(Rails.root.join("app/models/penalty_rule.rb"))
  end

  it "keeps penalty_rules as its table" do
    expect(PenaltyRule.table_name).to eq("penalty_rules")
  end

  it "is not namespaced under AttendancePayroll" do
    expect(defined?(::AttendancePayroll)).to be_nil.or(satisfy { !::AttendancePayroll.const_defined?(:PenaltyRule, false) })
  end

  it "resolves the same classes from both sides of the shift association" do
    belongs = PenaltyRule.reflect_on_association(:shift)
    expect(belongs).to have_attributes(macro: :belongs_to)
    expect(belongs.klass).to equal(Shift)

    has_many = Shift.reflect_on_association(:penalty_rules)
    expect(has_many).to have_attributes(macro: :has_many)
    expect(has_many.klass).to equal(PenaltyRule)
  end

  it "keeps the Shift association options unchanged (autosave, dependent destroy)" do
    expect(Shift.reflect_on_association(:penalty_rules).options).to eq(dependent: :destroy, autosave: true)
  end
end
