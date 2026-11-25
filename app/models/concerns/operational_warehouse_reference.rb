# Refuses a reference to the system transit warehouse (Warehouse#transit?) on
# a model whose warehouse must be an operational one — documents, warehouse
# assignments, availability settings, supply links:
#
#   operational_warehouse :warehouse
#   operational_warehouse :source_warehouse, :destination_warehouse
#
# Checked when the record is created or the reference changes. The database
# enforces the same rule (the *_operational_warehouse_only triggers), so no
# write path — form, service, import, console — can get around it.
module OperationalWarehouseReference
  extend ActiveSupport::Concern

  class_methods do
    def operational_warehouse(*associations)
      validate do
        associations.each do |name|
          foreign_key = self.class.reflect_on_association(name).foreign_key
          next unless new_record? || will_save_change_to_attribute?(foreign_key)

          warehouse = public_send(name)
          errors.add(foreign_key, :transit_warehouse) if warehouse&.transit?
        end
      end
    end
  end
end
