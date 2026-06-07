# Restricts a user to a set of warehouses. A user with NO assignments can see
# every warehouse (owners, accountants, admins); adding assignments narrows them
# to exactly those warehouses for all inventory data.
class WarehouseAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :warehouse

  validates :warehouse_id, uniqueness: { scope: :user_id }
  validate  :same_business

  private

  def same_business
    return if user.nil? || warehouse.nil?
    errors.add(:warehouse_id, :different_business) if warehouse.business_id != user.business_id
  end
end
