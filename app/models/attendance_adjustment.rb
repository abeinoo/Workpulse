class AttendanceAdjustment < ApplicationRecord
  self.ignored_columns += [ "updated_at" ]

  belongs_to :attendance_record
  belongs_to :adjusted_by, class_name: "User"

  validates :field_name, :reason, presence: true

  # Immutable audit log — block all mutations after creation
  before_update  { throw :abort }
  before_destroy { throw :abort }
end
