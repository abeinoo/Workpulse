require "rails_helper"

RSpec.describe Finance::Dashboard::Capabilities do
  subject(:capabilities) { described_class.new }

  it "reports every capability as unavailable when the backing table doesn't exist" do
    expect(capabilities.multi_business?).to eq(false)
    expect(capabilities.supplier_financials_available?).to eq(false)
    expect(capabilities.cash_ledger_available?).to eq(false)
    expect(capabilities.bank_ledger_available?).to eq(false)
  end

  it "flips on automatically once the backing table exists" do
    allow(ActiveRecord::Base.connection).to receive(:table_exists?).and_call_original
    allow(ActiveRecord::Base.connection).to receive(:table_exists?).with("supplier_invoices").and_return(true)

    expect(capabilities.supplier_financials_available?).to eq(true)
    expect(capabilities.cash_ledger_available?).to eq(false)
  end
end
