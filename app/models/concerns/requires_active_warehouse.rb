# Refuses NEW inventory work against an inactive warehouse (Warehouse Access
# hardening, Phase 2, scenario J) at the model level, so no write path —
# controller, service, import, console — relies on dropdown filtering alone.
#
#   requires_active_warehouse :warehouse, transitions: { status: %w[confirmed] }
#
# The named warehouse association(s) must be active when the record is
# created, when the warehouse changes, or when one of the listed attributes
# changes INTO one of the listed values (a forward workflow step: submit,
# approve, confirm, post). Everything else stays possible on a document whose
# warehouse was deactivated later: reading it, cancelling, rejecting, voiding
# (a void posts compensating "reversal" movements, which InventoryMovement
# still accepts), editing notes. Historical records are never re-validated.
#
# The movement ledger keeps its own last-line guard
# (InventoryMovement#warehouse_active_for_new_stock).
module RequiresActiveWarehouse
  extend ActiveSupport::Concern

  class_methods do
    def requires_active_warehouse(*associations, transitions: {})
      validate do
        stepping = transitions.any? do |attribute, values|
          will_save_change_to_attribute?(attribute) && values.include?(public_send(attribute).to_s)
        end

        associations.each do |name|
          foreign_key = self.class.reflect_on_association(name).foreign_key
          next unless new_record? || will_save_change_to_attribute?(foreign_key) || stepping

          warehouse = public_send(name)
          next if warehouse.nil? || warehouse.active?

          errors.add(:base, :warehouse_inactive, warehouse: warehouse.name)
        end
      end
    end
  end
end
