module Inventory
  # THE warehouse rule for Stock Issues and Quick Issues: stock is issued from
  # a warehouse the actor is authorized to use. One path for the forms (which
  # warehouses are offered, which one is preselected) and for every service
  # that sets, changes or acts on an issue's warehouse — so a crafted request
  # is refused server-side, never only by the dropdown.
  #
  # Reach comes from the approved warehouse-access rule (User#inventory_warehouse_ids
  # through Inventory::WarehouseReach — owners and access_all_warehouses
  # holders reach every warehouse of their own business; in a fail-closed
  # business the others reach only what Inventory::WarehouseAccess grants).
  # It is independent of the operation permissions (Inventory::StockIssueAuthorization):
  # an action needs both.
  #
  #   #warehouses / #issuable?  ACTIVE warehouses of the actor's business that
  #                             the actor reaches — what a NEW issue (or an edit
  #                             that changes the warehouse) may use.
  #   #default_warehouse_id     the only one, when there is exactly one
  #                             (selected automatically); nil otherwise.
  #   #sees?                    the issue's warehouse is reachable (active or
  #                             not), so history stays visible to the people
  #                             who reach it; every workflow service checks it.
  #
  # Never infers a warehouse from a branch, and never falls back to another
  # warehouse.
  class IssueWarehouseReach
    def self.for(actor) = new(actor)

    def initialize(actor)
      @actor = actor
    end

    # Active warehouses the actor may issue from, by name.
    def warehouses
      return Warehouse.none if @actor&.business_id.nil?

      relation = Warehouse.where(business_id: @actor.business_id).operational.active.ordered
      ids = @actor.inventory_warehouse_ids
      ids.nil? ? relation : relation.where(id: ids)
    end

    def warehouse_ids = @warehouse_ids ||= warehouses.pluck(:id)

    def none? = warehouse_ids.empty?

    # Selected automatically only when the choice is not a choice.
    def default_warehouse_id = (warehouse_ids.first if warehouse_ids.size == 1)

    # The warehouse may be used for a new issue / a changed warehouse: own
    # business, ACTIVE, and reached by the actor. Re-reads the row (never
    # trusts a loaded or submitted record).
    def issuable?(warehouse_or_id)
      id = warehouse_or_id.respond_to?(:id) ? warehouse_or_id.id : warehouse_or_id
      return false if @actor.nil? || id.blank? || !id.to_s.match?(/\A\d+\z/)

      Warehouse.where(business_id: @actor.business_id, id: id.to_i).operational.active.exists? &&
        WarehouseReach.permits?(@actor, id.to_i)
    end

    # The actor reaches the issue's warehouse (whatever its status).
    def sees?(issue)
      return false if @actor.nil? || issue.nil? || issue.warehouse_id.nil?

      issue.business_id == @actor.business_id && WarehouseReach.permits?(@actor, issue.warehouse_id)
    end

    # Re-verifies an issue's STORED warehouse inside the caller's transaction
    # (approval, confirmation): the row is locked FOR SHARE — so a concurrent
    # deactivation, which updates it, cannot commit between this check and the
    # reservation / deduction that follows — and must be of the issue's
    # business, ACTIVE and still reached by the actor. Returns nil when fine,
    # otherwise the message. Never re-resolves or replaces the warehouse.
    def verify_under_lock(issue)
      warehouse = Warehouse.where(id: issue.warehouse_id, business_id: issue.business_id).lock("FOR SHARE").first
      return I18n.t("inventory.issue_warehouse.errors.missing") if warehouse.nil?
      return I18n.t("inventory.issue_warehouse.errors.inactive", warehouse: warehouse.name) unless warehouse.active?
      return WarehouseReach.message unless WarehouseReach.permits?(@actor, warehouse.id)

      nil
    end

    # The message for a refused or unavailable warehouse choice.
    def message
      return I18n.t("inventory.issue_warehouse.errors.none_accessible") if none?

      I18n.t("inventory.issue_warehouse.errors.not_allowed")
    end

    def not_visible_message = I18n.t("inventory.issue_warehouse.errors.issue_not_visible")
  end
end
