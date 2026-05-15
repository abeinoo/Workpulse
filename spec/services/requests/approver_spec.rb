require "rails_helper"

RSpec.describe Requests::Approver do
  let(:business)   { create(:business) }
  let(:manager)    { create(:user, :branch_manager, business: business) }
  let(:accountant) { create(:user, :accountant, business: business) }

  describe ".approve" do
    context "late_permission request" do
      let!(:request) do
        create(:employee_request, :late_permission,
               user: create(:user, business: business))
      end

      it "returns success" do
        result = described_class.approve(request: request, reviewed_by: manager)
        expect(result).to be_success
      end

      it "transitions the request to :approved" do
        described_class.approve(request: request, reviewed_by: manager)
        expect(request.reload.status).to eq("approved")
      end

      it "records the reviewer and timestamp" do
        described_class.approve(request: request, reviewed_by: manager)
        expect(request.reload.reviewed_by).to eq(manager)
        expect(request.reload.reviewed_at).to be_present
      end

      it "does not create an Advance for non-salary requests" do
        expect {
          described_class.approve(request: request, reviewed_by: manager)
        }.not_to change(Advance, :count)
      end

      it "calls Payroll::PermissionApplier to retroactively update payroll" do
        allow(Payroll::PermissionApplier).to receive(:call)
        described_class.approve(request: request, reviewed_by: manager)
        expect(Payroll::PermissionApplier).to have_received(:call).with(request)
      end
    end

    context "salary_advance request" do
      let!(:request) do
        create(:employee_request, :salary_advance, amount: 1_500.0,
               user: create(:user, business: business))
      end

      it "transitions to approved but does NOT create an Advance" do
        expect {
          described_class.approve(request: request, reviewed_by: manager)
        }.not_to change(Advance, :count)
        expect(request.reload.status).to eq("approved")
      end
    end

    context "when the request is already approved" do
      let!(:request) { create(:employee_request, :approved,
                               user: create(:user, business: business)) }

      it "returns failure" do
        result = described_class.approve(request: request, reviewed_by: manager)
        expect(result).not_to be_success
        expect(result.error).to include("already")
      end
    end
  end

  describe ".reject" do
    let!(:request) do
      create(:employee_request, :late_permission,
             user: create(:user, business: business))
    end

    it "transitions the request to :rejected" do
      described_class.reject(request: request, reviewed_by: manager)
      expect(request.reload.status).to eq("rejected")
    end

    it "records the reviewer" do
      described_class.reject(request: request, reviewed_by: manager)
      expect(request.reload.reviewed_by).to eq(manager)
    end

    it "accepts an optional response_note" do
      described_class.reject(request: request, reviewed_by: manager,
                              response_note: "Not approved this period")
      expect(request.reload.response_note).to eq("Not approved this period")
    end

    context "when the request is already rejected" do
      let!(:rejected) { create(:employee_request, :rejected,
                                user: create(:user, business: business)) }

      it "returns failure" do
        result = described_class.reject(request: rejected, reviewed_by: manager)
        expect(result).not_to be_success
      end
    end
  end

  describe ".pay" do
    context "approved salary_advance request" do
      let!(:request) do
        create(:employee_request, :salary_advance, :approved, amount: 2_000.0,
               user: create(:user, business: business))
      end

      it "returns success" do
        result = described_class.pay(request: request, paid_by: accountant)
        expect(result).to be_success
      end

      it "transitions the request to :paid" do
        described_class.pay(request: request, paid_by: accountant)
        expect(request.reload.status).to eq("paid")
      end

      it "creates an Advance record for the full amount" do
        expect {
          described_class.pay(request: request, paid_by: accountant)
        }.to change(Advance, :count).by(1)

        advance = Advance.last
        expect(advance.total_amount).to eq(2_000.0)
        expect(advance.remaining_amount).to eq(2_000.0)
        expect(advance.user).to eq(request.user)
        expect(advance.employee_request).to eq(request)
        expect(advance.status).to eq("active")
      end
    end

    context "pending salary_advance request (not yet manager-approved)" do
      let!(:request) do
        create(:employee_request, :salary_advance, amount: 500.0,
               user: create(:user, business: business))
      end

      it "returns failure" do
        result = described_class.pay(request: request, paid_by: accountant)
        expect(result).not_to be_success
        expect(result.error).to include("approved")
      end
    end

    context "non-salary-advance request" do
      let!(:request) do
        create(:employee_request, :approved,
               user: create(:user, business: business))
      end

      it "returns failure" do
        result = described_class.pay(request: request, paid_by: accountant)
        expect(result).not_to be_success
      end
    end
  end
end
