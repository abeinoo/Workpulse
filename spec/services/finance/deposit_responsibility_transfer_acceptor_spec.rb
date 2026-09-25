require "rails_helper"

RSpec.describe Finance::DepositResponsibilityTransferAcceptor, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:from_user) { create(:user, business: business) }
  let(:to_user)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: from_user.id) }

  let!(:transfer) do
    DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: from_user, to_user: to_user)
  end

  def accept(actor: to_user)
    described_class.new(transfer.id, actor: actor).call
  end

  describe "#call" do
    it "accepts the transfer and updates the depositor" do
      result = accept
      expect(result.ok?).to be true
      expect(transfer.reload.accepted_at).to be_present
      expect(till_session.reload.depositor).to eq(to_user)
    end

    it "rejects the wrong recipient" do
      other = create(:user, business: business)
      result = accept(actor: other)
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("deposit_responsibility_transfers.errors.wrong_recipient"))
    end

    it "allows the business owner to accept a transfer addressed to someone else" do
      owner = create(:user, :owner, business: business)
      result = accept(actor: owner)
      expect(result.ok?).to be true
      expect(transfer.reload.accepted_at).to be_present
      expect(till_session.reload.depositor).to eq(owner)
      expect(transfer.reload.accepted_by).to eq(owner)
    end

    it "records who accepted and audits the previous depositor" do
      accept
      expect(transfer.reload.accepted_by).to eq(to_user)
      log = AuditLog.where(auditable: transfer, action: "accept").sole
      expect(log.metadata["previous_depositor_id"]).to eq(from_user.id)
    end

    it "refuses a rejected transfer and leaves the depositor alone" do
      transfer.update!(rejected_at: Time.current, rejected_by: to_user, rejection_reason: "no")
      expect(accept.error).to eq(I18n.t("deposit_responsibility_transfers.errors.rejected"))
      expect(till_session.reload.depositor).to eq(from_user)
    end

    it "refuses a second accept" do
      expect(accept).to be_ok
      expect(accept.error).to eq(I18n.t("deposit_responsibility_transfers.errors.already_accepted"))
    end

    it "re-checks the day on the server: a verified day cannot change depositor" do
      dr.update!(state: "verified", verified_at: Time.current)
      expect(accept.error).to eq(I18n.t("deposit_responsibility_transfers.errors.locked"))
      expect(transfer.reload).to be_pending
      expect(till_session.reload.depositor).to eq(from_user)
    end
  end

  describe "two tabs accepting at once" do
    self.use_transactional_tests = false

    after do
      AuditLog.where(business: business).delete_all
      DepositResponsibilityTransfer.where(daily_reconciliation_id: dr.id).delete_all
      TillSession.where(daily_reconciliation_id: dr.id).delete_all
      DailyReconciliation.where(id: dr.id).delete_all
      User.where(business: business).delete_all
      Branch.where(business: business).delete_all
      Business.where(id: business.id).delete_all
    end

    it "lets exactly one succeed and gives the other a clear error" do
      results = []
      mutex   = Mutex.new
      2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            r = described_class.new(transfer.id, actor: to_user).call
            mutex.synchronize { results << r }
          end
        end
      end.each(&:join)

      expect(results.count(&:ok?)).to eq(1)
      expect(results.reject(&:ok?).sole.error).to eq(I18n.t("deposit_responsibility_transfers.errors.already_accepted"))
      expect(till_session.reload.depositor).to eq(to_user)
      expect(AuditLog.where(auditable: transfer, action: "accept").count).to eq(1)
    end
  end
end
