require "rails_helper"

RSpec.describe "Notification reminder jobs", type: :job do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:tz)       { business.timezone_object }
  let(:today)    { Time.current.in_time_zone(tz).to_date }
  let(:user)     { create(:user, business: business) }

  # ── Forgot check-out ────────────────────────────────────────────────────────
  describe Notifications::ForgotCheckoutReminderJob do
    it "notifies an employee with an incomplete record from yesterday" do
      create(:attendance_record, user: user, business: business,
             work_date: today - 1, date: today - 1, status: "incomplete", check_out_at: nil)

      expect {
        described_class.perform_now
      }.to change { user.notifications.where(event_type: "attendance_missing_check_out").count }.by(1)
    end

    it "does not notify when the record was completed (checked out)" do
      create(:attendance_record, :checked_out, user: user, business: business,
             work_date: today - 1, date: today - 1)

      expect { described_class.perform_now }
        .not_to change(Notification, :count)
    end

    it "is idempotent across reruns (dedup window)" do
      create(:attendance_record, user: user, business: business,
             work_date: today - 1, date: today - 1, status: "incomplete", check_out_at: nil)

      described_class.perform_now
      expect { described_class.perform_now }.not_to change(Notification, :count)
    end

    it "skips inactive employees" do
      user.update!(active: false)
      create(:attendance_record, user: user, business: business,
             work_date: today - 1, date: today - 1, status: "incomplete", check_out_at: nil)

      expect { described_class.perform_now }.not_to change(Notification, :count)
    end

    # Business-day boundary: with start_hour = 6, "yesterday" at 02:00 must be the
    # business day two calendar days back, not the calendar yesterday. This proves
    # the job uses BusinessDay.current rather than a midnight rollover.
    context "with business_day_start_hour = 6 at 02:00" do
      let(:business) { create(:business, timezone: "UTC", business_day_start_hour: 6) }

      it "treats the previous BUSINESS day (not the calendar yesterday) as 'yesterday'" do
        travel_to Time.utc(2026, 5, 24, 2, 0, 0) do
          # At 02:00 the current business day is May 23, so "yesterday" = May 22.
          create(:attendance_record, user: user, business: business,
                 work_date: Date.new(2026, 5, 22), date: Date.new(2026, 5, 22),
                 status: "incomplete", check_out_at: nil)

          expect { described_class.perform_now }
            .to change { user.notifications.where(event_type: "attendance_missing_check_out").count }.by(1)
        end
      end

      it "does NOT flag the in-progress current business day (May 23) as missing checkout" do
        travel_to Time.utc(2026, 5, 24, 2, 0, 0) do
          create(:attendance_record, user: user, business: business,
                 work_date: Date.new(2026, 5, 23), date: Date.new(2026, 5, 23),
                 status: "incomplete", check_out_at: nil)

          expect { described_class.perform_now }.not_to change(Notification, :count)
        end
      end
    end
  end

  # ── Forgot check-in ──────────────────────────────────────────────────────────
  describe Notifications::ForgotCheckinReminderJob do
    it "notifies an employee with an active shift today and no check-in" do
      create(:shift_assignment, user: user, business: business,
             effective_from: today - 10, effective_to: nil)

      expect {
        described_class.perform_now
      }.to change { user.notifications.where(event_type: "attendance_missing_check_in").count }.by(1)
    end

    it "does not notify when the employee already checked in today" do
      # The attendance_record factory auto-creates the active shift assignment,
      # so the user has both a current shift AND a check-in today.
      create(:attendance_record, user: user, business: business, date: today, work_date: today)

      expect { described_class.perform_now }.not_to change(Notification, :count)
    end
  end

  # ── Daily attendance summary (manager) ───────────────────────────────────────
  describe Notifications::DailyAttendanceSummaryJob do
    it "notifies a manager about team members missing attendance today" do
      manager  = create(:user, business: business)
      create(:user, business: business, manager: manager) # report with no attendance

      expect {
        described_class.perform_now
      }.to change { manager.notifications.where(event_type: "manager_missing_attendance").count }.by(1)
    end

    it "does not notify when every report has attendance" do
      manager = create(:user, business: business)
      report  = create(:user, business: business, manager: manager)
      create(:attendance_record, user: report, business: business, date: today, work_date: today)

      expect { described_class.perform_now }.not_to change(Notification, :count)
    end
  end

  # ── Pending approval reminder ────────────────────────────────────────────────
  describe Notifications::PendingApprovalReminderJob do
    it "reminds the reviewing manager about a stale pending request" do
      manager  = create(:user, :branch_manager, business: business)
      employee = create(:user, business: business, manager: manager)
      create(:employee_request, :late_permission, user: employee, status: "pending",
             created_at: 2.days.ago)

      expect {
        described_class.perform_now
      }.to change { manager.notifications.where(event_type: "manager_pending_approvals").count }.by(1)
    end

    it "ignores fresh requests below the stale threshold" do
      manager  = create(:user, :branch_manager, business: business)
      employee = create(:user, business: business, manager: manager)
      create(:employee_request, :late_permission, user: employee, status: "pending",
             created_at: 1.hour.ago)

      expect { described_class.perform_now }.not_to change(Notification, :count)
    end
  end
end
