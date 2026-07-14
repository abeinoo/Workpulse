# Effective-dated history of the standard laundry-service cost charged to
# branches per towel, configured INDEPENDENTLY per towel type (a Drying Towel
# and a Hot Towel wash for different costs). Rows are immutable and
# append-only — changing the rate inserts a new row for that towel type (see
# Laundry::StandardCostRateSetter); nothing here is ever edited or deleted,
# so historical branch-consumption reports keep resolving to whatever rate
# was effective for that towel type at the time, even after the current rate
# changes.
#
# towel_type_id is nullable only to accommodate rows created before towel
# types existed as a per-rate dimension (a single global cost per business) —
# see the migration for why those are never backfilled/reassigned. Every row
# created going forward requires a towel_type (see the presence validation).
class LaundryStandardCostRate < ApplicationRecord
  belongs_to :business
  belongs_to :towel_type, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :cost_per_towel, numericality: { greater_than_or_equal_to: 0 }
  validates :effective_from, presence: true
  validates :towel_type, presence: true
  validate  :towel_type_in_same_business

  scope :for_business,   ->(business)   { where(business: business) }
  scope :for_towel_type, ->(towel_type) { where(towel_type: towel_type) }
  scope :chronological,  -> { order(:effective_from) }

  # The rate effective at a given instant for one towel type — the latest row
  # whose effective_from is at or before `at`. Returns nil if no rate has
  # ever been configured for that towel type (callers must handle this
  # explicitly, never silently treat it as zero).
  def self.effective_for(business, towel_type:, at:)
    for_business(business).for_towel_type(towel_type).where(effective_from: ..at)
                          .order(effective_from: :desc).first
  end

  # The current rate for every towel type in `towel_type_ids`, in one query —
  # avoids N+1 on the Towel Types index. { towel_type_id => rate }.
  def self.current_by_towel_type(business, towel_type_ids)
    for_business(business).where(towel_type_id: towel_type_ids, effective_from: ..Time.current)
                          .group_by(&:towel_type_id)
                          .transform_values { |rows| rows.max_by(&:effective_from) }
  end

  # All distinct rates for one towel type that applied at any point during
  # [from, to] — used to detect "multiple rates applied this period" on the
  # consumption report.
  def self.applicable_during(business, towel_type:, from:, to:)
    rates = for_business(business).for_towel_type(towel_type).chronological.to_a
    # The rate effective at `from` (if any) still applies going forward even
    # though its own effective_from predates the window.
    prior = rates.select { |r| r.effective_from <= from }.last
    within = rates.select { |r| r.effective_from > from && r.effective_from <= to }
    [ prior, *within ].compact.uniq
  end

  private

  def towel_type_in_same_business
    return if business_id.nil? || towel_type.nil?
    errors.add(:towel_type, :invalid) if towel_type.business_id != business_id
  end
end
