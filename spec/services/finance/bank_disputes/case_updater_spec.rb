require "rails_helper"

RSpec.describe Finance::BankDisputes::CaseUpdater do
  let(:business)   { create(:business) }
  let(:branch)     { create(:branch, business: business) }
  let(:accountant) { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let(:dispute) do
    BankDispute.create!(daily_reconciliation: dr, business: business, branch: branch, opened_by: accountant,
                        opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
                        amount: 300, bank_name: "NBE", terminal_id: "T-001", card_last4: "1234")
  end

  def update(**args)
    described_class.new(dispute.id, actor: accountant, **args).call
  end

  it "updates the bank ticket number and logs a distinct audit entry" do
    result = update(bank_ticket_number: "TCK-99")

    expect(result.ok?).to be true
    expect(dispute.reload.bank_ticket_number).to eq("TCK-99")
    log = AuditLog.where(auditable: dispute, action: "bank_ticket_number_added").sole
    expect(log.metadata["bank_ticket_number"]).to eq("TCK-99")
  end

  it "logs a case note without persisting it on the dispute record" do
    result = update(case_note: "Bank asked for the receipt photo", case_note_category: "additional_info_requested")

    expect(result.ok?).to be true
    log = AuditLog.where(auditable: dispute, action: "case_note_added").sole
    expect(log.metadata["note"]).to eq("Bank asked for the receipt photo")
    expect(log.metadata["category"]).to eq("additional_info_requested")
  end

  it "attaches photos and logs a distinct audit entry" do
    file = Rack::Test::UploadedFile.new(StringIO.new("fake"), "image/png", original_filename: "screenshot.png")

    result = update(photos: [ file ])

    expect(result.ok?).to be true
    expect(dispute.reload.photos.count).to eq(1)
    log = AuditLog.where(auditable: dispute, action: "attachments_added").sole
    expect(log.metadata["count"]).to eq(1)
  end

  it "logs one entry per field actually present, in a single call" do
    update(bank_ticket_number: "TCK-1", case_note: "Waiting", case_note_category: "waiting_for_bank")

    expect(AuditLog.where(auditable: dispute).pluck(:action)).to contain_exactly(
      "bank_ticket_number_added", "case_note_added"
    )
  end

  it "is a no-op with no audit entries when nothing is given" do
    expect { update }.not_to change(AuditLog, :count)
  end

  it "rejects updates once the case is closed" do
    dispute.update!(status: "closed")

    result = update(case_note: "too late")

    expect(result.ok?).to be false
    expect(AuditLog.where(auditable: dispute, action: "case_note_added")).to be_empty
  end

  # BUG-003: a case note is stored only in its audit entry (fail-closed); the
  # ticket number lives on the dispute row (fail-open).
  describe "when an audit entry cannot be written" do
    it "refuses a case note, and rolls back the rest of the same update" do
      fail_audit_writes!(:case_note_added)

      result = update(bank_ticket_number: "TCK-7", case_note: "Called the bank", case_note_category: "bank_called_back")

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("audit_log.errors.write_failed"))
      expect(dispute.reload.bank_ticket_number).to be_nil
      expect(AuditLog.where(auditable: dispute)).to be_empty
    end

    it "still saves a ticket number whose entry cannot be written (fail-open)" do
      fail_audit_writes!(:bank_ticket_number_added)

      expect(update(bank_ticket_number: "TCK-8").ok?).to be true
      expect(dispute.reload.bank_ticket_number).to eq("TCK-8")
      expect(AuditLog.where(auditable: dispute)).to be_empty
    end
  end
end
