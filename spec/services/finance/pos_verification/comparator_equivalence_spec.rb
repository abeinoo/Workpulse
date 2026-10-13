require "rails_helper"

# Golden test for the indexed Comparator (reference/amount/date grouping and
# set-based consumption): on thousands of generated datasets built to hit
# every matching rule's edge cases, it must produce exactly what the frozen
# original algorithm (spec/support/legacy_pos_comparator.rb) produces — the
# same pairs, in the same order, by the same tier, with the same leftovers in
# the same order.
RSpec.describe Finance::PosVerification::Comparator, "equivalence with the original algorithm" do
  # Stand-in for an ActiveRecord row: equality, eql? and hash by id — the same
  # contract ActiveRecord::Core gives persisted records, which is what both
  # Array#delete (original) and Set membership (optimized) rely on.
  # (Defined with let, not as constants, so nothing leaks to the top level.)
  let(:row_class) do
    Struct.new(:id, :amount, :reference_number, :transaction_date, :transaction_time) do
      def ==(other) = other.is_a?(self.class) && other.id == id
      alias_method :eql?, :==
      def hash = id.hash
    end
  end

  let(:refs) { [ nil, "", "   ", "AB12", "ab12", " AB 12 ", "a b\t1 2", "ZZ9", "zz9", "Q-1", "q-1 " ].freeze }

  def signature(result)
    {
      pairs:   result.matched_pairs.map { |p| [ p.sales_transaction.id, p.pos_transaction.id, p.method ] },
      missing: result.missing_from_pos.map(&:id),
      extra:   result.extra_in_pos.map(&:id)
    }
  end

  # Amounts drawn from a small set so many rows share an amount; sales use
  # scale 4 and POS scale 2 (as in the schema), plus zero and negative zero.
  def amount(rng, scale)
    v = [ "50", "100", "100.5", "0", "-0", "250" ].sample(random: rng)
    BigDecimal(scale == 4 ? format("%.4f", BigDecimal(v)) : format("%.2f", BigDecimal(v))).then { |d| v == "-0" ? -d.abs : d }
  end

  def dataset(rng)
    zone  = Time.zone
    days  = [ Date.new(2026, 9, 10), Date.new(2026, 9, 11) ]
    ids   = (1..200).to_a.shuffle(random: rng)
    # Anchor times cluster sales and POS together, including exact ±600 s
    # window edges and equal distances either side (tie-breaking).
    anchors = [ [ 0, 5 ], [ 12, 0 ], [ 12, 10 ], [ 23, 55 ] ]

    sales = Array.new(rng.rand(0..14)) do
      h, m = anchors.sample(random: rng)
      sec  = [ 0, 30, 59 ].sample(random: rng)
      time = rng.rand < 0.15 ? nil : Time.utc(2000, 1, 1, h, m, sec)
      row_class.new(ids.pop, amount(rng, 4), refs.sample(random: rng), days.sample(random: rng), time)
    end

    pos = Array.new(rng.rand(0..14)) do
      h, m  = anchors.sample(random: rng)
      day   = days.sample(random: rng)
      shift = [ -600, -599, -300, -30, 0, 30, 300, 599, 600, 601, -3600 ].sample(random: rng)
      at    = zone.local(day.year, day.month, day.day, h, m, [ 0, 30, 59 ].sample(random: rng)) + shift
      row_class.new(ids.pop, amount(rng, 2), refs.sample(random: rng), at, nil)
    end

    # The same record passed twice (both sides), as Array#delete-vs-Set
    # consumption must treat duplicates identically.
    sales << sales.sample(random: rng) if sales.any? && rng.rand < 0.2
    pos   << pos.sample(random: rng)   if pos.any?   && rng.rand < 0.2

    [ sales.shuffle(random: rng), pos.shuffle(random: rng) ]
  end

  it "matches the original on 3,000 generated datasets (pairs, tiers, ordering, leftovers)" do
    Time.use_zone("Africa/Cairo") do
      mismatches = []
      matched_total = Hash.new(0)

      3_000.times do |seed|
        sales, pos = dataset(Random.new(seed))
        expected = signature(LegacyPosComparator::Comparator.call(sales, pos))
        actual   = signature(described_class.call(sales, pos))
        expected[:pairs].each { |_, _, method| matched_total[method] += 1 }
        mismatches << seed unless actual == expected
      end

      expect(mismatches).to be_empty, "datasets differing from the original: seeds #{mismatches.first(10)}"
      # Guard against a vacuous pass: both tiers really did fire, many times.
      expect(matched_total[:reference_number]).to be > 1_000
      expect(matched_total[:amount_date_time_window]).to be > 500
    end
  end

  it "matches the original under a different time zone (date bucketing follows Time.zone)" do
    Time.use_zone("UTC") do
      500.times do |seed|
        sales, pos = dataset(Random.new(10_000 + seed))
        expect(signature(described_class.call(sales, pos)))
          .to eq(signature(LegacyPosComparator::Comparator.call(sales, pos))), "seed #{10_000 + seed}"
      end
    end
  end

  it "treats amounts equal across scales (and 0 / -0) as the same candidate, like the original" do
    Time.use_zone("Africa/Cairo") do
      at    = Time.zone.local(2026, 9, 10, 12, 0, 0)
      sales = [ row_class.new(1, BigDecimal("100.0000"), nil, at.to_date, Time.utc(2000, 1, 1, 12, 0, 0)),
                row_class.new(2, -BigDecimal("0"), nil, at.to_date, Time.utc(2000, 1, 1, 12, 0, 0)) ]
      pos   = [ row_class.new(3, BigDecimal("100.00"), nil, at, nil), row_class.new(4, BigDecimal("0.00"), nil, at, nil) ]

      expect(signature(described_class.call(sales, pos)))
        .to eq(signature(LegacyPosComparator::Comparator.call(sales, pos)))
      expect(described_class.call(sales, pos).matched_pairs.size).to eq(2)
    end
  end
end
