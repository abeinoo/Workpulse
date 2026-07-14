module Laundry
  # Per-business sequential batch numbers ("LB-000123"). Race-safe via a
  # transaction-level Postgres advisory lock, mirroring
  # Inventory::NumberSequencer. Must be called inside the transaction that
  # persists the batch so the lock is held until COMMIT.
  class BatchNumberSequencer
    LOCK_NAMESPACE = 4201
    PREFIX = "LB".freeze
    PAD = 6

    def initialize(business)
      @business = business
    end

    def next_number
      ActiveRecord::Base.connection.execute(
        "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{@business.id.to_i})"
      )
      "#{PREFIX}-#{format("%0#{PAD}d", next_sequence)}"
    end

    private

    def next_sequence
      highest = LaundryBatch.where(business: @business)
                            .where("batch_number LIKE ?", "#{PREFIX}-%")
                            .pluck(:batch_number)
                            .filter_map { |n| n.delete_prefix("#{PREFIX}-")[/\A\d+\z/]&.to_i }
                            .max
      (highest || 0) + 1
    end
  end
end
