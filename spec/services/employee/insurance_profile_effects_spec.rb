require "rails_helper"

# Pilot 8 — Employee Insurance Profile, M2: the Workforce contract
# Employee::InsuranceProfileEffects and its Attendance & Payroll implementation
# Payroll::InsuranceProfileEffects. Employee::InsuranceProfileUpdater and
# Admin::EmployeeInsuranceProfilesController are routed through the contract
# since M3 (insurance_profile_effects_routing_spec.rb); the behaviour stays
# pinned by spec/characterization/workforce/employee_insurance_*_spec.rb.
RSpec.describe Employee::InsuranceProfileEffects do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, business: business) }

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  def period(month, status)
    create(:payroll_period, business: business, period_year: 2026, period_month: month, working_days: 22, status: status)
  end

  describe "registration" do
    it "has the Attendance & Payroll implementation registered at boot" do
      expect(described_class.handler).to equal(Payroll::InsuranceProfileEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      incomplete = Module.new { def self.profile_changed(user:, actor:) = nil }

      expect { described_class.register(incomplete) }.to raise_error(ArgumentError, /payroll_notice_for/)
      expect(described_class.handler).to equal(Payroll::InsuranceProfileEffects)
    end

    it "raises NotRegistered (a StandardError) instead of silently skipping when no handler is registered" do
      expect(described_class::NotRegistered.ancestors).to include(StandardError)
      with_handler(nil) do
        expect { described_class.profile_changed(user: employee, actor: actor) }.to raise_error(described_class::NotRegistered)
        expect { described_class.payroll_notice_for(user: employee) }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    let(:handler) { double("handler", profile_changed: :handler_result, payroll_notice_for: :active) }

    it "profile_changed passes the employee and the actor unchanged, and returns nothing" do
      with_handler(handler) do
        expect(described_class.profile_changed(user: employee, actor: actor)).to be_nil
      end
      expect(handler).to have_received(:profile_changed).once.with(user: employee, actor: actor)
    end

    it "profile_changed propagates a handler error, so the caller can isolate it (as the updater does today)" do
      allow(handler).to receive(:profile_changed).and_raise(StandardError, "boom")

      with_handler(handler) do
        expect { described_class.profile_changed(user: employee, actor: actor) }.to raise_error(StandardError, "boom")
      end
    end

    it "payroll_notice_for passes the employee and returns the handler's notice" do
      with_handler(handler) { expect(described_class.payroll_notice_for(user: employee)).to eq(:active) }
      expect(handler).to have_received(:payroll_notice_for).with(user: employee)
    end

    it "payroll_notice_for accepts only the four notices — no payroll record or relation crosses the contract" do
      [ PayrollPeriod.all, period(6, "draft"), "active", nil ].each do |leak|
        allow(handler).to receive(:payroll_notice_for).and_return(leak)

        with_handler(handler) do
          expect { described_class.payroll_notice_for(user: employee) }.to raise_error(ArgumentError, /expected one of/)
        end
      end
      expect(described_class::NOTICES).to eq(%i[none active mixed finalized])
    end
  end

  describe "through the Attendance & Payroll implementation" do
    it "profile_changed re-derives the entry in open periods and leaves locked periods alone" do
      create(:salary_profile, :monthly, user: employee, base_amount: 5_000.0, effective_from: Date.new(2025, 1, 1))
      open   = period(6, "under_review")
      locked = period(5, "finalized")
      [ open, locked ].each { |p| Payroll::EntryCalculator.call(period: p, user: employee, business: business) }
      create(:employee_insurance_profile, user: employee, business: business, employee_contribution_amount: 500,
                                          insurance_start_date: Date.new(2025, 1, 1))

      described_class.profile_changed(user: employee, actor: actor)

      expect(open.payroll_entries.find_by(user: employee)).to have_attributes(insured: true, employee_insurance_amount: 500)
      expect(locked.payroll_entries.find_by(user: employee).insured).to be(false)
    end

    it "profile_changed is the recalculation the updater triggers today (same call, same arguments)" do
      allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for)

      described_class.profile_changed(user: employee, actor: actor)

      expect(Payroll::EntryRecalculator).to have_received(:recalculate_all_open_periods_for)
        .once.with(user: employee, triggered_by: actor)
    end

    {
      none:      [],
      active:    [ [ 5, "paid" ], [ 6, "under_review" ] ],
      mixed:     [ [ 6, "under_review" ], [ 7, "draft" ] ],
      finalized: [ [ 5, "paid" ], [ 6, "finalized" ] ]
    }.each do |notice, periods|
      it "payroll_notice_for → :#{notice}" do
        periods.each { |month, status| create(:payroll_entry, user: employee, payroll_period: period(month, status)) }

        expect(described_class.payroll_notice_for(user: employee)).to eq(notice)
      end
    end

    it "payroll_notice_for ignores other employees' entries" do
      create(:payroll_entry, user: create(:user, business: business), payroll_period: period(6, "draft"))

      expect(described_class.payroll_notice_for(user: employee)).to eq(:none)
    end
  end

  describe "parity with the edit-form notice", type: :request do
    it "the contract and the edit form agree in every state" do
      sign_in create(:user, :owner, business: business)
      states = {
        none: [], active: [ [ 6, "draft" ] ], mixed: [ [ 7, "draft" ] ], finalized: nil
      }
      states.each do |notice, periods|
        if notice == :finalized
          PayrollPeriod.where(business: business).update_all(status: "finalized")
        else
          periods.each { |month, status| create(:payroll_entry, user: employee, payroll_period: period(month, status)) }
        end

        expect(described_class.payroll_notice_for(user: employee)).to eq(notice)
        get edit_admin_user_employee_insurance_profile_path(employee)
        rendered = (described_class::NOTICES - [ :none ]).select do |key|
          response.body.include?(CGI.escapeHTML(I18n.t("insurance.payroll_notice.#{key}")))
        end
        expect(rendered).to eq(notice == :none ? [] : [ notice ])
      end
    end
  end

  it "keeps the Workforce contract free of Attendance & Payroll references" do
    source = File.read(Rails.root.join("app/services/employee/insurance_profile_effects.rb"))
    code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

    expect(code).not_to match(/\bPayroll\b|\bAttendance::|PayrollPeriod|PayrollEntry|EntryRecalculator|payroll_entries/)
  end
end
