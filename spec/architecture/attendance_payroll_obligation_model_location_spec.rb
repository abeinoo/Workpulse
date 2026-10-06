require "rails_helper"

# Milestone 2 Pilot 2 (M7): the Employee Obligations models live physically in
# Attendance & Payroll (app/models/attendance_payroll/, the collapsed directory
# from config/initializers/attendance_payroll_autoload.rb) but keep their
# top-level constants and tables. Guards against an accidental un-collapse,
# namespace or table change.
RSpec.describe "Architecture: Attendance & Payroll employee obligation model location" do
  {
    EmployeeObligation     => "employee_obligations",
    ObligationDeduction    => "obligation_deductions",
    ObligationPostponement => "obligation_postponements"
  }.each do |model, table|
    describe model.name do
      it "loads as a top-level constant from app/models/attendance_payroll/" do
        expect(model.name).to eq(model.name.demodulize) # resolving the constant also triggers the autoload
        path = Object.const_source_location(model.name).first
        expect(path).to eq(Rails.root.join("app/models/attendance_payroll/#{model.name.underscore}.rb").to_s)
      end

      it "no longer has a top-level model file" do
        expect(File).not_to exist(Rails.root.join("app/models/#{model.name.underscore}.rb"))
      end

      it "keeps #{table} as its table" do
        expect(model.table_name).to eq(table)
      end

      it "is not namespaced under AttendancePayroll" do
        expect(defined?(::AttendancePayroll)).to be_nil.or(satisfy { !::AttendancePayroll.const_defined?(model.name, false) })
      end
    end
  end

  it "is the same class every association resolves" do
    expect(Business.reflect_on_association(:employee_obligations).klass).to equal(EmployeeObligation)
    expect(User.reflect_on_association(:employee_obligations).klass).to equal(EmployeeObligation)
    expect(PayrollPeriod.reflect_on_association(:obligation_deductions).klass).to equal(ObligationDeduction)
    expect(EmployeeObligation.reflect_on_association(:obligation_deductions).klass).to equal(ObligationDeduction)
    expect(EmployeeObligation.reflect_on_association(:obligation_postponements).klass).to equal(ObligationPostponement)
    expect(EmployeeObligation.reflect_on_association(:user).klass).to equal(User)
    expect(EmployeeObligation.reflect_on_association(:created_by).klass).to equal(User)
    expect(ObligationDeduction.reflect_on_association(:employee_obligation).klass).to equal(EmployeeObligation)
    expect(ObligationDeduction.reflect_on_association(:payroll_period).klass).to equal(PayrollPeriod)
    expect(ObligationPostponement.reflect_on_association(:employee_obligation).klass).to equal(EmployeeObligation)
    expect(ObligationPostponement.reflect_on_association(:performed_by).klass).to equal(User)
  end

  it "is the class the policy and its scope resolve" do
    owner = create(:user, :owner)
    expect(Pundit::PolicyFinder.new(EmployeeObligation).policy).to equal(EmployeeObligationPolicy)
    expect(Pundit::PolicyFinder.new(EmployeeObligation.new).policy).to equal(EmployeeObligationPolicy)
    expect(EmployeeObligationPolicy::Scope.new(owner, EmployeeObligation).resolve.klass).to equal(EmployeeObligation)
  end

  it "is the class the payroll obligation services operate on" do
    business   = create(:business)
    obligation = create(:employee_obligation, business: business, start_month: 6, start_year: 2026)
    period     = create(:payroll_period, business: business, period_year: 2026, period_month: 6)

    item = Payroll::ObligationDeductor.call(user: obligation.user, period: period).items.sole

    expect(item.snapshot).to be_an_instance_of(ObligationDeduction)
    expect(item.snapshot.employee_obligation).to eq(obligation)
    expect(Payroll::ObligationInstallmentPostponer.const_get(:Result)).to be_a(Class)
    expect(ObligationPostponement::TYPES).to eq(%w[next_month extend_loan])
  end
end
