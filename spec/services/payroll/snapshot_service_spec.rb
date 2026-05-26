require "rails_helper"

RSpec.describe Payroll::SnapshotService do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, :super_admin, business: business) }
  let(:period)   { create(:payroll_period, business: business) }
  let(:u1)       { create(:user, business: business) }
  let(:u2)       { create(:user, business: business) }

  before do
    create(:payroll_entry, payroll_period: period, user: u1,
           base_salary: 5000, net_salary: 4800, total_overtime: 300,
           total_deductions: 200, total_bonuses: 0)
    create(:payroll_entry, payroll_period: period, user: u2,
           base_salary: 6000, net_salary: 5500, total_overtime: 0,
           total_deductions: 100, total_bonuses: 200)
  end

  subject(:result) { described_class.call(period: period, taken_by: actor) }

  it "succeeds" do
    expect(result.success?).to be true
  end

  it "creates a PayrollSnapshot record" do
    expect { result }.to change(PayrollSnapshot, :count).by(1)
  end

  it "stores correct aggregate totals" do
    snapshot = result.snapshot
    expect(snapshot.employee_count).to eq(2)
    expect(snapshot.total_net.to_f).to     be_within(0.01).of(10300.0)
    expect(snapshot.total_base.to_f).to    be_within(0.01).of(11000.0)
    expect(snapshot.total_overtime.to_f).to be_within(0.01).of(300.0)
    expect(snapshot.total_deductions.to_f).to be_within(0.01).of(300.0)
    expect(snapshot.total_bonuses.to_f).to be_within(0.01).of(200.0)
  end

  it "stores per-employee details" do
    snapshot = result.snapshot
    expect(snapshot.employee_details.size).to eq(2)
    user_ids = snapshot.employee_details.map { |e| e["user_id"] }
    expect(user_ids).to include(u1.id, u2.id)
  end

  it "uses the correct trigger" do
    expect(result.snapshot.trigger).to eq("pre_regenerate")
  end

  it "accepts a custom trigger" do
    result = described_class.call(period: period, taken_by: actor, trigger: "manual")
    expect(result.snapshot.trigger).to eq("manual")
  end

  describe "diff_from" do
    it "calculates numeric deltas between two snapshots" do
      snap_a = result.snapshot

      # Simulate a second snapshot with different totals by manually building one
      snap_b = create(:payroll_snapshot,
        payroll_period:  period,
        taken_by:        actor,
        employee_count:  2,
        total_net:       10000,
        total_base:      11000,
        total_overtime:  200,
        total_deductions: 400,
        total_bonuses:   100,
        employee_details: []
      )

      diff = snap_b.diff_from(snap_a)
      expect(diff[:net].to_f).to        be_within(0.01).of(-300.0)   # 10000 - 10300
      expect(diff[:deductions].to_f).to be_within(0.01).of(100.0)    # 400 - 300
    end
  end
end
