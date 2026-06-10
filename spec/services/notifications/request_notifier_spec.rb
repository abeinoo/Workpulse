require "rails_helper"

RSpec.describe Notifications::RequestNotifier do
  let(:business) { create(:business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let(:employee) { create(:user, business: business) }

  describe ".approved" do
    it "notifies the requester with a leave_approved event for a late_permission request" do
      req = create(:employee_request, :late_permission, user: employee)
      expect {
        described_class.approved(request: req, actor: manager)
      }.to change { employee.notifications.where(event_type: "leave_approved").count }.by(1)

      n = employee.notifications.where(event_type: "leave_approved").last
      expect(n.category).to eq("leave")
      expect(n.severity).to eq("success")
    end

    it "uses attendance_correction_approved for a punch_correction request" do
      req = create(:employee_request, :punch_correction, user: employee)
      described_class.approved(request: req, actor: manager)

      n = employee.notifications.last
      expect(n.event_type).to eq("attendance_correction_approved")
      expect(n.category).to eq("attendance")
    end

    it "uses employee_request_approved for a salary_advance request" do
      req = create(:employee_request, :salary_advance, user: employee)
      described_class.approved(request: req, actor: manager)

      n = employee.notifications.last
      expect(n.event_type).to eq("employee_request_approved")
      expect(n.category).to eq("approvals")
    end
  end

  describe ".rejected" do
    it "notifies the requester with a danger-severity rejection" do
      req = create(:employee_request, :salary_advance, user: employee)
      described_class.rejected(request: req, actor: manager)

      n = employee.notifications.last
      expect(n.event_type).to eq("employee_request_rejected")
      expect(n.severity).to eq("danger")
    end
  end

  describe "Requests::Approver integration" do
    it "creates a notification for the employee on approve" do
      req = create(:employee_request, :late_permission, user: employee)
      expect {
        Requests::Approver.approve(request: req, reviewed_by: manager)
      }.to change { employee.notifications.count }.by(1)
    end

    it "creates a notification for the employee on reject" do
      req = create(:employee_request, :late_permission, user: employee)
      expect {
        Requests::Approver.reject(request: req, reviewed_by: manager)
      }.to change { employee.notifications.where(event_type: "leave_rejected").count }.by(1)
    end

    it "respects the employee's category preference" do
      employee.set_notification_preference("leave", false)
      req = create(:employee_request, :late_permission, user: employee)
      expect {
        Requests::Approver.approve(request: req, reviewed_by: manager)
      }.not_to change(Notification, :count)
    end
  end
end
