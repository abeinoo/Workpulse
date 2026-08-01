require "rails_helper"

RSpec.describe PosTransaction do
  it "is valid with all required fields" do
    expect(build(:pos_transaction)).to be_valid
  end

  %i[transaction_id status transaction_date terminal_id].each do |field|
    it "requires #{field}" do
      pos_transaction = build(:pos_transaction, field => nil)
      expect(pos_transaction).not_to be_valid
      expect(pos_transaction.errors[field]).to be_present
    end
  end

  it "requires a positive amount" do
    expect(build(:pos_transaction, amount: nil)).not_to be_valid
    expect(build(:pos_transaction, amount: 0)).not_to be_valid
    expect(build(:pos_transaction, amount: -5)).not_to be_valid
  end

  it "enforces transaction_id uniqueness scoped to business" do
    business = create(:business)
    create(:pos_transaction, business: business, transaction_id: "TXN-DUP")

    dup = build(:pos_transaction, business: business, transaction_id: "TXN-DUP")
    expect(dup).not_to be_valid
    expect(dup.errors[:transaction_id]).to be_present
  end

  it "allows the same transaction_id across different businesses" do
    create(:pos_transaction, transaction_id: "TXN-SHARED")

    other_business_txn = build(:pos_transaction, transaction_id: "TXN-SHARED")
    expect(other_business_txn).to be_valid
  end

  describe "#total_fees" do
    it "sums fees and administrative_fees" do
      pos_transaction = build(:pos_transaction, fees: 2.5, administrative_fees: 1.25)
      expect(pos_transaction.total_fees).to eq(3.75)
    end
  end

  describe ".for_calendar_date" do
    # business_day_start_hour is deliberately non-zero and non-default here —
    # every example in this block asserts it has ZERO effect on POS
    # transaction bucketing. POS transactions are external financial records
    # reconciled against their actual Paid At timestamp, not the salon's
    # operational business day.
    let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
    let(:branch)   { create(:branch, business: business) }

    it "includes a transaction paid mid-afternoon on the given calendar date" do
      txn = create(:pos_transaction, business: business, branch: branch,
                   transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 15, 14, 0) })

      result = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 15), business: business)

      expect(result).to include(txn)
    end

    it "attributes a transaction paid at 00:30 to THAT SAME calendar date, ignoring business_day_start_hour entirely" do
      txn = create(:pos_transaction, business: business, branch: branch,
                   transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 16, 0, 30) })

      same_day     = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 16), business: business)
      previous_day = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 15), business: business)

      expect(same_day).to include(txn)
      expect(previous_day).not_to include(txn)
    end

    it "includes a transaction paid just before midnight (23:59) on the given calendar date" do
      txn = create(:pos_transaction, business: business, branch: branch,
                   transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 15, 23, 59) })

      result   = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 15), business: business)
      next_day = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 16), business: business)

      expect(result).to include(txn)
      expect(next_day).not_to include(txn)
    end

    it "excludes a transaction from a different branch" do
      other_branch = create(:branch, business: business)
      create(:pos_transaction, business: business, branch: other_branch,
             transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 15, 9, 0) })

      result = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 15), business: business)

      expect(result).to be_empty
    end

    it "excludes a transaction from the following calendar date" do
      create(:pos_transaction, business: business, branch: branch,
             transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 16, 9, 0) })

      result = described_class.for_calendar_date(branch: branch, date: Date.new(2026, 7, 15), business: business)

      expect(result).to be_empty
    end

    it "produces the same calendar-date bucketing regardless of business_day_start_hour" do
      no_rollover  = create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0)
      late_rollover = create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 20)
      branch_a = create(:branch, business: no_rollover)
      branch_b = create(:branch, business: late_rollover)

      txn_a = create(:pos_transaction, business: no_rollover, branch: branch_a,
                     transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 15, 3, 0) })
      txn_b = create(:pos_transaction, business: late_rollover, branch: branch_b,
                     transaction_date: Time.use_zone("Asia/Riyadh") { Time.zone.local(2026, 7, 15, 3, 0) })

      result_a = described_class.for_calendar_date(branch: branch_a, date: Date.new(2026, 7, 15), business: no_rollover)
      result_b = described_class.for_calendar_date(branch: branch_b, date: Date.new(2026, 7, 15), business: late_rollover)

      expect(result_a).to include(txn_a)
      expect(result_b).to include(txn_b)
    end
  end
end
