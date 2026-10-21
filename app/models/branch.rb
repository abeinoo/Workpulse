class Branch < ApplicationRecord
  # "sales" branches are salon locations that appear in POS/sales-facing branch
  # pickers. Other types are internal operational units (laundry, a warehouse,
  # HQ, maintenance, or an uncategorized "other") that reuse Branch purely to
  # participate in shift assignments, attendance, payroll, and expenses — see
  # CLAUDE.md's laundry architecture notes for why this is additive rather
  # than a separate OperationalUnit model.
  #
  # branch_type describes operational PURPOSE, not a specific module — it is
  # reused across inventory, laundry, and reporting. Every module that needs
  # to restrict itself to certain kinds of locations (e.g. the towel-transfer
  # selectors only offering sales/laundry branches — see
  # Laundry::TowelTransfersController) must branch on this field, never infer
  # anything from Branch#name.
  #
  # "warehouse_ops" was renamed to "warehouse" (see
  # db/migrate/*_rename_warehouse_ops_branch_type_to_warehouse.rb) — verified
  # zero rows and zero code references used the old value before renaming.
  enum :branch_type, { sales: "sales", laundry: "laundry", warehouse: "warehouse",
                        headquarters: "headquarters", maintenance: "maintenance", other: "other" },
       default: "sales", prefix: true

  belongs_to :business
  belongs_to :branch_manager, class_name: "User", optional: true
  belongs_to :area_manager,   class_name: "User", optional: true
  has_many :shift_assignments,   dependent: :nullify
  has_many :attendance_records,  dependent: :destroy
  has_many :payroll_periods,     dependent: :destroy
  # Primary supplying warehouse (reporting relationship only — the branch owns no stock).
  has_one :warehouse_supply, class_name: "WarehouseBranchSupply", dependent: :destroy

  # Financial Operations & Expense Management — financial history is restricted
  # on delete (block, never silently orphan) to preserve the audit trail.
  has_many :expenses,            dependent: :restrict_with_error
  has_many :expense_allocations, dependent: :restrict_with_error
  has_many :recurring_expenses,  dependent: :restrict_with_error
  has_many :custody_accounts,    dependent: :restrict_with_error
  has_many :branch_revenues,     dependent: :restrict_with_error
  has_many :pos_transactions,    dependent: :restrict_with_error
  # Terminal IDs (Finance & Sales) are edited as a section of the Branch form —
  # there is no standalone Terminal configuration page. The rows are staged
  # through the OrganizationAccess::BranchTerminalSettings contract (Pilot 12);
  # autosave persists them in the branch's own save.
  has_many :pos_terminals,       dependent: :restrict_with_error, autosave: true

  # Laundry Operations — towel ledger rows and transfers reference a branch as
  # a physical location (any branch, not only branch_type: "laundry").
  has_many :towel_ledger_entries,           dependent: :restrict_with_error
  has_many :outgoing_towel_transfers, class_name: "TowelTransfer", foreign_key: :source_branch_id,      dependent: :restrict_with_error, inverse_of: :source_branch
  has_many :incoming_towel_transfers, class_name: "TowelTransfer", foreign_key: :destination_branch_id, dependent: :restrict_with_error, inverse_of: :destination_branch
  has_many :laundry_batches, foreign_key: :laundry_branch_id, dependent: :restrict_with_error, inverse_of: :laundry_branch

  validates :name,        presence: true
  validates :business,    presence: true
  validates :branch_type, presence: true
  validates :latitude, :longitude, :radius_meters,
            presence: true,
            if: :geolocation_enabled?
  validates :latitude,      numericality: { in: -90..90 },    allow_nil: true
  validates :longitude,     numericality: { in: -180..180 },  allow_nil: true
  validates :radius_meters, numericality: { greater_than: 0 }, allow_nil: true
  # Branch and area managers must belong to the branch's business — the form
  # lists only own users, but request params are never trusted (OA-S7).
  validate :managers_in_same_business,
           if: -> { will_save_change_to_branch_manager_id? || will_save_change_to_area_manager_id? }

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business: business) }

  # The only branch types the simplified towel-transfer workflow supports as
  # a source or destination — see Laundry::TowelTransfersController and
  # TowelTransfer.infer_towel_status. Warehouse/headquarters/maintenance/other
  # branches are deliberately excluded from those selectors; they require
  # explicit support before participating in any laundry workflow.
  scope :laundry_transfer_eligible, -> { where(branch_type: %w[sales laundry]) }

  private

  def managers_in_same_business
    { branch_manager: branch_manager, area_manager: area_manager }.each do |attribute, manager|
      errors.add(attribute, :invalid) if manager && manager.business_id != business_id
    end
  end
end
