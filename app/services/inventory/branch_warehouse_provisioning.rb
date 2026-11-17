module Inventory
  # Inventory & Purchasing implementation of the Organization & Access
  # OrganizationAccess::BranchProvisioning contract (registered in
  # config/initializers/organization_access_branch_provisioning.rb): gives a
  # sales branch its one branch warehouse, "<Branch Name> – المخزن", through
  # Inventory::WarehouseManager#provision_branch_warehouse — the same save and
  # audit path as every other warehouse creation, inside the branch's
  # transaction. Idempotent (an existing branch warehouse is kept as it is);
  # any refusal raises OrganizationAccess::BranchProvisioning::Failed so the
  # branch change rolls back.
  #
  # The contract calls provision!(branch:, actor:) — the audit source is then
  # "branch_provisioning". Inventory's own backfill of existing branches
  # (Inventory::BranchWarehouseBackfill) passes source: "branch_backfill"; the
  # Organization & Access contract itself does not know about sources.
  module BranchWarehouseProvisioning
    module_function

    def provision!(branch:, actor:, source: "branch_provisioning")
      result = WarehouseManager.new(actor: actor).provision_branch_warehouse(branch: branch, source: source)
      raise OrganizationAccess::BranchProvisioning::Failed, result.error unless result.ok?

      result.warehouse
    end
  end
end
