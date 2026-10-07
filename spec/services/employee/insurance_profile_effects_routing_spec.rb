require "rails_helper"

# Pilot 8 — Employee Insurance Profile, M3: the two Workforce callers go through
# the Workforce contract Employee::InsuranceProfileEffects instead of naming
# Attendance & Payroll. The behaviour is unchanged and stays pinned by
# spec/characterization/workforce/employee_insurance_*_spec.rb; this spec pins the
# routing itself (and M6 will enforce the boundary).
RSpec.describe "Employee insurance profile → Employee::InsuranceProfileEffects routing" do
  let(:contract) { Employee::InsuranceProfileEffects }
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, business: business) }

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = contract.instance_variable_get(:@handler)
    contract.instance_variable_set(:@handler, handler)
    yield
  ensure
    contract.instance_variable_set(:@handler, original)
  end

  def save_profile(attrs = { insured: true, employee_contribution_amount: 500, employer_contribution_amount: 900,
                             insurance_start_date: Date.new(2026, 1, 1) })
    Employee::InsuranceProfileUpdater.call(user_id: employee.id, actor: actor, attrs: attrs)
  end

  def audits = AuditLog.where(auditable_type: "EmployeeInsuranceProfile")

  describe "Employee::InsuranceProfileUpdater → profile_changed" do
    it "A. a successful save calls profile_changed once with the employee and the actor, after the profile and its audit are committed" do
      seen = nil
      depth = ActiveRecord::Base.connection.open_transactions
      handler = Module.new do
        define_singleton_method(:payroll_notice_for) { |user:| :none }
        define_singleton_method(:profile_changed) do |user:, actor:|
          seen = { user: user, actor: actor, open_transactions: ActiveRecord::Base.connection.open_transactions,
                   profile_saved: EmployeeInsuranceProfile.exists?(user_id: user.id),
                   audited: AuditLog.exists?(auditable_type: "EmployeeInsuranceProfile", action: "insurance_profile_created") }
        end
      end

      result = with_handler(handler) { save_profile }

      expect(result.ok?).to be(true)
      expect(seen).to eq(user: employee, actor: actor, open_transactions: depth, profile_saved: true, audited: true)
    end

    it "A. through the registered implementation it still recalculates (same call and arguments as before M3)" do
      allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for)

      save_profile

      expect(Payroll::EntryRecalculator).to have_received(:recalculate_all_open_periods_for)
        .once.with(user: employee, triggered_by: actor)
    end

    it "B. a failed save never calls the contract" do
      handler = double("handler", profile_changed: nil, payroll_notice_for: :none)

      result = with_handler(handler) { save_profile(insured: true, insurance_start_date: nil) }

      expect(result.ok?).to be(false)
      expect(handler).not_to have_received(:profile_changed)
    end

    it "C. a raising implementation is rescued and logged as before; profile and audit stay; the result is ok" do
      handler = double("handler", payroll_notice_for: :none)
      allow(handler).to receive(:profile_changed).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:error)

      result = with_handler(handler) { save_profile }

      expect(result.ok?).to be(true)
      expect(employee.reload.employee_insurance_profile).to be_present
      expect(audits.pluck(:action)).to eq([ "insurance_profile_created" ])
      expect(Rails.logger).to have_received(:error)
        .with("[Employee::InsuranceProfileUpdater] payroll recalc failed user=#{employee.id}: StandardError: boom")
    end

    it "C. no registered handler is treated the same way (NotRegistered is rescued and logged)" do
      allow(Rails.logger).to receive(:error)

      result = with_handler(nil) { save_profile }

      expect(result.ok?).to be(true)
      expect(Rails.logger).to have_received(:error).with(/payroll recalc failed .*Employee::InsuranceProfileEffects::NotRegistered/)
    end
  end

  describe "Admin::EmployeeInsuranceProfilesController → payroll_notice_for", type: :request do
    before { sign_in create(:user, :owner, business: business) }

    def rendered_notices
      (contract::NOTICES - [ :none ]).select do |key|
        response.body.include?(CGI.escapeHTML(I18n.t("insurance.payroll_notice.#{key}")))
      end
    end

    it "D. the edit form renders whatever notice the contract returns, for the employee being edited" do
      contract::NOTICES.each do |notice|
        handler = double("handler", profile_changed: nil, payroll_notice_for: notice)

        with_handler(handler) { get edit_admin_user_employee_insurance_profile_path(employee) }

        expect(handler).to have_received(:payroll_notice_for).with(user: employee)
        expect(rendered_notices).to eq(notice == :none ? [] : [ notice ])
      end
    end

    it "D. the update path asks the contract too (re-rendered form after an invalid submission)" do
      handler = double("handler", profile_changed: nil, payroll_notice_for: :finalized)

      with_handler(handler) do
        patch admin_user_employee_insurance_profile_path(employee),
              params: { employee_insurance_profile: { insured: "1", insurance_start_date: "" } }
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(rendered_notices).to eq([ :finalized ])
    end
  end

  it "neither caller names Attendance & Payroll any more" do
    %w[app/services/employee/insurance_profile_updater.rb app/controllers/admin/employee_insurance_profiles_controller.rb].each do |path|
      code = File.read(Rails.root.join(path)).each_line.reject { |line| line.lstrip.start_with?("#") }.join

      expect(code).not_to match(/\bPayroll::|\bPayrollPeriod\b|\bPayrollEntry\b|payroll_entries|EntryRecalculator/), path
      expect(code).to include("Employee::InsuranceProfileEffects.")
    end
  end
end
