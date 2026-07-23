module Laundry
  # Derives towel balances from the immutable TowelLedgerEntry ledger. Balance
  # is never stored — always SUM(in) - SUM(out) — mirroring Inventory::StockLevels.
  class TowelBalances
    SIGNED_SUM = "COALESCE(SUM(CASE WHEN direction = 'in' THEN quantity ELSE -quantity END), 0)".freeze

    def initialize(towel_type)
      @towel_type = towel_type
    end

    # On-hand for one status at one branch (e.g. dirty towels waiting at a
    # branch, or clean towels available at the laundry).
    def at_branch(branch, status)
      branch_id = branch.respond_to?(:id) ? branch.id : branch
      @towel_type.towel_ledger_entries
                 .where(branch_id: branch_id, status: status)
                 .pick(Arel.sql(SIGNED_SUM)) || 0
    end

    # { status => quantity } for a single branch — the basis for branch/laundry
    # dashboards (clean/dirty/damaged/disposed/lost at that location).
    def by_status_for_branch(branch)
      branch_id = branch.respond_to?(:id) ? branch.id : branch
      @towel_type.towel_ledger_entries
                 .where(branch_id: branch_id)
                 .group(:status)
                 .sum(Arel.sql("CASE WHEN direction = 'in' THEN quantity ELSE -quantity END"))
    end

    # The single "operational" balance for a branch — clean-on-hand for a
    # sales branch, dirty-on-hand (awaiting wash) for the laundry. Never sums
    # clean+dirty; the location alone determines which status is meaningful
    # to a normal operational user (see towel_balances#index).
    def operational(branch)
      branch.branch_type_laundry? ? at_branch(branch, "dirty") : at_branch(branch, "clean")
    end

    # Quantity currently "in transit" for this towel type: derived from open
    # TowelTransfer rows (dispatched, not yet received/cancelled) — never a
    # ledger balance, per the towel-domain design (state derived from data
    # shape, not a stored flag).
    def in_transit(branch: nil)
      scope = @towel_type.towel_transfer_items.joins(:towel_transfer).merge(TowelTransfer.dispatched)
      scope = scope.where(towel_transfers: { source_branch_id: branch }) if branch.present?
      scope.sum(:declared_quantity)
    end

    # Class helper: on-hand for every towel type at once, restricted to a
    # business — avoids N+1 on dashboard pages.
    def self.totals_for(business, branch_id: nil)
      relation = TowelLedgerEntry.for_business(business)
      relation = relation.where(branch_id: branch_id) if branch_id
      relation.group(:towel_type_id, :status)
              .sum(Arel.sql("CASE WHEN direction = 'in' THEN quantity ELSE -quantity END"))
    end

    # Same shape of row as the controller builds per-towel-type today
    # ({ branch:, operational:, clean:, dirty:, damaged:, disposed:, lost:,
    # in_transit_out: }), but for every towel type across every branch in two
    # aggregate queries total — used by the "All towel types" balances view so
    # rendering N towel-type sections never costs N x branches queries.
    def self.batch_rows_for(towel_types, branches)
      towel_type_ids = towel_types.map(&:id)
      branch_ids = branches.map(&:id)

      status_totals = Hash.new { |h, k| h[k] = {} }
      TowelLedgerEntry.where(towel_type_id: towel_type_ids, branch_id: branch_ids)
                      .group(:towel_type_id, :branch_id, :status)
                      .sum(Arel.sql("CASE WHEN direction = 'in' THEN quantity ELSE -quantity END"))
                      .each { |(towel_type_id, branch_id, status), amount| status_totals[[ towel_type_id, branch_id ]][status] = amount }

      transit_totals = TowelTransferItem.joins(:towel_transfer).merge(TowelTransfer.dispatched)
                                       .where(towel_type_id: towel_type_ids, towel_transfers: { source_branch_id: branch_ids })
                                       .group(:towel_type_id, "towel_transfers.source_branch_id")
                                       .sum(:declared_quantity)

      towel_types.index_with do |towel_type|
        branches.map do |branch|
          by_status = status_totals[[ towel_type.id, branch.id ]]
          operational = branch.branch_type_laundry? ? (by_status["dirty"] || 0) : (by_status["clean"] || 0)
          { branch: branch, operational: operational,
            clean: by_status["clean"] || 0, dirty: by_status["dirty"] || 0,
            damaged: by_status["damaged"] || 0, disposed: by_status["disposed"] || 0,
            lost: by_status["lost"] || 0,
            in_transit_out: transit_totals[[ towel_type.id, branch.id ]] || 0 }
        end
      end
    end
  end
end
