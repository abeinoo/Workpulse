# Restricts a user to a set of warehouses. A user with NO assignments can see
# every warehouse (owners, accountants, admins); adding assignments narrows them
# to exactly those warehouses for all inventory data.
#
# Audit (Warehouse Architecture PR 5, D7): a row created or destroyed with an
# audit_actor writes a fail-closed AuditLog entry ("create" / "destroy") in the
# same transaction — so an assignment change and its audit commit or roll back
# together, and a refused change (validation, foreign key) leaves no entry.
# Inventory::UserWarehouseAssignments — the only application write path —
# always sets the actor.
class WarehouseAssignment < ApplicationRecord
  include AuditLoggable

  belongs_to :user
  belongs_to :warehouse

  # The user making the change; not persisted.
  attr_accessor :audit_actor

  validates :warehouse_id, uniqueness: { scope: :user_id }
  validate  :same_business

  after_create  :audit_creation, if: :audit_actor
  after_destroy :audit_removal,  if: :audit_actor

  private

  def same_business
    return if user.nil? || warehouse.nil?
    errors.add(:warehouse_id, :different_business) if warehouse.business_id != user.business_id
  end

  def audit_creation = log_audit!(actor: audit_actor, auditable: self, action: "create", metadata: audit_metadata)
  def audit_removal  = log_audit!(actor: audit_actor, auditable: self, action: "destroy", metadata: audit_metadata)

  # Ids only — no names or personal data.
  def audit_metadata
    { user_id: user_id, warehouse_id: warehouse_id, business_id: warehouse&.business_id }
  end
end
