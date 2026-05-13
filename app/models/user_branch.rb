class UserBranch < ApplicationRecord
  belongs_to :user
  belongs_to :branch

  validates :user_id, uniqueness: { scope: :branch_id }

  scope :active, -> { where(active: true) }

  delegate :business, to: :branch
end
