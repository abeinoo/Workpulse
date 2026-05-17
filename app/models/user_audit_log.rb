class UserAuditLog < ApplicationRecord
  ACTIONS = %w[password_changed_self password_reset_by_admin].freeze

  belongs_to :actor,       class_name: "User"
  belongs_to :target_user, class_name: "User"

  validates :action, inclusion: { in: ACTIONS }
end
