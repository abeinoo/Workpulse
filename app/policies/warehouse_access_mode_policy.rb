# Who may switch a business between the legacy and the fail-closed warehouse
# access rule (OrganizationAccess::WarehouseAccessMode). record: the Business.
#
# Owner-only, like ownership transfer: the switch decides how far every
# inventory permission of the business reaches, so no delegable permission
# (manage_settings, manage_inventory, access_all_warehouses) is enough. The
# actor must be active and belong to that business.
class WarehouseAccessModePolicy < ApplicationPolicy
  def update?
    record.is_a?(Business) && user.active? && user.business_id == record.id && owner?
  end
end
