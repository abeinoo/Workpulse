module Inventory
  # Service-level warehouse authorization (Warehouse Access hardening, Phase
  # 2): the ONE rule every inventory service applies to its actor before it
  # writes, so a service called outside its controller (console, job, another
  # service) is never a bypass. It is the same rule the controllers apply
  # (Inventory::BaseController#ensure_warehouses_accessible! and the policy
  # scopes), so the two layers can never disagree:
  #
  #   * every warehouse belongs to the actor's business, and
  #   * the actor can reach it: User#inventory_warehouse_ids (nil = every
  #     warehouse of the business; an Array — possibly empty — otherwise).
  #
  # Business owners and access_all_warehouses holders resolve to nil there,
  # so they pass for every warehouse of their own business — never another's.
  # Operation permissions stay with the policies; this decides WHERE only.
  module WarehouseReach
    class Denied < StandardError
      def initialize(msg = "warehouse outside the actor's reach") = super
    end

    module_function

    # warehouses: Warehouse records and/or ids (nils ignored). With nothing to
    # check, only an unrestricted actor passes when allow_none is true (a legacy
    # purchase request without any warehouse); otherwise nothing passes.
    def permits?(actor, *warehouses, allow_none: false)
      return false if actor.nil?

      ids   = warehouses.flatten.compact.map { |w| w.respond_to?(:id) ? w.id : Integer(w) }.uniq
      reach = actor.inventory_warehouse_ids
      return allow_none && reach.nil? if ids.empty?
      return false unless Warehouse.where(id: ids, business_id: actor.business_id).count == ids.size

      reach.nil? || (ids - reach).empty?
    rescue ArgumentError, TypeError
      false
    end

    def ensure!(actor, *warehouses, allow_none: false)
      raise Denied unless permits?(actor, *warehouses, allow_none: allow_none)
    end

    def message = I18n.t("inventory.errors.warehouse_not_accessible")
  end
end
