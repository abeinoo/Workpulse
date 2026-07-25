require "rails_helper"

RSpec.describe "Finance::DailyReconciliations — Cancel/Reject a pending till handover", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:sender)   { create(:user, :owner, business: business) }
  let(:receiver) { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: sender) }

  let!(:handover) do
    TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                          self_deposit: false, fresha_date: dr.business_date)
  end

  before { sign_in sender }

  describe "custody and calculations while pending, then after cancel/reject" do
    it "keeps custody, Custody Summary, and POS breakdown attributed to the sender throughout" do
      TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 500, refund_amount: 0, kind: "operational")

      # While pending: sender is still Current Holder; the pending handover is
      # invisible to ERS (accepted_at is nil), so neither cashier has a row yet.
      expect(dr.till_session.reload.current_holder).to eq(sender)
      expect(Finance::EmployeeReconciliationSummarizer.new(dr).summaries).to be_empty

      Finance::TillHandoverCanceller.new(handover.id, actor: sender).call

      expect(dr.till_session.reload.current_holder).to eq(sender)
      expect(Finance::EmployeeReconciliationSummarizer.new(dr).summaries).to be_empty
      expect(TillHandover.count).to eq(1)
    end
  end

  describe "GET show — timeline" do
    it "shows Handover Cancelled with the reason" do
      Finance::TillHandoverCanceller.new(handover.id, actor: sender, reason: "Wrong person").call

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include("Handover Cancelled")
      expect(response.body).to include("Wrong person")
    end

    it "shows Handover Rejected with the reason" do
      Finance::TillHandoverRejecter.new(handover.id, actor: receiver, reason: "Not my till").call

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include("Handover Rejected")
      expect(response.body).to include("Not my till")
    end
  end

  describe "PATCH cancel / reject via controller" do
    it "lets the sender cancel their own pending handover" do
      patch cancel_till_handover_path(handover)

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(handover.reload.cancelled?).to be true
    end

    it "blocks an unauthorized employee from cancelling" do
      other = create(:user, business: business)
      sign_in other

      patch cancel_till_handover_path(handover)

      expect(handover.reload.cancelled?).to be false
    end

    it "blocks an employee with close_till_session who is not the sender from cancelling someone else's handover" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                permissions: %w[view_daily_reconciliation close_till_session])
      not_sender = create(:user, business: business, permission_role: role)
      sign_in not_sender

      patch cancel_till_handover_path(handover)

      expect(handover.reload.cancelled?).to be false
    end

    it "lets the receiver reject the pending handover" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                permissions: %w[view_daily_reconciliation accept_till_handover])
      receiver.update_column(:permission_role_id, role.id)
      sign_in receiver

      patch reject_till_handover_path(handover)

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(handover.reload.rejected?).to be true
    end

    it "blocks an unauthorized employee from rejecting" do
      other = create(:user, business: business)
      sign_in other

      patch reject_till_handover_path(handover)

      expect(handover.reload.rejected?).to be false
    end

    it "blocks an employee with accept_till_handover who is not the intended recipient from rejecting" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                permissions: %w[view_daily_reconciliation accept_till_handover])
      not_recipient = create(:user, business: business, permission_role: role)
      sign_in not_recipient

      patch reject_till_handover_path(handover)

      expect(handover.reload.rejected?).to be false
    end

    it "blocks a non-owner sender from rejecting their own handover" do
      plain_sender = create(:user, business: business)
      own_handover = TillHandover.create!(daily_reconciliation: dr, from_user: plain_sender, to_user: receiver,
                                           self_deposit: false, fresha_date: dr.business_date)
      sign_in plain_sender

      patch reject_till_handover_path(own_handover)

      expect(own_handover.reload.rejected?).to be false
    end

    it "allows the business owner (Super Admin) to reject a handover addressed to someone else" do
      # `sender` in this file is created with the :owner trait — this exercises
      # the deliberate Super Admin bypass (see TillHandoverPolicy#reject?).
      patch reject_till_handover_path(handover)

      expect(handover.reload.rejected?).to be true
    end
  end
end
