require "rails_helper"

# BUG-003: ignoring a MATCHED line deletes its match row, so the :ignored entry
# is then the only record of the released deposit (fail-closed). An unmatched
# line keeps its ignore reason on the row (fail-open).
RSpec.describe Finance::BankStatements::Ignorer do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                opened_at: 1.hour.ago, business_date: Date.current)
  end
  let(:statement) { create(:bank_statement, :pending, business: business, branch: branch) }

  def line!(status: "unexpected")
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 300,
                                     transaction_date: Date.current, raw_data: {}, status: status)
  end

  def matched_line!
    deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                                  amount: 300, deposited_at: Time.current)
    line = line!(status: "verified")
    DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: line, matched_by: actor)
    line.update!(match_method: "manual", match_confidence: 100)
    statement.update_columns(matched_rows: 1, unmatched_rows: 0)
    [ line, deposit ]
  end

  def ignore(line) = described_class.call(line.id, actor: actor, reason: "Bank fee")

  describe "a matched line" do
    it "releases the match and records the released deposit in the :ignored entry" do
      line, deposit = matched_line!

      expect(ignore(line)).to be_ok

      expect(line.reload.status).to eq("ignored")
      expect(line.deposit_matches).to be_empty
      expect(statement.reload.matched_rows).to eq(0)
      audit = AuditLog.where(auditable: line, action: "ignored").sole
      expect(audit.metadata).to include("was_matched" => true, "previous_till_deposit_id" => deposit.id,
                                        "reason" => "Bank fee")
    end

    it "refuses and keeps the match when the entry cannot be written (fail-closed)" do
      line, deposit = matched_line!
      fail_audit_writes!(:ignored)

      result = ignore(line)

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("audit_log.errors.write_failed"))
      expect(line.reload.status).to eq("verified")
      expect(line.matched_till_deposit).to eq(deposit)
      expect(statement.reload.matched_rows).to eq(1)
      expect(AuditLog.where(auditable: line)).to be_empty
    end
  end

  describe "an unmatched line" do
    it "is ignored even when the entry cannot be written (fail-open), and the failure is reported" do
      line = line!
      statement.update_columns(unmatched_rows: 1)
      fail_audit_writes!(:ignored)
      expect(Rails.error).to receive(:report).once.and_call_original

      expect(ignore(line)).to be_ok

      expect(line.reload).to have_attributes(status: "ignored", ignored_reason: "Bank fee")
      expect(statement.reload.unmatched_rows).to eq(0)
      expect(AuditLog.where(auditable: line)).to be_empty
    end
  end
end
