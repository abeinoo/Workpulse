class PosImportIgnoredRow < ApplicationRecord
  belongs_to :pos_import
  belongs_to :business
  belongs_to :ignored_by, class_name: "User"

  before_validation :default_business_from_pos_import

  validates :row_number, presence: true, uniqueness: { scope: :pos_import_id }
  validates :reason, presence: true

  scope :ordered, -> { order(:row_number) }

  private

  def default_business_from_pos_import
    self.business_id ||= pos_import&.business_id
  end
end
