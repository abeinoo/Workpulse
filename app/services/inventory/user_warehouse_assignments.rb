module Inventory
  # Inventory & Purchasing implementation of the Organization & Access
  # OrganizationAccess::UserWarehouseAccess contract (registered in
  # config/initializers/user_warehouse_access.rb): the only application write
  # path of explicit warehouse assignments.
  #
  # #assign applies a submitted set of warehouses — immediately for a persisted
  # user (before and regardless of the user's own save), on save for a new
  # one; blank values are ignored; an unknown id raises
  # ActiveRecord::RecordNotFound and another business's warehouse
  # ActiveRecord::RecordInvalid, leaving the existing assignments as they were.
  #
  # Authorization (Warehouse Access hardening, Phase 2) is enforced HERE, not
  # only by the form, so no caller can bypass it:
  #   * the actor holds manage_warehouse_access, is not changing their own
  #     access, and controls the user (OrganizationAccess::UserWarehouseAccess.manageable? —
  #     management scope + PermissionGrants.covers?);
  #   * the actor may only add or remove warehouses they can reach themselves
  #     (User#inventory_warehouse_ids; nil = every warehouse of the business),
  #     and only an ACTIVE warehouse may be newly granted;
  #   * assignments to warehouses outside the actor's reach are left exactly
  #     as they are (the actor cannot see them, so their absence from the
  #     submitted set is not a request to remove them).
  # A refusal raises OrganizationAccess::UserWarehouseAccess::Refused before
  # anything is written.
  #
  # #revoke_branch_warehouse removes one user's explicit assignment to one
  # branch's own warehouse (branch-manager lifecycle; see
  # OrganizationAccess::BranchManagerLifecycle). Nothing else is touched.
  #
  # Every assignment created or removed is audited (D7) with the actor, in the
  # same transaction as the change (WarehouseAssignment#audit_actor): a refused
  # or rolled-back change leaves no entry, and an audit that cannot be written
  # rolls the change back.
  module UserWarehouseAssignments
    Refused = OrganizationAccess::UserWarehouseAccess::Refused

    module_function

    def assign(user:, warehouse_ids:, actor:)
      raise ArgumentError, "an actor is required to change warehouse access" if actor.nil?
      raise ArgumentError, "the actor must belong to the user's business" if actor.business_id != user.business_id

      authorize!(actor, user)
      wanted = Warehouse.find(Array(warehouse_ids).reject(&:blank?).uniq) # RecordNotFound, as before
      refuse_other_business!(user, wanted)
      reach = actor.inventory_warehouse_ids # nil = every warehouse of the business
      return stage_for_new_user(user, wanted, actor, reach) if user.new_record?

      WarehouseAssignment.transaction do
        current    = user.warehouse_assignments.to_a
        wanted_ids = wanted.map(&:id)
        added      = wanted.reject { |warehouse| current.any? { |a| a.warehouse_id == warehouse.id } }
        removed    = current.reject { |a| wanted_ids.include?(a.warehouse_id) }
        removed    = removed.select { |a| reach.include?(a.warehouse_id) } if reach # outside reach: untouched
        added.each { |warehouse| grantable!(warehouse, reach) }

        removed.each do |assignment|
          assignment.audit_actor = actor
          assignment.destroy!
        end
        added.each do |warehouse|
          WarehouseAssignment.create!(user: user, warehouse_id: warehouse.id, audit_actor: actor)
        end
      end
      user.warehouse_assignments.reset
      user.assigned_warehouses.reset
      wanted
    end

    # Removes user_id's explicit assignment to branch_id's own warehouse (kind
    # "branch", of the actor's business), audited in the actor's name. Runs in
    # the caller's transaction. { user_id:, warehouse_id: } or nil.
    def revoke_branch_warehouse(user_id:, branch_id:, actor:)
      raise ArgumentError, "an actor is required to change warehouse access" if actor.nil?
      return nil if user_id.nil? || branch_id.nil?

      warehouse = Warehouse.find_by(business_id: actor.business_id, kind: "branch", branch_id: branch_id)
      return nil unless warehouse

      assignment = WarehouseAssignment.lock.find_by(user_id: user_id, warehouse_id: warehouse.id)
      return nil unless assignment

      assignment.audit_actor = actor
      assignment.destroy!
      { user_id: user_id, warehouse_id: warehouse.id }
    end

    # A new user's assignments are saved — and audited — with the user, in its
    # own save transaction (validated with it; nothing is written if it fails).
    def stage_for_new_user(user, warehouses, actor, reach)
      warehouses.each { |warehouse| grantable!(warehouse, reach) }
      warehouses.each { |warehouse| user.warehouse_assignments.build(warehouse: warehouse, audit_actor: actor) }
      warehouses
    end

    def authorize!(actor, user)
      raise Refused, :own_access if actor.id == user.id && user.persisted?
      raise Refused, :not_permitted unless actor.can?(:manage_warehouse_access)
      raise Refused, :not_in_scope unless OrganizationAccess::UserWarehouseAccess.manageable?(actor: actor, user: user)
    end

    # Another business's warehouse keeps its historical error (RecordInvalid
    # from WarehouseAssignment#same_business), never a reach refusal.
    # Another business's warehouse, or the system transit warehouse (never
    # assignable — OperationalWarehouseReference), is refused the same way:
    # the assignment's own validation raises RecordInvalid, nothing changes.
    def refuse_other_business!(user, warehouses)
      foreign = warehouses.find { |warehouse| warehouse.business_id != user.business_id || warehouse.transit? }
      WarehouseAssignment.new(user: user, warehouse: foreign).validate! if foreign
    end

    def grantable!(warehouse, reach)
      raise Refused, :outside_reach if reach && !reach.include?(warehouse.id)
      raise Refused, :inactive_warehouse unless warehouse.active?
    end
  end
end
