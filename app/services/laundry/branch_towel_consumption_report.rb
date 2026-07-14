module Laundry
  # Read-only report: how many towels each sales branch had CONFIRMED received
  # at the central laundry during a period, and the standard laundry-service
  # cost that implies — using the rate effective FOR THAT TOWEL TYPE at each
  # individual receipt time, never the current rate applied in bulk and never
  # another towel type's rate. Never writes anything.
  #
  # Counts only: status == "received", source branch is a sales branch,
  # destination branch is the laundry — this excludes draft/dispatched-only/
  # cancelled transfers (cancelling flips status away from "received"),
  # laundry->branch returns, branch->branch transfers, and any transfer not
  # ending at the laundry, by construction. Uses confirmed_quantity, never
  # declared_quantity.
  class BranchTowelConsumptionReport
    Event = Struct.new(:transfer, :received_at, :towel_type, :confirmed_quantity, :rate, :line_total,
                       keyword_init: true)
    Row = Struct.new(:branch, :towel_count, :multiple_rates, :missing_rate, :single_rate, :total_cost, :events,
                     keyword_init: true)
    Result = Struct.new(:rows, :total_towels, :total_cost, :rate_configured, keyword_init: true)

    def initialize(business, from:, to:, branch_id: nil, towel_type_id: nil)
      @business      = business
      @from          = from
      @to            = to
      @branch_id     = branch_id
      @towel_type_id = towel_type_id
    end

    def call
      rates = LaundryStandardCostRate.for_business(@business).chronological.to_a
      rates_by_towel_type = rates.group_by(&:towel_type_id)

      events_by_branch = Hash.new { |h, k| h[k] = [] }
      relevant_transfers.each do |transfer|
        rate = rate_effective_at(rates_by_towel_type[transfer.towel_type_id] || [], transfer.received_at)
        events_by_branch[transfer.source_branch_id] << Event.new(
          transfer:           transfer,
          received_at:        transfer.received_at,
          towel_type:         transfer.towel_type,
          confirmed_quantity: transfer.confirmed_quantity,
          rate:               rate&.cost_per_towel,
          line_total:         rate ? transfer.confirmed_quantity * rate.cost_per_towel : nil
        )
      end

      branches = @business.branches.where(id: events_by_branch.keys).index_by(&:id)
      rows = events_by_branch.map do |branch_id, events|
        distinct_rates = events.filter_map(&:rate).uniq
        Row.new(
          branch:         branches[branch_id],
          towel_count:    events.sum(&:confirmed_quantity),
          multiple_rates: distinct_rates.size > 1,
          missing_rate:   events.any? { |e| e.rate.nil? },
          single_rate:    distinct_rates.size == 1 ? distinct_rates.first : nil,
          total_cost:     events.sum { |e| e.line_total || 0 },
          events:         events.sort_by(&:received_at)
        )
      end.sort_by { |r| r.branch.name }

      Result.new(
        rows:            rows,
        total_towels:    rows.sum(&:towel_count),
        total_cost:      rows.sum(&:total_cost),
        rate_configured: rates.any?
      )
    end

    private

    def relevant_transfers
      range = @from.to_date.beginning_of_day..@to.to_date.end_of_day
      scope = TowelTransfer.for_business(@business)
                           .received
                           .where(received_at: range)
                           .where.not(confirmed_quantity: nil)
                           .includes(:source_branch, :destination_branch, :towel_type)
      scope = scope.where(source_branch_id: @branch_id) if @branch_id.present?
      scope = scope.where(towel_type_id: @towel_type_id) if @towel_type_id.present?

      scope.select do |t|
        t.source_branch&.branch_type_sales? && t.destination_branch&.branch_type_laundry?
      end
    end

    def rate_effective_at(rates, at)
      rates.select { |r| r.effective_from <= at }.max_by(&:effective_from)
    end
  end
end
