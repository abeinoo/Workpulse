class ShiftTemplate < ApplicationRecord
  WEEKDAY_NAMES = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

  belongs_to :business
  belongs_to :created_by, class_name: "User"
  has_many :entries,               class_name: "ShiftTemplateEntry", dependent: :destroy
  has_many :generated_assignments, class_name: "ShiftAssignment",
           foreign_key: :source_template_id, dependent: :nullify

  accepts_nested_attributes_for :entries, allow_destroy: true, reject_if: :all_blank

  validates :name, presence: true,
                   uniqueness: { scope: :business_id, case_sensitive: false }
  validates :business_id, :created_by_id, presence: true

  scope :active,       -> { where(archived_at: nil) }
  scope :archived,     -> { where.not(archived_at: nil) }
  scope :for_business, ->(business) { where(business_id: business.id) }

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  def coverage_summary
    entries.includes(:shift, :branch).group_by(&:weekday).transform_values do |day_entries|
      day_entries.map { |e| { shift: e.shift.name, branch: e.branch&.name } }
    end
  end
end
