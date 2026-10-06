require "rails_helper"

# SEC-M2-4: Admin::EmployeeObligationsController takes user_id from params, and
# EmployeeObligation had no same-business check — so a manager in business A
# could record an obligation (payroll deduction) against an employee of
# business B, and Payroll::ObligationDeductor (which selected obligations by
# user only) would deduct it from business B's payroll. The model now rejects
# a user / creator of another business (every write path), and the deductor
# only applies obligations of the period's own business.
RSpec.describe "Security: payroll deduction (obligation) business boundaries", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  # Business-wide manage_obligations scope, so only the business boundary is under test
  # (scope rules: employee_obligations_authorization_spec.rb).
  let(:manager)  { api_user_with(business, :view_employees, :manage_obligations, scopes: { "manage_obligations" => "business" }) }
  let(:employee) { create(:user, business: business) }
  let(:foreign_employee) { create(:user, business: other) }

  let(:month) { Date.current.month }
  let(:year)  { Date.current.year }

  def obligation_params(user)
    { employee_obligation: { user_id: user.id, obligation_type: "cash_loan", title: "Laptop loan",
                             total_amount: 1_000, installment_amount: 100,
                             start_month: month, start_year: year, auto_deduct: "1" } }
  end

  describe "creating an obligation" do
    before { sign_in manager }

    # Refused by the policy (the foreign user is outside every manage_obligations
    # scope) before the model's same-business validation is reached.
    it "rejects a user_id of another business (nothing created)" do
      expect { post admin_employee_obligations_path, params: obligation_params(foreign_employee) }
        .not_to change(EmployeeObligation, :count)
      expect(response).to redirect_to(root_path)
      expect(EmployeeObligation.where(user: foreign_employee)).to be_empty
    end

    it "still accepts a user_id of the same business" do
      expect { post admin_employee_obligations_path, params: obligation_params(employee) }
        .to change(EmployeeObligation, :count).by(1)
      obligation = EmployeeObligation.last
      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation).to have_attributes(user: employee, business: business, created_by: manager)
    end
  end

  describe "updating an obligation" do
    let!(:obligation) do
      create(:employee_obligation, business: business, user: employee, created_by: manager,
                                   start_month: month, start_year: year)
    end

    before { sign_in manager }

    it "rejects moving it to a user of another business" do
      patch admin_employee_obligation_path(obligation), params: { employee_obligation: { user_id: foreign_employee.id } }
      expect(response).to redirect_to(root_path)
      expect(obligation.reload.user).to eq(employee)
    end

    it "still accepts a same-business edit" do
      patch admin_employee_obligation_path(obligation), params: { employee_obligation: { title: "Phone loan" } }
      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload.title).to eq("Phone loan")
    end
  end

  describe "model validation (every write path)" do
    it "rejects a user or creator of another business" do
      obligation = build(:employee_obligation, business: business, user: foreign_employee)
      expect(obligation).not_to be_valid
      expect(obligation.errors[:user]).to be_present

      obligation = build(:employee_obligation, business: business, created_by: create(:user, business: other))
      expect(obligation).not_to be_valid
      expect(obligation.errors[:created_by]).to be_present
    end

    it "accepts same-business references (factory defaults)" do
      expect(build(:employee_obligation, business: business)).to be_valid
    end

    it "does not re-validate an existing row when unrelated fields change" do
      legacy = build(:employee_obligation, business: business, user: foreign_employee)
      legacy.save!(validate: false)
      expect(legacy.update(title: "Renamed")).to be(true)
    end
  end

  describe "applying deductions in payroll" do
    let(:foreign_period) { create(:payroll_period, business: other, period_year: year, period_month: month) }

    it "never deducts an obligation recorded under another business (e.g. created before the fix)" do
      legacy = build(:employee_obligation, business: business, user: foreign_employee, created_by: manager,
                                           start_month: month, start_year: year)
      legacy.save!(validate: false)

      result = Payroll::ObligationDeductor.call(user: foreign_employee, period: foreign_period)

      expect(result.total_amount).to eq(0)
      expect(result.items).to be_empty
      expect(ObligationDeduction.where(employee_obligation: legacy)).to be_empty
    end

    it "still deducts a same-business obligation" do
      same_business = create(:employee_obligation, business: other, user: foreign_employee,
                                                   start_month: month, start_year: year,
                                                   total_amount: 1_000, remaining_amount: 1_000, installment_amount: 100)

      result = Payroll::ObligationDeductor.call(user: foreign_employee, period: foreign_period)

      expect(result.total_amount).to eq(100)
      expect(result.items.map { |item| item.snapshot.employee_obligation }).to eq([ same_business ])
    end
  end
end
