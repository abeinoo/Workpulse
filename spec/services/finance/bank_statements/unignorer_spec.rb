require "rails_helper"

RSpec.describe Finance::BankStatements::Unignorer do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, business: business) }
  let(:statement) { create(:bank_statement, :pending, business: business) }
  let(:line) do
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 75,
                                     transaction_date: Date.current, raw_data: {}, status: "unexpected")
  end

  before do
    statement.update_columns(matched_rows: 0, unmatched_rows: 1)
    Finance::BankStatements::Ignorer.call(line.id, actor: actor, reason: "Bank fee")
  end

  it "returns the line to verification, restores the counter, and audits both reasons", :aggregate_failures do
    expect(statement.reload.unmatched_rows).to eq(0)

    result = described_class.call(line.id, actor: actor, reason: "Ignored by mistake")

    expect(result).to be_ok
    line.reload
    expect([ line.status, line.ignored_reason ]).to eq([ "unexpected", nil ])
    expect(statement.reload.unmatched_rows).to eq(1)
    audit = AuditLog.where(auditable: line, action: "unignored").sole
    expect(audit.actor).to eq(actor)
    expect(audit.metadata).to include("reason" => "Ignored by mistake", "previous_ignored_reason" => "Bank fee")
  end

  it "requires a reason" do
    result = described_class.call(line.id, actor: actor, reason: " ")

    expect(result.error).to eq(I18n.t("finance.bank_statements.errors.unignore_reason_required"))
    expect(line.reload.status).to eq("ignored")
  end

  it "refuses a line that is not ignored, without a second audit" do
    described_class.call(line.id, actor: actor, reason: "first")

    result = described_class.call(line.id, actor: actor, reason: "again")

    expect(result.error).to eq(I18n.t("finance.bank_statements.errors.not_ignored"))
    expect(AuditLog.where(auditable: line, action: "unignored").count).to eq(1)
  end

  it "leaves a line of a deleted statement ignored" do
    statement.update_columns(deleted_at: Time.current)

    expect(described_class.call(line.id, actor: actor, reason: "x")).not_to be_ok
    expect(line.reload.status).to eq("ignored")
  end

  it "does not reach another business's line" do
    outsider = create(:user)

    expect(described_class.call(line.id, actor: outsider, reason: "x")).not_to be_ok
    expect(line.reload.status).to eq("ignored")
  end
end
