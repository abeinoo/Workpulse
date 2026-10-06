require "rails_helper"

# Characterization (Milestone 2 — Finance & Sales Expenses, M1) — CURRENT
# Finance::NumberSequencer: per-business, per-kind document numbers. Shared by
# expenses (including the payroll insurance expense) and balance requests.
RSpec.describe "Characterization: Finance::NumberSequencer" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def next_number(target = business, kind = :expense)
    ActiveRecord::Base.transaction { Finance::NumberSequencer.new(target, kind).next_number }
  end

  it "starts each business at 000001 with the kind's prefix" do
    expect(next_number).to eq("EXP-000001")
    expect(next_number(business, :balance_request)).to eq("BRQ-000001")
  end

  it "continues after the highest existing number, ignoring numbers without the prefix" do
    create(:expense, business: business, branch: branch, reference_number: "EXP-000007")
    create(:expense, business: business, branch: branch, reference_number: "EXP-000003")
    create(:expense, business: business, branch: branch, reference_number: "MANUAL-99")

    expect(next_number).to eq("EXP-000008")
  end

  it "keeps sequences independent per business" do
    create(:expense, business: business, branch: branch, reference_number: "EXP-000050")

    expect(next_number(create(:business))).to eq("EXP-000001")
  end

  it "rejects an unknown document kind" do
    expect { Finance::NumberSequencer.new(business, :bogus) }.to raise_error(KeyError)
  end
end
