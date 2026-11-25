module Inventory
  # The ONE system-managed "In Transit" warehouse of a business (Stock
  # Transfer redesign, decision D2). Dispatched transfer stock is moved into it
  # through the ordinary movement ledger (source transfer_out + transit
  # transit_in) and out of it on receipt or resolution — so it stays part of
  # the business's total on-hand (moving-average cost and valuation remain
  # correct) without a second balance system.
  #
  # .for! is the only way the row is created: idempotent and race-safe — a
  # transaction-scoped advisory lock per business serializes provisioners, the
  # partial unique index (index_warehouses_one_transit_per_business) is the
  # final backstop, and a concurrent loser simply reads the winner's row.
  # Created on first need (Phase B: the first dispatch), never for every
  # business up front, never from a branch. Audited ("provision_transit_warehouse",
  # mandatory: if the entry cannot be written nothing is created).
  #
  # .find_for reads it without creating (nil when the business never needed one).
  class TransitWarehouse
    include AuditLoggable

    LOCK_NAMESPACE = 4107 # Inventory::NumberSequencer uses 4101–4106

    def self.find_for(business)
      Warehouse.transit.find_by(business_id: business_id_of(business))
    end

    def self.for!(business, actor:) = new(business_id_of(business), actor).provision

    def self.business_id_of(business) = business.respond_to?(:id) ? business.id : Integer(business)

    def initialize(business_id, actor)
      raise ArgumentError, "an actor of the same business is required" if actor.nil? || actor.business_id != business_id

      @business_id = business_id
      @actor       = actor
    end

    def provision
      existing = self.class.find_for(@business_id)
      return existing if existing

      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", LOCK_NAMESPACE, Integer(@business_id) ])
        )
        self.class.find_for(@business_id) || create!
      end
    # A row created meanwhile outside this lock is refused by the reserved-name
    # validation or, as the last line, the unique index: read it instead.
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      self.class.find_for(@business_id) || raise
    end

    private

    def create!
      warehouse = Warehouse.new(business_id: @business_id, name: Warehouse::TRANSIT_NAME, kind: Warehouse::TRANSIT_KIND,
                                status: "active", description: "System-managed in-transit stock for stock transfers")
      warehouse.system_provisioning = true
      warehouse.save!
      log_audit!(actor: @actor, auditable: warehouse, action: "provision_transit_warehouse",
                 metadata: { business_id: @business_id })
      warehouse
    end
  end
end
