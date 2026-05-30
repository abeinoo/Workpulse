require "rails_helper"

RSpec.describe Notifications::Creator do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }

  describe ".call" do
    it "creates a notification and derives category + severity from the catalog" do
      n = described_class.call(user: user, event_type: "leave_approved", title: "Approved")

      expect(n).to be_persisted
      expect(n.category).to eq("leave")
      expect(n.severity).to eq("success")
      expect(n.title).to eq("Approved")
    end

    it "lets the caller override severity/category explicitly" do
      n = described_class.call(user: user, event_type: "system_warning", title: "x",
                               severity: "danger", category: "system")
      expect(n.severity).to eq("danger")
    end

    it "returns nil and creates nothing for an unknown event_type" do
      expect {
        result = described_class.call(user: user, event_type: "not_a_real_event", title: "x")
        expect(result).to be_nil
      }.not_to change(Notification, :count)
    end

    it "returns nil when user is nil" do
      expect(described_class.call(user: nil, event_type: "leave_approved", title: "x")).to be_nil
    end

    it "attaches a polymorphic notifiable and data payload" do
      request = create(:employee_request, user: user)
      n = described_class.call(user: user, event_type: "employee_request_approved",
                               title: "x", notifiable: request, data: { foo: "bar" })
      expect(n.notifiable).to eq(request)
      expect(n.data).to eq("foo" => "bar")
    end
  end

  describe "preference gating" do
    it "suppresses a notification when the user disabled that category" do
      user.set_notification_preference("leave", false)

      expect {
        result = described_class.call(user: user, event_type: "leave_approved", title: "x")
        expect(result).to be_nil
      }.not_to change(Notification, :count)
    end

    it "still delivers categories the user has NOT disabled" do
      user.set_notification_preference("leave", false)
      n = described_class.call(user: user, event_type: "payroll_paid", title: "x")
      expect(n).to be_persisted
    end

    it "delivers by default when no preference was ever set" do
      n = described_class.call(user: user, event_type: "leave_approved", title: "x")
      expect(n).to be_persisted
    end
  end

  describe "deduplication" do
    it "suppresses a duplicate within the dedup window (same event + notifiable)" do
      record = create(:attendance_record, user: user)
      args = { user: user, event_type: "attendance_missing_check_out", title: "x",
               notifiable: record, dedup_within: 12.hours }

      first  = described_class.call(**args)
      second = described_class.call(**args)

      expect(first).to be_persisted
      expect(second).to be_nil
      expect(Notification.where(event_type: "attendance_missing_check_out").count).to eq(1)
    end

    it "allows a new notification once the window has elapsed" do
      record = create(:attendance_record, user: user)
      create(:notification, user: user, event_type: "attendance_missing_check_out",
             category: "attendance", notifiable: record, created_at: 2.days.ago)

      n = described_class.call(user: user, event_type: "attendance_missing_check_out",
                               title: "x", notifiable: record, dedup_within: 12.hours)
      expect(n).to be_persisted
    end

    it "does not dedup when no window is given" do
      2.times { described_class.call(user: user, event_type: "leave_approved", title: "x") }
      expect(Notification.where(event_type: "leave_approved").count).to eq(2)
    end
  end

  describe ".broadcast" do
    it "creates one notification per recipient and returns the created records" do
      u2 = create(:user, business: business)
      created = described_class.broadcast(users: [ user, u2 ],
                                          event_type: "manager_pending_approvals", title: "x")
      expect(created.size).to eq(2)
      expect(Notification.where(event_type: "manager_pending_approvals").count).to eq(2)
    end

    it "skips recipients who disabled the category (returns only delivered)" do
      u2 = create(:user, business: business)
      u2.set_notification_preference("approvals", false)
      created = described_class.broadcast(users: [ user, u2 ],
                                          event_type: "manager_pending_approvals", title: "x")
      expect(created.size).to eq(1)
      expect(created.first.user).to eq(user)
    end
  end
end
