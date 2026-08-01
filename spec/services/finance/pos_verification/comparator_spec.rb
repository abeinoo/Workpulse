require "rails_helper"

RSpec.describe Finance::PosVerification::Comparator do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }

  let(:sales_import) { SalesImport.create!(business: business, imported_by: user, file_name: "export.csv", status: "imported") }
  let(:pos_import)   { create(:pos_import, business: business, imported_by: user) }

  def sales_txn(amount: 100, reference_number: nil, transaction_date: Date.current, transaction_time: "10:00:00",
                payment_method_name: "Card")
    SalesTransaction.create!(
      business: business, sales_import: sales_import, branch_name: branch.name, cashier_name: "Ahmed",
      amount: amount, reference_number: reference_number, transaction_date: transaction_date,
      transaction_time: transaction_time, payment_method_name: payment_method_name
    )
  end

  def pos_txn(amount: 100, reference_number: nil, transaction_date: Time.zone.parse("#{Date.current} 10:00:00"),
              payment_method: "Card", terminal_id: "TERM-1")
    create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
           amount: amount, reference_number: reference_number, transaction_date: transaction_date,
           payment_method: payment_method, terminal_id: terminal_id)
  end

  describe "Tier 1 — Reference Number" do
    it "matches two transactions that share a reference number, regardless of amount/date/method" do
      s = sales_txn(amount: 100, reference_number: "REF-1", payment_method_name: "Card")
      p = pos_txn(amount: 999, reference_number: "REF-1", payment_method: "Cash",
                   transaction_date: Time.zone.parse("2020-01-01 00:00:00"))

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(1)
      expect(result.matched_pairs.first.sales_transaction).to eq(s)
      expect(result.matched_pairs.first.pos_transaction).to eq(p)
      expect(result.matched_pairs.first.method).to eq(:reference_number)
    end

    it "flags an amount mismatch on a reference-matched pair without breaking the match" do
      s = sales_txn(amount: 100, reference_number: "REF-1")
      p = pos_txn(amount: 90, reference_number: "REF-1")

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(1)
      expect(result.matched_pairs.first.amount_mismatch?).to be true
      expect(result.balanced?).to be false
    end

    it "normalizes reference number whitespace/case" do
      s = sales_txn(reference_number: " ref-1 ")
      p = pos_txn(reference_number: "REF-1")

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(1)
    end
  end

  describe "Tier 2 — Amount + Date + Time Window (default ±10 minutes; Payment Method is NOT a matching condition)" do
    it "matches on amount + nearby time when there is no reference number, regardless of payment method" do
      s = sales_txn(amount: 300, payment_method_name: "Visa", transaction_time: "13:55:10")
      p = pos_txn(amount: 300, payment_method: "Card", transaction_date: Time.zone.parse("#{Date.current} 13:58:42"))

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(1)
      expect(result.matched_pairs.first.method).to eq(:amount_date_time_window)
    end

    it "matches at a ~7 minute gap (within ±10 minutes)" do
      s = sales_txn(amount: 300, transaction_time: "13:55:10")
      p = pos_txn(amount: 300, transaction_date: Time.zone.parse("#{Date.current} 14:02:55"))

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(1)
    end

    it "does not match once the gap exceeds ±10 minutes" do
      s = sales_txn(amount: 300, transaction_time: "13:55:10")
      p = pos_txn(amount: 300, transaction_date: Time.zone.parse("#{Date.current} 14:11:00"))

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(0)
      expect(result.missing_from_pos).to eq([ s ])
      expect(result.extra_in_pos).to eq([ p ])
    end

    it "does not match across different calendar dates, even within the time window" do
      s = sales_txn(amount: 300, transaction_date: Date.current, transaction_time: "23:58:00")
      p = pos_txn(amount: 300, transaction_date: Time.zone.parse("#{1.day.since.to_date} 00:03:00"))

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(0)
    end

    it "cannot match a sales transaction with no recorded time" do
      s = sales_txn(amount: 300, payment_method_name: "Card", transaction_time: nil)
      p = pos_txn(amount: 300, payment_method: "Visa", transaction_date: Time.zone.parse("#{Date.current} 10:00:00"))

      result = described_class.call([ s ], [ p ])

      expect(result.matched_count).to eq(0)
      expect(result.missing_from_pos).to eq([ s ])
    end

    it "claims the nearest-time candidate (smallest absolute difference) when multiple are within the window" do
      s = sales_txn(amount: 300, transaction_time: "10:00:00")
      near = pos_txn(amount: 300, transaction_date: Time.zone.parse("#{Date.current} 10:03:00"))
      far  = pos_txn(amount: 300, transaction_date: Time.zone.parse("#{Date.current} 10:08:00"))

      result = described_class.call([ s ], [ far, near ])

      expect(result.matched_pairs.first.pos_transaction).to eq(near)
      expect(result.extra_in_pos).to eq([ far ])
    end

    it "consumes both records once matched — a second sales transaction with the same amount cannot reclaim them" do
      s1 = sales_txn(amount: 300, transaction_time: "10:00:00")
      s2 = sales_txn(amount: 300, transaction_time: "10:01:00")
      p  = pos_txn(amount: 300, transaction_date: Time.zone.parse("#{Date.current} 10:00:30"))

      result = described_class.call([ s1, s2 ], [ p ])

      expect(result.matched_count).to eq(1)
      expect(result.matched_pairs.first.sales_transaction).to eq(s1)
      expect(result.missing_from_pos).to eq([ s2 ])
    end
  end

  describe "missing/extra reporting" do
    it "reports an unmatched sales transaction as missing_from_pos" do
      s = sales_txn(amount: 100)

      result = described_class.call([ s ], [])

      expect(result.missing_from_pos).to eq([ s ])
      expect(result.extra_in_pos).to be_empty
    end

    it "reports an unmatched pos transaction as extra_in_pos" do
      p = pos_txn(amount: 100)

      result = described_class.call([], [ p ])

      expect(result.extra_in_pos).to eq([ p ])
      expect(result.missing_from_pos).to be_empty
    end
  end

  describe "Result aggregates" do
    it "computes totals, counts, and balanced? across matched + unmatched" do
      matched_s = sales_txn(amount: 100, reference_number: "REF-1")
      matched_p = pos_txn(amount: 100, reference_number: "REF-1")
      missing_s = sales_txn(amount: 50, reference_number: "REF-2")
      extra_p   = pos_txn(amount: 25, reference_number: "REF-3")

      result = described_class.call([ matched_s, missing_s ], [ matched_p, extra_p ])

      expect(result.sales_total).to eq(150)
      expect(result.pos_total).to eq(125)
      expect(result.difference).to eq(25)
      expect(result.sales_count).to eq(2)
      expect(result.pos_count).to eq(2)
      expect(result.matched_count).to eq(1)
      expect(result.balanced?).to be false
    end

    it "is balanced when every transaction matches with no amount mismatches" do
      s = sales_txn(amount: 100, reference_number: "REF-1")
      p = pos_txn(amount: 100, reference_number: "REF-1")

      result = described_class.call([ s ], [ p ])

      expect(result.balanced?).to be true
    end
  end
end
