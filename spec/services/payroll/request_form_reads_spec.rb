require "rails_helper"

# Batch V — request-validation reads (D-A5), M3: Payroll::RequestFormReads, the
# Attendance & Payroll implementation of Requests::RequestFormReads. Every
# operation is exercised through the contract (so the contract's result checks
# apply) and compared with the Attendance & Payroll code the Workforce call sites
# used before M4; spec/characterization/workforce/request_validation_reads_spec.rb
# pins the screens themselves.
RSpec.describe Payroll::RequestFormReads do
  include ActiveSupport::Testing::TimeHelpers
  include ApiCharacterizationHelpers

  let(:contract) { Requests::RequestFormReads }
  let(:riyadh)   { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:business) do
    create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0, max_salary_advance_percentage: 50).tap do |b|
      b.update!(attendance_suspicious_duration_hours: 10, attendance_critical_duration_hours: 14)
    end
  end
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let!(:assignment) do
    create(:shift_assignment, business: business, user: employee, branch: branch_a, effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end
  let!(:profile) { create(:salary_profile, :monthly, user: employee, base_amount: 6420, effective_from: Date.new(2026, 1, 1)) }
  let(:no_profile_employee) do
    create(:user, business: business).tap do |u|
      create(:shift_assignment, business: business, user: u, branch: branch_a, effective_from: Date.new(2026, 1, 1), effective_to: nil)
    end
  end

  def approver(*extra, scopes: {})
    api_user_with(business, :view_requests, :approve_requests, :view_employees, *extra,
                  scopes: { "view_requests" => "business", "approve_requests" => "business", "view_employees" => "business" }.merge(scopes))
  end

  def plain_approver   = approver
  def payroll_approver = approver(:view_payroll, scopes: { "view_payroll" => "business" })
  def outside_payroll_approver = approver(:view_payroll).tap { |u| branch_b.update_column(:branch_manager_id, u.id) }
  def branch_payroll_manager   = approver(:view_payroll).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  around { |example| travel_to(riyadh.local(2026, 9, 20, 12, 0)) { example.run } }

  def salary_views = AuditLog.where(action: "view_salary")

  def limit_fields(result)
    result && result.to_h.slice(:description_key, :max_amount, :outstanding, :available, :no_profile)
  end

  describe "advance_limit" do
    it "is the calculator's limit, field for field (with a profile, with an outstanding advance, without a profile)" do
      create(:employee_request, :salary_advance, user: employee, amount: 1000, requested_for_date: Date.new(2026, 9, 3))

      [ employee, no_profile_employee ].each do |user|
        limit = contract.advance_limit(user: user)
        expect(limit).to be_a(contract::AdvanceLimit)
        expect(limit.to_h).to eq(limit_fields(Salary::AdvanceEligibilityCalculator.for(user: user)))
      end
      expect(contract.advance_limit(user: employee).to_h)
        .to eq(description_key: "monthly_basis", max_amount: 3210.0, outstanding: 1000.0, available: 2210.0, no_profile: false)
      expect(contract.advance_limit(user: no_profile_employee)).to be_no_profile
    end

    it "is nil when the business configures no percentage, and records nothing" do
      business.update!(max_salary_advance_percentage: nil)
      expect { expect(contract.advance_limit(user: employee)).to be_nil }.not_to change(AuditLog, :count)
    end
  end

  describe "advance_limit_for" do
    def limit_for(user, viewer) = contract.advance_limit_for(user: user, viewer: viewer)

    it "own form: the limit, not hidden, no audit — even for a viewer who may view salaries" do
      own_payroll_viewer = payroll_approver
      create(:salary_profile, :monthly, user: own_payroll_viewer, base_amount: 1000, effective_from: Date.new(2026, 1, 1))

      [ employee, own_payroll_viewer ].each do |user|
        view = nil
        expect { view = limit_for(user, user) }.not_to change(salary_views, :count)
        expect(view).not_to be_hidden
        expect(view.limit.to_h).to eq(limit_fields(Salary::AdvanceEligibilityCalculator.for(user: user)))
      end
    end

    it "no limit configured: limit nil, not hidden, no audit — whoever views" do
      business.update!(max_salary_advance_percentage: nil)

      [ employee, plain_approver, payroll_approver ].each do |viewer|
        view = nil
        expect { view = limit_for(employee, viewer) }.not_to change(salary_views, :count)
        expect(view.to_h).to eq(limit: nil, hidden: false)
      end
    end

    it "a viewer who may not see the salary: hidden, no figures, no audit (with or without a profile)" do
      [ plain_approver, outside_payroll_approver ].each do |viewer|
        [ employee, no_profile_employee ].each do |user|
          view = nil
          expect { view = limit_for(user, viewer) }.not_to change(salary_views, :count)
          expect(view.to_h).to eq(limit: nil, hidden: true)
        end
      end
    end

    it "computes the limit before the visibility decision, as the form did (one calculation per call)" do
      allow(Salary::AdvanceEligibilityCalculator).to receive(:for).and_call_original
      limit_for(employee, plain_approver)
      expect(Salary::AdvanceEligibilityCalculator).to have_received(:for).once.with(user: employee)
    end

    it "a viewer who may see the salary: the limit and one salary view per call, with the form's metadata" do
      actor = payroll_approver

      view = nil
      expect { view = limit_for(employee, actor) }.to change(salary_views, :count).by(1)
      expect(view).not_to be_hidden
      expect(view.limit.to_h).to eq(limit_fields(Salary::AdvanceEligibilityCalculator.for(user: employee)))

      audit = salary_views.sole
      expect([ audit.actor_id, audit.auditable_type, audit.auditable_id, audit.business_id ])
        .to eq([ actor.id, "User", employee.id, business.id ])
      expect(audit.metadata).to eq("source" => "request_advance_limit", "self_view" => false, "salary_profile_ids" => [ profile.id ])
      expect(audit.changes_json).to eq({})

      expect { limit_for(employee, actor) }.to change(salary_views, :count).by(1)
    end

    it "a viewer who may see the salary of an employee without a profile: the no-profile limit, no audit" do
      view = nil
      expect { view = limit_for(no_profile_employee, payroll_approver) }.not_to change(salary_views, :count)
      expect(view).not_to be_hidden
      expect(view.limit).to be_no_profile
    end

    it "hierarchy-default view_payroll over the employee's branch and the business owner: visible and audited" do
      [ branch_payroll_manager, create(:user, :owner, business: business) ].each do |viewer|
        expect { expect(limit_for(employee, viewer)).not_to be_hidden }.to change(salary_views, :count).by(1)
        expect(salary_views.order(:id).last.actor_id).to eq(viewer.id)
      end
    end
  end

  describe "salary_visible?" do
    it "is SalaryProfilePolicy.viewable_employees membership for every actor and target, never computing or recording" do
      expect(Salary::AdvanceEligibilityCalculator).not_to receive(:for)

      actors = [ plain_approver, payroll_approver, outside_payroll_approver, branch_payroll_manager,
                 api_user_with(business, :view_payroll, scopes: { "view_payroll" => "business" }),
                 create(:user, :owner, business: business) ]
      expect do
        actors.product([ employee, no_profile_employee ]).each do |viewer, target|
          expect(contract.salary_visible?(viewer: viewer, employee: target))
            .to eq(SalaryProfilePolicy.viewable_employees(viewer).exists?(id: target.id))
        end
      end.not_to change(AuditLog, :count)

      expect(actors.map { |viewer| contract.salary_visible?(viewer: viewer, employee: employee) })
        .to eq([ false, true, false, true, true, true ])
    end

    it "is false for the viewer's own salary (the rule covers other employees only)" do
      actor = payroll_approver
      expect(contract.salary_visible?(viewer: actor, employee: actor)).to be(false)
      expect(contract.salary_visible?(viewer: employee, employee: employee)).to be(false)
    end
  end

  describe "attendance_day" do
    let(:work_date) { Date.new(2026, 9, 18) }

    it "is the employee's record for the work date, with the five fields the show page reads" do
      record = create(:attendance_record, user: employee, branch: branch_a, shift_assignment: assignment, date: work_date,
                                          work_date: work_date, check_in_at: at(18, 8), check_out_at: at(18, 19),
                                          worked_minutes: 660, status: "present")

      day = contract.attendance_day(user: employee, date: work_date)
      expect(day.to_h).to eq(check_in_at: record.check_in_at, check_out_at: record.check_out_at, status: "present",
                             worked_minutes: 660, duration_severity: :suspicious)
      expect(day.duration_severity).to eq(record.duration_severity)
    end

    it "an incomplete record: no check-out, no worked minutes, no severity" do
      create(:attendance_record, user: employee, branch: branch_a, shift_assignment: assignment, date: work_date,
                                 work_date: work_date, check_in_at: at(18, 8, 5), status: "incomplete")

      expect(contract.attendance_day(user: employee, date: work_date).to_h)
        .to include(check_out_at: nil, status: "incomplete", worked_minutes: nil, duration_severity: nil)
    end

    it "is nil without a record for that employee and date" do
      create(:attendance_record, user: create(:user, business: business), branch: branch_a, date: work_date, work_date: work_date)
      create(:attendance_record, user: employee, branch: branch_a, shift_assignment: assignment,
                                 date: work_date + 1, work_date: work_date + 1, check_in_at: at(19, 8))

      expect(contract.attendance_day(user: employee, date: work_date)).to be_nil
    end
  end

  describe "recent_check_ins" do
    before do
      [ [ Date.new(2026, 9, 19), at(19, 8, 5) ], [ Date.new(2026, 7, 20), riyadh.local(2026, 7, 20, 7, 59) ],
        [ Date.new(2026, 7, 19), riyadh.local(2026, 7, 19, 9, 0) ], [ Date.new(2026, 9, 18), riyadh.local(2026, 9, 17, 23, 30) ] ]
        .each do |date, check_in|
          create(:attendance_record, user: employee, branch: branch_a, shift_assignment: assignment, date: date,
                                     work_date: date, check_in_at: check_in, status: "incomplete")
        end
      create(:attendance_record, user: create(:user, business: business), branch: branch_a,
                                 date: Date.new(2026, 9, 17), work_date: Date.new(2026, 9, 17), check_in_at: at(17, 6))
    end

    it "is the employee's check-ins of the last 62 days (inclusive), keyed by work date, business-local" do
      expect(contract.recent_check_ins(user: employee))
        .to eq("2026-09-19" => "2026-09-19T08:05", "2026-07-20" => "2026-07-20T07:59", "2026-09-18" => "2026-09-17T23:30")
    end

    it "is what the form's hint uses (the controller delegates to the contract), and empty without attendance" do
      allow(contract).to receive(:recent_check_ins).and_call_original
      hint = EmployeeRequestsController.new.send(:punch_check_ins_for, employee)

      expect(contract).to have_received(:recent_check_ins).once.with(user: employee)
      expect(hint).to eq(contract.recent_check_ins(user: employee))
      expect(contract.recent_check_ins(user: no_profile_employee)).to eq({})
    end
  end

  describe "duration_threshold_hours" do
    it "is Attendance::DurationCheck.threshold_hours: critical for :critical, suspicious for anything else" do
      { critical: 14, suspicious: 10, nil => 10, other: 10 }.each do |severity, hours|
        expect(contract.duration_threshold_hours(severity: severity, business: business)).to eq(hours)
        expect(Attendance::DurationCheck.threshold_hours(severity, business: business)).to eq(hours)
      end
    end

    it "uses the defaults when the business configures none" do
      defaults = create(:business)
      expect(contract.duration_threshold_hours(severity: :critical, business: defaults)).to eq(24)
      expect(contract.duration_threshold_hours(severity: :suspicious, business: defaults)).to eq(16)
    end
  end
end
