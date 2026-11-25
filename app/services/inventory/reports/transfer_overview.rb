module Inventory
  module Reports
    # The inventory dashboard's Stock Transfers card: how many transfers the
    # viewer may see (StockTransferPolicy::Scope) are in each stage. Read-only;
    # three grouped queries. "Partially received" is derived (in transit with a
    # receipt); "completed" counts the last 30 days.
    class TransferOverview
      STAGES = %w[pending_approval awaiting_dispatch in_transit partially_received discrepancy completed].freeze

      def initialize(scope)
        @scope = scope.active
      end

      def counts
        @counts ||= begin
          by_status = @scope.where(status: %w[pending_approval awaiting_dispatch in_transit discrepancy]).group(:status).count
          partial   = @scope.in_transit.where(id: StockTransferReceipt.select(:stock_transfer_id)).count
          completed = @scope.where(status: "received", received_at: 30.days.ago..).count
          {
            "pending_approval"   => by_status["pending_approval"].to_i,
            "awaiting_dispatch"  => by_status["awaiting_dispatch"].to_i,
            "in_transit"         => by_status["in_transit"].to_i - partial,
            "partially_received" => partial,
            "discrepancy"        => by_status["discrepancy"].to_i,
            "completed"          => completed
          }
        end
      end

      def any? = counts.values.any?(&:positive?)
    end
  end
end
