module OrganizationAccess
  # Branch-manager responsibility changes and the warehouse access they end
  # (Warehouse Access decisions 4–7, Phase 2). Called INSIDE the caller's
  # transaction, after the branch / account change was saved, so the change,
  # any revocation and the audit entries commit or roll back together:
  #
  #   OrganizationAccess::UpdateBranch      manager assigned / replaced / removed,
  #                                         branch reclassified sales -> non-sales
  #   OrganizationAccess::DeactivateBranch  branch deactivated
  #   User (account deactivation, set by OrganizationAccess::Accounts)
  #                                         manager's account deactivated
  #
  # What it revokes: ONLY the affected manager's EXPLICIT assignment to the
  # affected branch's own (kind "branch") warehouse — through the Organization &
  # Access contract OrganizationAccess::UserWarehouseAccess.revoke_branch_warehouse
  # (Inventory & Purchasing implements it and audits the removed assignment).
  # Every other assignment, every warehouse and every inventory record is left
  # as it is. Nothing is ever granted here: the new manager reaches the
  # branch's warehouse only through the automatic rule
  # (Inventory::WarehouseAccess — current, active, sales branch). A former
  # manager who still needs the old warehouse must be granted it again
  # explicitly (decision 7).
  #
  # Audit: one fail-closed "branch_manager_change" entry per change on the
  # branch (log_audit! — if it cannot be written the whole change rolls back),
  # with changes { branch_manager_id: [previous, new] } for a manager change and
  # metadata branch_id, branch_name, change_type, previous_manager_id,
  # new_manager_id and revoked_warehouse_assignment ({ user_id, warehouse_id }
  # or nil). Branch deactivation and reclassification are recorded only when
  # the branch has a manager (their own audit entries already exist).
  class BranchManagerLifecycle
    include AuditLoggable

    ACTION = "branch_manager_change".freeze
    CHANGE_TYPES = %w[manager_assigned manager_replaced manager_removed
                      manager_deactivated branch_deactivated branch_reclassified].freeze

    # previous: the branch's { branch_manager_id:, active:, branch_type: }
    # captured under its lock BEFORE the change.
    def self.branch_changed!(branch:, actor:, previous:)
      new(actor).branch_changed!(branch, previous)
    end

    def self.manager_deactivated!(user:, actor:)
      new(actor).manager_deactivated!(user)
    end

    def initialize(actor)
      raise ArgumentError, "an actor is required for a branch-manager change" if actor.nil?

      @actor = actor
    end

    def branch_changed!(branch, previous)
      previous_manager = previous[:branch_manager_id]
      manager          = branch.branch_manager_id

      if previous_manager != manager
        type = if previous_manager.nil? then "manager_assigned"
        elsif manager.nil? then "manager_removed"
        else "manager_replaced"
        end
        record!(branch, type, previous_manager, manager, revoke(previous_manager, branch))
      end

      if previous[:active] && !branch.active? && manager
        record!(branch, "branch_deactivated", manager, manager, revoke(manager, branch))
      end

      if previous[:branch_type].to_s == "sales" && branch.branch_type.to_s != "sales" && manager
        record!(branch, "branch_reclassified", manager, manager, revoke(manager, branch),
                extra: { previous_branch_type: previous[:branch_type].to_s, new_branch_type: branch.branch_type.to_s })
      end
    end

    # Every branch the (now inactive) user manages: their explicit assignment
    # to its warehouse is revoked. branches.branch_manager_id is not changed —
    # replacing the manager stays a separate, deliberate branch edit.
    def manager_deactivated!(user)
      Branch.where(business_id: user.business_id, branch_manager_id: user.id).order(:id).lock.each do |branch|
        record!(branch, "manager_deactivated", user.id, user.id, revoke(user.id, branch))
      end
    end

    private

    def revoke(user_id, branch)
      return nil if user_id.nil?

      UserWarehouseAccess.revoke_branch_warehouse(user_id: user_id, branch_id: branch.id, actor: @actor)
    end

    def record!(branch, change_type, previous_manager_id, new_manager_id, revoked, extra: {})
      changes = previous_manager_id == new_manager_id ? {} : { branch_manager_id: [ previous_manager_id, new_manager_id ] }
      log_audit!(actor: @actor, auditable: branch, action: ACTION, changes: changes,
                 metadata: { branch_id: branch.id, branch_name: branch.name, change_type: change_type,
                             previous_manager_id: previous_manager_id, new_manager_id: new_manager_id,
                             revoked_warehouse_assignment: revoked }.merge(extra))
    end
  end
end
