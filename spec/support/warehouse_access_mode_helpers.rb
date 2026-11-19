# Test-only: stores raw values under Business settings keys directly in the
# column (update_column — no callbacks), the way a fixture would. In the
# application the warehouse access mode is written only by the audited
# OrganizationAccess::WarehouseAccessMode, and every other Business save keeps
# the stored mode (Business#merge_settings_onto_stored) — so specs that need a
# business in a given mode (or a malformed value) set it here.
module WarehouseAccessModeHelpers
  def store_business_settings!(business, values)
    business.update_column(:settings, (business.reload.settings || {}).merge(values))
    business.reload
  end

  def store_warehouse_access_fail_closed!(business, value = true)
    store_business_settings!(business, Business::WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING => value)
  end
end

RSpec.configure { |config| config.include WarehouseAccessModeHelpers }
