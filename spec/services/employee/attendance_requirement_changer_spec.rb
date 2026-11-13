require "rails_helper"

# R3.2 G5: Employee::AttendanceRequirementChanger, the single writer of the
# attendance requirement history (attendance plan revision 19, §6.1, §19.14).
# The two-connection behaviour is in attendance_requirement_changer_concurrency_spec.rb.
RSpec.describe Employee::AttendanceRequirementChanger do
  let(:business) { create(:business, timezone: "Africa/Cairo", business_day_start_hour: 6) }
  let(:hr) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business,
                                                            permissions: %w[view_employees manage_employees],
                                                            permission_scopes: { "view_employees" => "business",
                                                                                 "manage_employees" => "business" }))
  end
  let(:employee) { create(:user, business: business) }
  let(:today)    { Date.new(2026, 11, 15) }

  around { |example| travel_to(Time.find_zone("Africa/Cairo").local(2026, 11, 15, 10, 0)) { example.run } }

  def enable_rollout!(on: "2026-11-01")
    business.update!(settings: (business.settings || {}).merge(Workforce::AttendanceRequirementRollout::SETTING => on))
  end

  def change(status:, from:, reason: nil, source: :hr_change, actor: hr, user: employee)
    described_class.call(user_id: user.id, status: status, effective_from: from, reason: reason, actor: actor, source: source)
  end

  def first_row!(status: "required", from: Date.new(2026, 1, 1))
    change(status: status, from: from, source: :creation).tap { |result| raise "setup failed: #{result.error}" unless result.ok? }
  end

  describe "creation (first row)" do
    it "records the first row with no reason and no D4 check, and audits it" do
      create(:payroll_period, business: business, period_year: 2026, period_month: 3, status: :finalized)
      result = first_row!(from: Date.new(2026, 3, 10))

      expect(result.record).to have_attributes(status: "required", source: "creation", reason: nil,
                                               effective_from: Date.new(2026, 3, 10), changed_by_id: hr.id)
      audit = AuditLog.find_by!(action: "attendance_requirement_changed", auditable: employee)
      expect(audit.diff).to include(status: %w[not_reviewed required])
      expect(audit.metadata).to include("source" => "creation", "backdated" => true, "effective_from" => "2026-03-10")
    end

    it "works while the rollout switch is off (creation is gated by its callers, OD-2)" do
      expect(Workforce::AttendanceRequirementRollout.active?(business)).to be(false)
      expect(change(status: "not_required", from: today, source: :creation)).to be_ok
    end

    it "refuses a second first row" do
      first_row!
      expect(change(status: "required", from: today, source: :creation).error).to eq(:already_recorded)
    end

    it "requires manage_employees" do
      expect(change(status: "required", from: today, source: :creation, actor: employee).error).to eq(:not_authorized)
    end
  end

  describe "HR changes" do
    before { first_row! }

    it "is refused while the rollout switch is off (OD-5)" do
      result = change(status: "not_required", from: today + 1)
      expect(result.error).to eq(:rollout_inactive)
      expect(EmployeeAttendanceRequirement.count).to eq(1)
    end

    context "with the rollout active" do
      before { enable_rollout! }

      it "records a future-dated change with no reason and audits old, new, date and actor" do
        result = change(status: "not_required", from: today + 10)
        expect(result).to be_ok
        audit = AuditLog.where(action: "attendance_requirement_changed").order(:id).last
        expect(audit).to have_attributes(actor_id: hr.id)
        expect(audit.diff).to include(status: %w[required not_required])
        expect(audit.metadata).to include("backdated" => false, "source" => "hr_change")
      end

      it "treats today (the business day) as not backdated" do
        expect(change(status: "not_required", from: today)).to be_ok
      end

      it "uses the business day: before 06:00 Cairo, yesterday's calendar date is today" do
        travel_to(Time.find_zone("Africa/Cairo").local(2026, 11, 16, 5, 30)) # replaces the around hook's time
        expect(change(status: "not_required", from: Date.new(2026, 11, 15))).to be_ok
        expect(AuditLog.where(action: "attendance_requirement_changed").order(:id).last.metadata["backdated"]).to be(false)
      end

      it "refuses not_reviewed and unknown statuses" do
        expect(change(status: "not_reviewed", from: today).error).to eq(:invalid_status)
        expect(change(status: "exempt", from: today).error).to eq(:invalid_status)
      end

      it "refuses a change to the value already in force" do
        expect(change(status: "required", from: today).error).to eq(:unchanged)
      end

      it "refuses a backdated change without a reason" do
        expect(change(status: "not_required", from: today - 5).error).to eq(:reason_required)
      end

      it "accepts a backdated change with a reason when no period is under review or later" do
        create(:payroll_period, business: business, period_year: 2026, period_month: 11, status: :draft)
        expect(change(status: "not_required", from: today - 5, reason: "Remote role since the 10th")).to be_ok
      end

      %i[under_review branch_review_completed finalized paid].each do |status|
        it "refuses a backdated change reaching a #{status} period (D4), writing nothing" do
          create(:payroll_period, business: business, period_year: 2026, period_month: 10, status: status)
          result = change(status: "not_required", from: Date.new(2026, 10, 20), reason: "x")
          expect(result.error).to eq(:payroll_protected)
          expect(result.details).to include(starts_on: Date.new(2026, 10, 1))
          expect(EmployeeAttendanceRequirement.count).to eq(1)
          expect(AuditLog.where(action: "attendance_requirement_changed").count).to eq(1)
        end
      end

      it "protects a period in which the employee has no payroll entry (OD-10), ignoring other businesses" do
        create(:payroll_period, business: create(:business), period_year: 2026, period_month: 10, status: :finalized)
        expect(change(status: "not_required", from: Date.new(2026, 10, 20), reason: "x")).to be_ok

        create(:payroll_period, business: business, period_year: 2026, period_month: 9, status: :under_review)
        expect(change(status: "not_required", from: Date.new(2026, 9, 20), reason: "x").error).to eq(:payroll_protected)
      end

      describe "A5: assignments" do
        let(:shift) { create(:shift, business: business) }

        it "refuses not_required while any assignment is active on or after the date (all kinds)" do
          create(:shift_assignment, user: employee, shift: shift, effective_from: today - 30, effective_to: nil)
          expect(change(status: "not_required", from: today + 5).error).to eq(:assignments_active)
        end

        it "refuses not_required with a future assignment, including a floating one" do
          create(:shift_assignment, :floating, user: employee, shift: shift, effective_from: today + 20, effective_to: nil)
          expect(change(status: "not_required", from: today + 5).error).to eq(:assignments_active)
        end

        it "allows not_required once every assignment ends before the date" do
          create(:shift_assignment, user: employee, shift: shift, effective_from: today - 30, effective_to: today + 4)
          expect(change(status: "not_required", from: today + 5)).to be_ok
        end

        it "never blocks a change to required" do
          change(status: "not_required", from: today + 5)
          create(:shift_assignment, user: employee, shift: shift, effective_from: today - 30, effective_to: today + 4)
          expect(change(status: "required", from: today + 10)).to be_ok
        end
      end

      describe "authorisation" do
        it "refuses an actor without manage_employees" do
          expect(change(status: "not_required", from: today, actor: create(:user, business: business)).error).to eq(:not_authorized)
        end

        it "refuses a change of one's own requirement, the owner included" do
          owner = create(:user, business: business).tap { |user| business.update!(owner: user) }
          change(status: "required", from: Date.new(2026, 1, 1), source: :creation, actor: hr, user: owner)
          expect(change(status: "not_required", from: today, actor: owner, user: owner).error).to eq(:not_authorized)
          expect(change(status: "not_required", from: today, actor: hr, user: hr).error).to eq(:not_authorized)
        end

        it "never finds another business's employee" do
          stranger = create(:user, business: create(:business))
          expect { change(status: "not_required", from: today, user: stranger) }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      it "keeps the change when its audit entry cannot be written (log_audit is fail-open; the row is the record)" do
        allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
        expect(change(status: "not_required", from: today)).to be_ok
        expect(Employee::AttendanceRequirements.status_on(user_id: employee.id, date: today)).to eq(:not_required)
        expect(PendingAuditEvent.count).to eq(0)
      end
    end
  end

  it "takes the employee lock before writing (first lock of the transaction)" do
    expect(Employee::AttendanceRequirements).to receive(:lock_employee!).with(user_id: employee.id).ordered.and_call_original
    expect(EmployeeAttendanceRequirement).to receive(:create!).ordered.and_call_original
    first_row!
  end
end
