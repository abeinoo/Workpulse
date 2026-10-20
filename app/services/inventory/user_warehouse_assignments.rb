module Inventory
  # Inventory & Purchasing implementation of the Organization & Access
  # OrganizationAccess::UserWarehouseAccess contract (registered in
  # config/initializers/user_warehouse_access.rb): applies the employee form's
  # warehouse access (Batch W — warehouse access write boundary).
  #
  # Today's behaviour, unchanged: the has_many :through ids writer replaces the
  # user's WarehouseAssignment rows — immediately for a persisted user (before
  # and regardless of the user's own save), on save for a new one; blank values
  # are ignored; an unknown id raises ActiveRecord::RecordNotFound and another
  # business's warehouse ActiveRecord::RecordInvalid (WarehouseAssignment's
  # same-business validation). Who may be restricted, and how, stays
  # User#inventory_warehouse_ids (no assignment = every warehouse).
  module UserWarehouseAssignments
    module_function

    def assign(user:, warehouse_ids:)
      user.assigned_warehouse_ids = warehouse_ids
    end
  end
end
