module Inventory
  # Inventory & Purchasing implementation of the Organization & Access
  # OrganizationAccess::UserWarehouseAccess contract (registered in
  # config/initializers/user_warehouse_access.rb): applies the employee form's
  # warehouse access (Batch W — warehouse access write boundary).
  #
  # Today's observable behaviour is kept: the submitted set replaces the user's
  # assignments — immediately for a persisted user (before and regardless of
  # the user's own save), on save for a new one; blank values are ignored; an
  # unknown id raises ActiveRecord::RecordNotFound and another business's
  # warehouse ActiveRecord::RecordInvalid, leaving the existing assignments as
  # they were. Who may be restricted, and how, stays User#inventory_warehouse_ids.
  #
  # Every assignment created or removed here is audited (D7) with the actor,
  # in the same transaction as the change (WarehouseAssignment#audit_actor): a
  # refused or rolled-back change leaves no entry, and an audit that cannot be
  # written rolls the change back.
  module UserWarehouseAssignments
    module_function

    def assign(user:, warehouse_ids:, actor:)
      raise ArgumentError, "an actor is required to change warehouse access" if actor.nil?
      raise ArgumentError, "the actor must belong to the user's business" if actor.business_id != user.business_id

      wanted = Warehouse.find(Array(warehouse_ids).reject(&:blank?).uniq) # RecordNotFound, as before
      return stage_for_new_user(user, wanted, actor) if user.new_record?

      WarehouseAssignment.transaction do
        current = user.warehouse_assignments.to_a
        wanted_ids = wanted.map(&:id)

        current.reject { |a| wanted_ids.include?(a.warehouse_id) }.each do |assignment|
          assignment.audit_actor = actor
          assignment.destroy!
        end
        (wanted_ids - current.map(&:warehouse_id)).each do |warehouse_id|
          WarehouseAssignment.create!(user: user, warehouse_id: warehouse_id, audit_actor: actor)
        end
      end
      user.warehouse_assignments.reset
      user.assigned_warehouses.reset
      wanted
    end

    # A new user's assignments are saved — and audited — with the user, in its
    # own save transaction (validated with it; nothing is written if it fails).
    def stage_for_new_user(user, warehouses, actor)
      warehouses.each { |warehouse| user.warehouse_assignments.build(warehouse: warehouse, audit_actor: actor) }
      warehouses
    end
  end
end
