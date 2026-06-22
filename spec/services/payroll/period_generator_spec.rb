require "rails_helper"

# Verifies employee inclusion rules for payroll generation.
#
# Deactivated employees MUST appear in payroll when they have payroll-relevant
# activity during the period (attendance, adjustments, or active advances).
# They must NOT appear when they have no such activity.
RSpec.describe Payroll::PeriodGenerator, type: :service do
  let(:business) { create(:business, working_days_per_month: 22) }
  let(:actor)    { create(:user, business: business) }

  let(:year)         { 2025 }
  let(:month)        { 6 }
  let(:period_start) { Date.new(year, month, 1) }
  let(:period_end)   { period_start.end_of_month }

  # Track which users the generator attempts to build payroll entries for.
  let(:included_user_ids) { [] }

  before do
    allow(Payroll::EntryCalculator).to receive(:call) do |args|
      included_user_ids << args[:user].id
    end
  end

  def generate
    described_class.call(
      business:     business,
      year:         year,
      month:        month,
      generated_by: actor
    )
  end

  describe "active employees" do
    it "includes an active employee with no attendance" do
      employee = create(:user, business: business, active: true)
      generate
      expect(included_user_ids).to include(employee.id)
    end

    it "includes an active employee with attendance during the period" do
      employee = create(:user, business: business, active: true)
      create(:attendance_record, user: employee, business: business, work_date: period_start + 5)
      generate
      expect(included_user_ids).to include(employee.id)
    end
  end

  describe "inactive employees with attendance records" do
    it "includes an inactive employee with attendance during the period" do
      employee = create(:user, :inactive, business: business)
      create(:attendance_record, user: employee, business: business, work_date: period_start + 10)
      generate
      expect(included_user_ids).to include(employee.id)
    end

    it "includes an employee deactivated mid-period who already has attendance" do
      employee = create(:user, business: business, active: true)
      create(:attendance_record, user: employee, business: business, work_date: period_start + 5)
      employee.update!(active: false)
      generate
      expect(included_user_ids).to include(employee.id)
    end

    it "excludes an inactive employee with attendance only outside the period" do
      employee = create(:user, :inactive, business: business)
      create(:attendance_record, user: employee, business: business, work_date: period_start - 1)
      generate
      expect(included_user_ids).not_to include(employee.id)
    end
  end

  describe "inactive employees with payroll adjustments" do
    it "includes an inactive employee with a payroll adjustment for this period" do
      employee       = create(:user, :inactive, business: business)
      payroll_period = create(:payroll_period, business: business, period_year: year, period_month: month)
      create(:payroll_adjustment, payroll_period: payroll_period, user: employee, business: business,
             period_year: year, period_month: month)
      generate
      expect(included_user_ids).to include(employee.id)
    end

    it "excludes an inactive employee with adjustments only in a different period" do
      employee        = create(:user, :inactive, business: business)
      other_period    = create(:payroll_period, business: business, period_year: year, period_month: month - 1)
      create(:payroll_adjustment, payroll_period: other_period, user: employee, business: business,
             period_year: year, period_month: month - 1)
      generate
      expect(included_user_ids).not_to include(employee.id)
    end
  end

  describe "inactive employees with salary advances" do
    it "includes an inactive employee with an active advance with remaining balance" do
      employee = create(:user, :inactive, business: business)
      create(:advance, user: employee, remaining_amount: 500.0, status: :active)
      generate
      expect(included_user_ids).to include(employee.id)
    end

    it "excludes an inactive employee whose advance is fully repaid" do
      employee = create(:user, :inactive, business: business)
      create(:advance, :fully_repaid, user: employee)
      generate
      expect(included_user_ids).not_to include(employee.id)
    end
  end

  describe "inactive employees with no payroll activity" do
    it "excludes an inactive employee with no attendance, adjustments, or advances" do
      employee = create(:user, :inactive, business: business)
      generate
      expect(included_user_ids).not_to include(employee.id)
    end

    it "does not bleed active advances from another business into inclusion" do
      other_business = create(:business)
      outsider       = create(:user, :inactive, business: other_business)
      create(:advance, user: outsider, remaining_amount: 500.0, status: :active)
      generate
      expect(included_user_ids).not_to include(outsider.id)
    end
  end
end
