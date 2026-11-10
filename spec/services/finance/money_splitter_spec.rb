require "rails_helper"

RSpec.describe Finance::MoneySplitter do
  def d(values) = values.map(&:to_d)

  describe ".split" do
    it "rounds every part but the last to 2 dp and gives the last part the exact residual" do
      expect(described_class.split(100, 3) { BigDecimal(100) / 3 }).to eq(d(%w[33.33 33.33 33.34]))
    end

    it "rounds half away from zero" do
      expect(described_class.split(BigDecimal("10.05"), 2) { BigDecimal("5.025") }).to eq(d(%w[5.03 5.02]))
      expect(described_class.split(BigDecimal("-10.05"), 2) { BigDecimal("-5.025") }).to eq(d(%w[-5.03 -5.02]))
    end

    it "gives a single part the whole total without asking for its share" do
      expect(described_class.split(BigDecimal("99.99"), 1) { raise "not called" }).to eq(d(%w[99.99]))
    end

    it "returns no parts for a count of zero" do
      expect(described_class.split(100, 0) { raise "not called" }).to eq([])
    end

    it "asks for each share by index, in order, never for the last part" do
      asked = []
      described_class.split(100, 4) { |i| asked << i; 25 }
      expect(asked).to eq([ 0, 1, 2 ])
    end

    it "splits a zero total into zero parts" do
      expect(described_class.split(BigDecimal(0), 3) { BigDecimal(0) }).to eq(d(%w[0 0 0]))
    end

    it "does not validate: shares larger than the total leave a negative residual" do
      expect(described_class.split(100, 2) { 60 }).to eq(d(%w[60 40]))
      expect(described_class.split(100, 3) { 60 }).to eq(d(%w[60 60 -20]))
    end

    it "can round a share to zero (callers that need a positive part must check)" do
      expect(described_class.split(100, 3) { BigDecimal("0.001") }).to eq(d(%w[0 0 100]))
    end
  end

  describe "properties" do
    let(:random) { Random.new(20_261_107) }

    def random_amount(max_cents) = BigDecimal(random.rand(1..max_cents)) / 100

    it "sums exactly to the total and is deterministic, for many parts" do
      200.times do
        total  = random_amount(10_000_000)
        count  = random.rand(1..60)
        weights = Array.new(count) { random.rand(1..1000) }
        sum     = weights.sum
        share   = ->(i) { total * weights[i] / sum }

        parts = described_class.split(total, count, &share)

        expect(parts.sum).to eq(total)
        expect(parts.first(count - 1)).to all(satisfy { |p| p == p.round(2) })
        expect(described_class.split(total, count, &share)).to eq(parts)
      end
    end
  end

  # Parity with the three loops the splitter replaced (copied verbatim from
  # AllocationCalculator#apply_equal / #distribute_amounts and
  # PayrollInsuranceExpense#build_manual_allocations before R2).
  describe "parity with the replaced implementations" do
    let(:random) { Random.new(20_261_007) }

    def legacy_equal_percentages(n)
      pct = (BigDecimal(100) / n).round(2)
      Array.new(n) { |i| (i == n - 1) ? 100 - (pct * (n - 1)) : pct }
    end

    def legacy_amounts(total, percentages)
      running = BigDecimal(0)
      percentages.each_with_index.map do |pct, i|
        if i == percentages.size - 1
          total - running
        else
          amt = (total * pct.to_d / 100).round(2)
          running += amt
          amt
        end
      end
    end

    def legacy_insurance_percentages(amounts, employer_total)
      running_pct = 0.to_d
      amounts.each_with_index.map do |amount, i|
        pct = if i == amounts.size - 1
          100 - running_pct
        else
          (amount.to_d / employer_total.to_d * 100).round(2)
        end
        running_pct += pct
        pct
      end
    end

    it "matches equal percentages for 1–100 parts" do
      (1..100).each do |n|
        expect(described_class.split(100, n) { BigDecimal(100) / n }).to eq(legacy_equal_percentages(n)), "n=#{n}"
      end
    end

    it "matches amounts from percentages, including negative totals and non-100 percentages" do
      300.times do
        total = random_amount_signed
        percentages = Array.new(random.rand(1..40)) { BigDecimal(random.rand(1..10_000)) / 100 }

        parts = described_class.split(total, percentages.size) { |i| total * percentages[i].to_d / 100 }

        expect(parts).to eq(legacy_amounts(total, percentages)), "total=#{total.to_s('F')} pct=#{percentages.map { |p| p.to_s('F') }}"
      end
    end

    it "matches insurance percentages from exact branch amounts" do
      300.times do
        amounts = Array.new(random.rand(2..40)) { BigDecimal(random.rand(1..5_000_000)) / 100 }
        total   = amounts.sum

        parts = described_class.split(100, amounts.size) { |i| amounts[i].to_d / total.to_d * 100 }

        expect(parts).to eq(legacy_insurance_percentages(amounts, total)), "amounts=#{amounts.map { |a| a.to_s('F') }}"
      end
    end

    def random_amount_signed
      cents = random.rand(0..10_000_000)
      BigDecimal(random.rand < 0.2 ? -cents : cents) / 100
    end
  end
end
