require "rails_helper"

RSpec.describe TillHandoverPolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:sender)   { user_with("view_daily_reconciliation", "reverse_till_handover", "close_till_session") }
  let(:receiver) { user_with("view_daily_reconciliation", "reverse_till_handover", "accept_till_handover") }
  let(:third)    { user_with("view_daily_reconciliation", "reverse_till_handover") }

  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "open",
      opened_at:     1.hour.ago,
      business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: receiver) }

  let!(:handover) do
    TillHandover.create!(
      daily_reconciliation: dr,
      from_user:            sender,
      to_user:               receiver,
      self_deposit:          false,
      accepted_at:           1.hour.ago,
      fresha_date:           dr.business_date
    )
  end

  describe "#reverse?" do
    it "allows the receiver while they still hold custody" do
      expect(described_class.new(receiver, handover).reverse?).to be true
    end

    it "allows it while a pending, unaccepted outgoing handover exists" do
      TillHandover.create!(
        daily_reconciliation: dr,
        from_user:            receiver,
        to_user:               third,
        self_deposit:          false,
        fresha_date:           dr.business_date
      )

      expect(described_class.new(receiver, handover).reverse?).to be true
    end

    it "blocks it once a subsequent handover has been accepted" do
      TillHandover.create!(
        daily_reconciliation: dr,
        from_user:            receiver,
        to_user:               third,
        self_deposit:          false,
        accepted_at:           Time.current,
        fresha_date:           dr.business_date
      )
      till_session.update!(current_holder: third)

      expect(described_class.new(receiver, handover).reverse?).to be false
    end

    it "blocks it after the receiver has closed the day (self-deposit)" do
      till_session.update!(current_holder: nil)

      expect(described_class.new(receiver, handover).reverse?).to be false
    end
  end

  describe "#cancel? / #reject?" do
    let(:no_perm_sender) { create(:user, business: business) }

    let!(:pending_handover) do
      TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                            self_deposit: false, fresha_date: dr.business_date)
    end

    describe "#cancel?" do
      it "allows the sender, with no special permission beyond close_till_session" do
        plain_sender = user_with("view_daily_reconciliation", "close_till_session")
        h = TillHandover.create!(daily_reconciliation: dr, from_user: plain_sender, to_user: receiver,
                                  self_deposit: false, fresha_date: dr.business_date)
        expect(described_class.new(plain_sender, h).cancel?).to be true
      end

      it "blocks the sender if they lack close_till_session" do
        h = TillHandover.create!(daily_reconciliation: dr, from_user: no_perm_sender, to_user: receiver,
                                  self_deposit: false, fresha_date: dr.business_date)
        expect(described_class.new(no_perm_sender, h).cancel?).to be false
      end

      it "blocks an unrelated employee with no special permission" do
        expect(described_class.new(third, pending_handover).cancel?).to be false
      end

      it "allows an admin holding void_till_handover even though they are not the sender" do
        admin = user_with("view_daily_reconciliation", "void_till_handover")
        expect(described_class.new(admin, pending_handover).cancel?).to be true
      end

      it "blocks the receiver from cancelling (only the sender may cancel)" do
        expect(described_class.new(receiver, pending_handover).cancel?).to be false
      end

      it "blocks it once the handover has been accepted" do
        pending_handover.update!(accepted_at: Time.current)
        expect(described_class.new(sender, pending_handover).cancel?).to be false
      end
    end

    describe "#reject?" do
      it "allows the intended receiver" do
        expect(described_class.new(receiver, pending_handover).reject?).to be true
      end

      it "blocks the sender from rejecting their own handover" do
        expect(described_class.new(sender, pending_handover).reject?).to be false
      end

      it "blocks an unrelated employee" do
        expect(described_class.new(third, pending_handover).reject?).to be false
      end

      it "blocks it once the handover has been accepted" do
        pending_handover.update!(accepted_at: Time.current)
        expect(described_class.new(receiver, pending_handover).reject?).to be false
      end
    end
  end
end
