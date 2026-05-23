class AuditLog < ApplicationRecord
  self.ignored_columns += %w[updated_at]

  belongs_to :actor,    class_name: "User"
  belongs_to :business
  belongs_to :auditable, polymorphic: true, optional: true

  validates :action,         presence: true
  validates :auditable_type, presence: true
  validates :auditable_id,   presence: true

  scope :for_business,  ->(b)   { where(business: b) }
  scope :for_auditable, ->(obj) { where(auditable: obj) }
  scope :recent,        ->      { order(created_at: :desc) }

  # Convenience accessor: changes_json as a plain hash with symbolized keys.
  def diff
    (changes_json || {}).transform_keys(&:to_sym)
  end
end
