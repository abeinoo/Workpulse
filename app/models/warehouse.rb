class Warehouse < ApplicationRecord
  belongs_to :business
  # The owning branch of a branch warehouse (kind "branch"); nil for a central
  # or not-yet-classified warehouse. Deliberately no inverse association on
  # Branch (Organization & Access) — Inventory looks the warehouse up itself.
  belongs_to :branch, optional: true

  has_many :goods_receipts,      dependent: :restrict_with_error
  has_many :stock_issues,        dependent: :restrict_with_error
  has_many :inventory_movements, dependent: :restrict_with_error
  has_many :warehouse_assignments, dependent: :destroy
  has_many :assigned_users, through: :warehouse_assignments, source: :user
  # Branches this warehouse supplies (reporting relationship only — stock stays here).
  has_many :branch_supplies, class_name: "WarehouseBranchSupply", dependent: :restrict_with_error

  STATUSES = %w[active inactive].freeze
  enum :status, { active: "active", inactive: "inactive" }

  # central — owned by no branch; may supply any branch (including Laundry).
  # branch  — the one warehouse of exactly one sales branch.
  # nil     — not yet classified (every warehouse that predates the warehouse
  #           architecture). Classification is an explicit, audited decision
  #           made later, never inferred. The database enforces the same
  #           shape (warehouses_kind_known / warehouses_branch_only_for_branch_kind
  #           / index_warehouses_one_per_branch).
  KINDS = %w[central branch].freeze
  enum :kind, KINDS.index_with(&:itself), prefix: true, validate: { allow_nil: true }

  validates :name, presence: true, length: { maximum: 120 }
  validates :name, uniqueness: { scope: :business_id, case_sensitive: false }
  validates :branch, presence: { message: :required }, if: :kind_branch?
  validate  :branch_only_for_branch_kind
  validates :branch_id, uniqueness: { message: :already_has_warehouse }, allow_nil: true
  validate  :branch_in_same_business, if: :will_save_change_to_branch_id?
  # Only sales branches get a branch warehouse. Checked when the link is set,
  # so a warehouse whose branch later changes type stays valid (it is never
  # deleted or detached automatically).
  validate  :branch_is_sales, if: :will_save_change_to_branch_id?
  # Structural identity: a warehouse never moves to another business, and once
  # classified its kind and owning branch are fixed — a branch warehouse is
  # never re-parented or turned central, a central one never becomes a branch
  # warehouse through an ordinary update. Classifying a not-yet-classified
  # warehouse (kind nil -> central/branch) is left open for the explicit,
  # audited classification step.
  validate  :structural_identity_unchanged, on: :update

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:name) }

  private

  def branch_only_for_branch_kind
    errors.add(:branch, :only_for_branch_warehouse) if branch_id.present? && !kind_branch?
  end

  # The branch id can come from outside (console, services, later forms) —
  # never link a warehouse to another business's branch (IP-1).
  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :other_business) if branch.business_id != business_id
  end

  def branch_is_sales
    return if branch.nil?

    errors.add(:branch, :not_sales_branch) unless branch.branch_type_sales?
  end

  def structural_identity_unchanged
    errors.add(:business_id, :immutable) if will_save_change_to_business_id?
    return if kind_in_database.nil?

    errors.add(:kind, :immutable)      if will_save_change_to_kind?
    errors.add(:branch_id, :immutable) if will_save_change_to_branch_id?
  end
end
