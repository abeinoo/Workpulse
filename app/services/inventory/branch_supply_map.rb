module Inventory
  # Resolves which warehouse(s) supply each branch — the one place reports ask.
  #
  #   1. Explicit (primary): active WarehouseBranchSupply rows, set by an admin.
  #   2. Fallback (inferred): for a branch with NO active explicit link, the
  #      warehouses the posted ledger shows consumption issued from
  #      (ConsumptionLedger#supply_pairs). Never persisted automatically.
  #
  # Each link carries its source so the UI can say "علاقة مخزن محددة" vs
  # "علاقة مستنتجة من الحركات". Restricted to warehouse_ids when given (a
  # warehouse-scoped user only ever sees links to warehouses they can access).
  class BranchSupplyMap
    Link = Struct.new(:branch_id, :warehouse_id, :source, keyword_init: true) do
      def explicit? = source == :explicit
      def inferred? = source == :inferred
    end

    def initialize(business, warehouse_ids: nil)
      @business      = business
      @warehouse_ids = warehouse_ids
    end

    def links
      @links ||= begin
        explicit = explicit_rows.map { |b, w| Link.new(branch_id: b, warehouse_id: w, source: :explicit) }
        # A branch with an active explicit link never falls back — even when
        # that link points at a warehouse this user can't see.
        pinned   = WarehouseBranchSupply.active.where(business_id: @business.id).pluck(:branch_id).to_set
        inferred = ConsumptionLedger.new(@business, reasons: ConsumptionLedger::ALL_CONSUMPTION,
                                                    warehouse_ids: @warehouse_ids)
                                    .supply_pairs.reject { |b, _| pinned.include?(b) }
                                    .map { |b, w| Link.new(branch_id: b, warehouse_id: w, source: :inferred) }
        explicit + inferred
      end
    end

    def branch_ids              = links.map(&:branch_id).uniq
    def links_for_branch(id)    = links.select { |l| l.branch_id == id }
    def warehouse_ids_for(id)   = links_for_branch(id).map(&:warehouse_id).uniq
    def branch_ids_for_warehouse(id) = links.select { |l| l.warehouse_id == id }.map(&:branch_id).uniq

    # A warehouse is shared when it supplies more than one branch.
    def shared_warehouse?(id) = branch_ids_for_warehouse(id).size > 1

    def branches
      @branches ||= @business.branches.where(id: branch_ids).order(:name)
    end

    private

    def explicit_rows
      rel = WarehouseBranchSupply.active.where(business_id: @business.id)
      rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
      rel.pluck(:branch_id, :warehouse_id)
    end
  end
end
