require "rails_helper"

# R3.2 G1: the attendance requirement history row (roadmap §2 W, §8). Model-level
# rules; the database guards are in employee_attendance_requirements_guard_spec.rb.
RSpec.describe EmployeeAttendanceRequirement, type: :model do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:hr)       { create(:user, business: business) }

  def build_row(**attrs)
    build(:employee_attendance_requirement, user: employee, changed_by: hr, **attrs)
  end

  it "records required and not required for creation and HR changes" do
    expect(build_row(status: "required", source: "creation")).to be_valid
    expect(build_row(status: "not_required", source: "hr_change", reason: "Remote role")).to be_valid
  end

  it "refuses an unknown status or source" do
    expect(build_row(status: "exempt")).not_to be_valid
    expect(build_row(source: "import")).not_to be_valid
  end

  it "records not reviewed only from the backfill" do
    expect(build_row(status: "not_reviewed", source: "creation").tap(&:valid?).errors)
      .to be_of_kind(:status, :not_reviewed_backfill_only)
    expect(build_row(status: "not_reviewed", source: "hr_change")).not_to be_valid
    expect(build_row(status: "not_reviewed", source: "backfill", effective_date_basis: "hire_date")).to be_valid
  end

  it "records the effective-date basis only on backfill rows" do
    expect(build_row(source: "creation", effective_date_basis: "hire_date").tap(&:valid?).errors)
      .to be_of_kind(:effective_date_basis, :backfill_only)
    expect(build_row(source: "backfill", effective_date_basis: "unknown")).not_to be_valid
  end

  it "requires an effective date" do
    expect(build_row(effective_from: nil)).not_to be_valid
  end

  it "refuses an employee or an actor from another business" do
    stranger = create(:user, business: create(:business))
    expect(build_row(user: stranger, business: business).tap(&:valid?).errors).to be_of_kind(:user, :other_business)
    expect(build_row(changed_by: stranger).tap(&:valid?).errors).to be_of_kind(:changed_by, :other_business)
  end

  it "is read-only once saved" do
    row = build_row.tap(&:save!)
    expect(row).to be_readonly
    expect { row.update!(status: "not_required") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { row.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(row.reload.status).to eq("required")
  end

  it "orders a timeline by effective date, then id — the latest row of a date last" do
    later  = create(:employee_attendance_requirement, user: employee, changed_by: hr, effective_from: Date.new(2026, 3, 1))
    first  = create(:employee_attendance_requirement, user: employee, changed_by: hr, effective_from: Date.new(2026, 1, 1))
    second = create(:employee_attendance_requirement, :not_required, :hr_change, user: employee, changed_by: hr,
                                                                                 effective_from: Date.new(2026, 1, 1))
    expect(described_class.where(user: employee).in_timeline_order).to eq([ first, second, later ])
  end
end
