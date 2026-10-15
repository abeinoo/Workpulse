require "rails_helper"

RSpec.describe Finance::Reports::VerifiedRevenue, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:card_pm)  { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true) }

  def verified_dr(branch:, business_date:, collected: {}, refund: {})
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "verified",
      opened_at: business_date.to_time, closed_at: business_date.to_time,
      business_date: business_date,
      verified_at: business_date.to_time, verified_by_id: actor.id
    )
    collected.each do |pm, amount|
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: pm, payment_method_name: pm.name,
                                 collected_amount: amount, refund_amount: refund[pm] || 0)
    end
    dr
  end

  def unverified_dr(branch:, business_date:, collected:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: business_date.to_time, closed_at: business_date.to_time, business_date: business_date
    )
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                               collected_amount: collected, refund_amount: 0)
    dr
  end

  subject(:service) { described_class.new(business, from: Date.current.beginning_of_month, to: Date.current.end_of_month) }

  it "sums collected minus refund across payment methods for a verified DR" do
    verified_dr(branch: branch, business_date: Date.current,
                collected: { cash_pm => 500, card_pm => 300 }, refund: { cash_pm => 50 })

    expect(service.total).to eq(500 - 50 + 300)
  end

  it "excludes unverified (open/closed but not verified) reconciliations" do
    unverified_dr(branch: branch, business_date: Date.current, collected: 1000)

    expect(service.total).to eq(0)
  end

  it "excludes DRs outside the requested date range" do
    verified_dr(branch: branch, business_date: 2.months.ago.to_date, collected: { cash_pm => 700 })

    expect(service.total).to eq(0)
  end

  it "returns zero/empty when there is no data for the period, not an error" do
    expect(service.total).to eq(0)
    expect(service.by_branch).to eq({})
    expect(service.by_month).to eq({})
  end

  it "groups by branch" do
    verified_dr(branch: branch, business_date: Date.current, collected: { cash_pm => 400 })
    verified_dr(branch: other_branch, business_date: Date.current, collected: { cash_pm => 250 })

    expect(described_class.new(business, from: Date.current.beginning_of_month, to: Date.current.end_of_month).by_branch)
      .to eq(branch.id => 400, other_branch.id => 250)
  end

  it "narrows to the given branch_ids" do
    verified_dr(branch: branch, business_date: Date.current, collected: { cash_pm => 400 })
    verified_dr(branch: other_branch, business_date: Date.current, collected: { cash_pm => 250 })

    scoped = described_class.new(business, from: Date.current.beginning_of_month, to: Date.current.end_of_month,
                                  branch_ids: [ branch.id ])
    expect(scoped.total).to eq(400)
  end

  it "groups by month using business_date, not created_at" do
    verified_dr(branch: branch, business_date: 1.month.ago.to_date.beginning_of_month, collected: { cash_pm => 900 })

    wide = described_class.new(business, from: 2.months.ago.to_date.beginning_of_month, to: Date.current.end_of_month)
    key  = 1.month.ago.to_date.beginning_of_month
    expect(wide.by_month.find { |k, _| k.to_date == key }&.last).to eq(900)
  end

  it "returns keys that are plain Date objects, directly usable as Hash keys by callers" do
    verified_dr(branch: branch, business_date: 1.month.ago.to_date.beginning_of_month, collected: { cash_pm => 900 })

    wide = described_class.new(business, from: 2.months.ago.to_date.beginning_of_month, to: Date.current.end_of_month)
    result = wide.by_month
    expect(result.keys).to all(be_a(Date))

    # This is the regression this test guards: Hash#[] uses #eql?, and Time#eql?(Date)
    # is always false even for the same calendar day — a Time-keyed hash silently
    # returns nil for every Date-keyed lookup a caller like the trend chart performs
    # (`months.map { |m| by_month[m] || 0 }`, where `m` is always a Date).
    key = 1.month.ago.to_date.beginning_of_month
    expect(result[key]).to eq(900)
  end

  it "does not read SalesTransaction at all" do
    expect(SalesTransaction).not_to receive(:where)
    verified_dr(branch: branch, business_date: Date.current, collected: { cash_pm => 100 })
    service.total
  end

  describe "#any?" do
    it "is false when there is no verified DR for the period" do
      expect(service.any?).to eq(false)
    end

    it "is false when only an unverified DR exists" do
      unverified_dr(branch: branch, business_date: Date.current, collected: 500)
      expect(service.any?).to eq(false)
    end

    it "is true when a verified DR exists, even if its net revenue is exactly zero" do
      verified_dr(branch: branch, business_date: Date.current, collected: { cash_pm => 100 }, refund: { cash_pm => 100 })
      expect(service.total).to eq(0)
      expect(service.any?).to eq(true)
    end

    it "respects branch_ids narrowing" do
      verified_dr(branch: other_branch, business_date: Date.current, collected: { cash_pm => 400 })
      scoped = described_class.new(business, from: Date.current.beginning_of_month, to: Date.current.end_of_month,
                                    branch_ids: [ branch.id ])
      expect(scoped.any?).to eq(false)
    end
  end

  describe "derived figures" do
    it "keeps total equal to the sum of by_branch, including refunds and branch_ids narrowing" do
      verified_dr(branch: branch, business_date: Date.current,
                  collected: { cash_pm => 500, card_pm => 300 }, refund: { cash_pm => 50 })
      verified_dr(branch: other_branch, business_date: Date.current, collected: { cash_pm => 120 })
      unverified_dr(branch: branch, business_date: Date.current - 1, collected: 999) unless Date.current.day == 1

      expect(service.by_branch).to eq(branch.id => 750, other_branch.id => 120)
      expect(service.total).to eq(870)

      scoped = described_class.new(business, from: Date.current.beginning_of_month, to: Date.current.end_of_month,
                                   branch_ids: [ other_branch.id ])
      expect(scoped.total).to eq(120)
    end

    it "answers total, any? and by_branch for one instance with a single query" do
      verified_dr(branch: branch, business_date: Date.current, collected: { cash_pm => 500 })

      queries = []
      counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        service.total
        service.any?
        service.by_branch
      end

      expect(queries.size).to eq(1)
    end
  end
end
