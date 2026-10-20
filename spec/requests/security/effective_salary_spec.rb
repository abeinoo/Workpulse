require "rails_helper"

# The effective salary (decisions of 2026-10-19): a profile entered with a future
# effective_from does not replace the salary in force before that date. The
# previous profile stays effective until then; from the effective business day
# (BusinessDay: the business timezone and day-start hour) the new one is. Salary
# display, the salary API, the advance limit and payroll all select the same
# profile (SalaryProfile.effective_for).
RSpec.describe "Effective salary", type: :request do
  let(:zone)     { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:business) do
    create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6, max_salary_advance_percentage: 50)
  end
  let(:employee) { create(:user, business: business) }

  def at(*args) = zone.local(*args)

  # Entered in order: historical, current, then the scheduled raise (which
  # becomes `active` at once, as SalaryProfile always did).
  let!(:historical) { create(:salary_profile, user: employee, base_amount: 4_000, effective_from: Date.new(2025, 6, 1)) }
  let!(:current)    { create(:salary_profile, user: employee, base_amount: 5_000, effective_from: Date.new(2026, 1, 1)) }
  let!(:scheduled)  do
    travel_to(at(2026, 3, 10, 12)) do
      Salary::ProfileUpdater.call(user: employee, actor: employee, source: "api",
                                  params: { salary_type: "monthly", base_amount: 6_000, currency: "SAR",
                                            effective_from: Date.new(2026, 3, 15) }).profile
    end
  end

  def selected_by_every_consumer
    today   = SalaryProfile.effective_date_for(business)
    payroll = Salary::DailyRateCalculator.for(user: employee, business: business, date: today).profile
    scope   = SalaryProfilePolicy::Scope.new(employee, SalaryProfile).resolve.where(user: employee).to_a
    limit   = Salary::AdvanceEligibilityCalculator.for(user: employee)

    { current_for: SalaryProfile.current_for(employee), payroll: payroll, scope: scope.sole,
      advance_max: limit.max_amount }
  end

  it "keeps the scheduled profile stored and active, the earlier ones stored" do
    expect(employee.salary_profiles.order(:effective_from)).to eq([ historical, current, scheduled ])
    expect(scheduled).to be_active
    expect(current.reload).not_to be_active
  end

  it "before the effective date: the current profile, everywhere" do
    travel_to(at(2026, 3, 14, 23)) do
      expect(selected_by_every_consumer).to eq(current_for: current, payroll: current, scope: current, advance_max: 2_500.0)
    end
  end

  it "on the effective date, before the business day starts: still the current profile" do
    travel_to(at(2026, 3, 15, 5, 59)) do
      expect(SalaryProfile.effective_date_for(business)).to eq(Date.new(2026, 3, 14))
      expect(selected_by_every_consumer).to eq(current_for: current, payroll: current, scope: current, advance_max: 2_500.0)
    end
  end

  it "on the effective business day: the scheduled profile, everywhere" do
    travel_to(at(2026, 3, 15, 6, 0)) do
      expect(selected_by_every_consumer).to eq(current_for: scheduled, payroll: scheduled, scope: scheduled, advance_max: 3_000.0)
    end
  end

  it "after the effective date: the scheduled profile, the same on repeated queries" do
    travel_to(at(2026, 4, 20, 12)) do
      2.times do
        expect(selected_by_every_consumer).to eq(current_for: scheduled, payroll: scheduled, scope: scheduled, advance_max: 3_000.0)
      end
    end
  end

  it "prices payroll periods with the profile effective in them" do
    march = create(:payroll_period, business: business, period_year: 2026, period_month: 3)
    april = create(:payroll_period, business: business, period_year: 2026, period_month: 4)

    expect(Payroll::EntryCalculator.rate_calculator_for(user: employee, business: business, period: march).profile).to eq(current)
    expect(Payroll::EntryCalculator.rate_calculator_for(user: employee, business: business, period: april).profile).to eq(scheduled)
  end

  it "breaks an effective-date tie by the most recently entered profile" do
    correction = create(:salary_profile, user: employee, base_amount: 5_100, effective_from: Date.new(2026, 1, 1))

    travel_to(at(2026, 3, 1, 12)) do
      expect(selected_by_every_consumer).to include(current_for: correction, payroll: correction, scope: correction)
    end
  end

  it "has no salary in force before a new hire's first profile takes effect" do
    hire = create(:user, business: business)
    create(:salary_profile, user: hire, effective_from: Date.new(2026, 5, 1))

    travel_to(at(2026, 4, 20, 12)) do
      expect(SalaryProfile.current_for(hire)).to be_nil
      expect(Salary::AdvanceEligibilityCalculator.for(user: hire)).to be_no_profile
    end
  end

  describe "salary display" do
    let(:manager) do
      role = business.permission_roles.create!(name: "Payroll", permissions: %w[view_employees view_payroll],
                                               permission_scopes: { "view_employees" => "business", "view_payroll" => "business" })
      create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    end

    it "API and employee page show the current profile before the date, never the scheduled one" do
      travel_to(at(2026, 3, 14, 12)) do
        sign_in manager
        get "/api/v1/users/#{employee.id}/salary_profiles", as: :json
        expect(api_data.map { |p| p["id"] }).to eq([ current.id ])

        get "/api/v1/users/#{employee.id}/salary_profiles/#{scheduled.id}", as: :json
        expect(response).to have_http_status(:not_found)
      end
    end

    it "the employee page shows the current amount before the date and the new one after" do
      sign_in manager
      travel_to(at(2026, 3, 14, 12)) do
        get admin_user_path(employee)
        expect(response.body).to include("5,000.00")
        expect(response.body).not_to include("6,000.00")
      end

      travel_to(at(2026, 3, 16, 12)) do
        get admin_user_path(employee)
        expect(response.body).to include("6,000.00")
        expect(response.body).not_to include("5,000.00")
      end
    end

    it "the employee sees their own current profile, not the scheduled one" do
      travel_to(at(2026, 3, 14, 12)) do
        sign_in employee
        get "/api/v1/users/#{employee.id}/salary_profiles", as: :json
        expect(api_data.map { |p| p["id"] }).to eq([ current.id ])
      end
    end
  end
end
