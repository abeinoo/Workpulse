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

  # Warehouse names are unique per business only through the validation above
  # (the database index is not unique). Two writers checking the same name at
  # once would both pass it, so every save that sets a name first takes a
  # transaction-scoped advisory lock on (business, lower(name)): save runs its
  # validations inside its own transaction, so the lock is held until COMMIT
  # and a competing writer of the same name waits, then validates against the
  # committed row. Taken only inside a transaction (a bare valid? call has no
  # transaction to hold it). Lock order: any business/branch row locks of the
  # caller come first; nothing takes a business or branch lock after this one.
  NAME_LOCK_NAMESPACE = "warehouses.name".freeze
  # The one definition of the lock key: a bind-placeholder template (namespace,
  # business id, name) that PostgreSQL turns into two int4 keys. Both statements
  # below embed this constant template and are parameterized as a whole with
  # sanitize_sql_array, so no value is ever interpolated into SQL text.
  NAME_LOCK_KEY_TEMPLATE = "hashtext(?), hashtext(? || ':' || LOWER(?))".freeze
  NAME_LOCK_KEY_QUERY    = "SELECT #{NAME_LOCK_KEY_TEMPLATE}".freeze
  NAME_LOCK_STATEMENT    = "SELECT pg_advisory_xact_lock(#{NAME_LOCK_KEY_TEMPLATE})".freeze
  before_validation :lock_name_for_uniqueness, if: :name_lock_needed?

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:name) }

  # The advisory lock key for a (business, name) pair, as SQL: both halves are
  # computed by PostgreSQL, the name through the same LOWER() the
  # case-insensitive uniqueness validation compares with — so two names the
  # database considers equal always map to the same key (a hash collision
  # between different names only adds serialization; it can never let a
  # duplicate through, the validation still decides). The name is not
  # stripped: the validation does not strip either.
  def self.name_lock_key_sql(business_id, name)
    sanitize_sql_array([ NAME_LOCK_KEY_TEMPLATE, *name_lock_key_binds(business_id, name) ])
  end

  # The bind values for NAME_LOCK_KEY_TEMPLATE, in placeholder order.
  def self.name_lock_key_binds(business_id, name)
    [ NAME_LOCK_NAMESPACE, Integer(business_id).to_s, name.to_s ]
  end

  # [namespace_key, name_key] as PostgreSQL computes them (for verification).
  def self.name_lock_key(business_id, name)
    connection.select_rows(sanitize_sql_array([ NAME_LOCK_KEY_QUERY, *name_lock_key_binds(business_id, name) ]))
              .first.map(&:to_i)
  end

  # The exact statement lock_name_for_uniqueness runs (parameterized).
  def self.name_lock_statement(business_id, name)
    sanitize_sql_array([ NAME_LOCK_STATEMENT, *name_lock_key_binds(business_id, name) ])
  end

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

  def name_lock_needed?
    name.present? && business_id.present? && (new_record? || will_save_change_to_name?) &&
      self.class.connection.transaction_open?
  end

  def lock_name_for_uniqueness
    self.class.connection.execute(self.class.name_lock_statement(business_id, name))
  end

  def structural_identity_unchanged
    errors.add(:business_id, :immutable) if will_save_change_to_business_id?
    return if kind_in_database.nil?

    errors.add(:kind, :immutable)      if will_save_change_to_kind?
    errors.add(:branch_id, :immutable) if will_save_change_to_branch_id?
  end
end
