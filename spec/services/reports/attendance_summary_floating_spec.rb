require "rails_helper"

# Reports::AttendanceSummary and a floating employee's records (NULL branch):
# never attributed to a branch — not even the one they punched at — and always
# counted in the unrestricted business-wide summary.
RSpec.describe Reports::AttendanceSummary, "floating employees" do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:day)      { Date.current - 1 }
  let(:floating) { create(:user, business: business, allow_biometric_attendance: true) }
  let(:regular)  { create(:user, business: business) }

  before do
    create(:shift_assignment, :floating, user: floating, shift: shift)
    assignment = create(:shift_assignment, user: regular, shift: shift, branch: branch_a)
    create(:attendance_record, user: regular, branch: branch_a, shift_assignment: assignment, work_date: day)
    Attendance::PunchService.call(employee: floating, punched_at: business.timezone_object.local(day.year, day.month, day.day, 10),
                                  business: business, device: create(:biometric_device, business: business, branch: branch_a))
  end

  def user_ids(summary) = summary[:employees].map { |row| row[:user_id] }

  it "keeps the floating employee out of the branch they punched at" do
    summary = described_class.call(business: business, branch: branch_a, start_date: day, end_date: day)

    expect(user_ids(summary)).to eq([ regular.id ])
  end

  it "keeps the floating employee out of a branch-restricted summary" do
    summary = described_class.call(business: business, branch_ids: [ branch_a.id ], start_date: day, end_date: day)

    expect(user_ids(summary)).to eq([ regular.id ])
  end

  it "counts the floating employee in the business-wide summary and its totals" do
    summary = described_class.call(business: business, start_date: day, end_date: day)

    expect(user_ids(summary)).to match_array([ regular.id, floating.id ])
    expect(summary[:totals][:total_days]).to eq(2)
  end
end
