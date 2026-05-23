class AttendanceImportLog < ApplicationRecord
  belongs_to :business
  belongs_to :imported_by, class_name: "User"

  enum :status, { pending: "pending", completed: "completed", failed: "failed" }

  scope :for_business, ->(business) { where(business: business) }

  def preview_rows
    metadata["preview"] || []
  end

  def valid_preview_rows
    preview_rows.select { |r| r["valid"] }
  end

  def invalid_preview_rows
    preview_rows.reject { |r| r["valid"] }
  end

  def failed_import_rows
    metadata["failed"] || []
  end

  def any_failed?
    failed_rows_count > 0 || failed_import_rows.any?
  end
end
