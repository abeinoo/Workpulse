require "rails_helper"

# PayrollEntry#salary_breakdown — the per-profile record of how base_salary
# was built (Payroll::BasicSalaryCalculator). Editable with the entry while
# the period is open; frozen once the period is finalized or paid.
RSpec.describe PayrollEntry, "salary breakdown" do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business) }
  let(:breakdown) do
    { "version" => 1, "total" => "500.00",
      "portions" => [ { "salary_profile_id" => 1, "salary_type" => "daily", "amount" => "500.00" } ] }
  end
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: create(:user, business: business),
                           base_salary: 500, net_salary: 500, salary_breakdown: breakdown)
  end

  describe "column (migration 20261104100000)" do
    subject(:column) { described_class.columns_hash["salary_breakdown"] }

    it "is a nullable jsonb column without a default" do
      expect(column.sql_type).to eq("jsonb")
      expect(column.null).to be(true)
      expect(column.default).to be_nil
    end

    it "leaves entries calculated before it existed with no breakdown" do
      legacy = create(:payroll_entry, payroll_period: period, user: create(:user, business: business),
                                      base_salary: 500, net_salary: 500)
      expect(legacy.salary_breakdown).to be_nil
      expect(legacy.salary_breakdown_portions).to eq([])
      expect(legacy).not_to be_split_salary
    end

    it "round-trips decimal strings exactly" do
      expect(entry.reload.salary_breakdown).to eq(breakdown)
    end
  end

  %w[draft under_review branch_review_completed].each do |status|
    it "can be replaced while the period is #{status}" do
      period.update!(status: status)
      expect(entry.update(salary_breakdown: breakdown.merge("total" => "600.00"))).to be(true)
    end
  end

  %w[finalized paid].each do |status|
    context "once the period is #{status}" do
      before { entry && period.update!(status: status) }

      it "refuses any change to the breakdown" do
        expect(entry.update(salary_breakdown: breakdown.merge("total" => "600.00"))).to be(false)
        expect(entry.errors.of_kind?(:salary_breakdown, :locked)).to be(true)
        expect(entry.reload.salary_breakdown).to eq(breakdown)
      end

      it "refuses clearing it" do
        expect(entry.update(salary_breakdown: nil)).to be(false)
      end

      it "still allows updates that leave the breakdown alone" do
        expect(entry.update(notes: "paid by bank transfer")).to be(true)
      end
    end
  end

  it "has an English and an Arabic message for the lock" do
    %i[en ar].each do |locale|
      message = I18n.t("activerecord.errors.models.payroll_entry.attributes.salary_breakdown.locked", locale: locale)
      expect(message).not_to include("translation missing")
    end
  end
end
