# Append-only history of an EmployeeDataRequest: who did what, when, and why.
# Reviewer notes (rejection reason, requested corrections) live here, never on
# the request itself, so every decision stays in the chronological trail.
class EmployeeDataRequestEvent < ApplicationRecord
  class ImmutableEventError < StandardError; end

  # corrected — a reviewer edited the data before deciding (a new revision).
  ACTIONS        = %w[submitted resubmitted corrected changes_requested rejected approved].freeze
  REVIEW_ACTIONS = %w[changes_requested rejected approved].freeze
  NOTE_REQUIRED  = %w[changes_requested rejected].freeze

  belongs_to :employee_data_request, inverse_of: :events
  belongs_to :actor,    class_name: "User"
  belongs_to :revision, class_name: "EmployeeDataRequestRevision", optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :note, presence: true, if: -> { action.in?(NOTE_REQUIRED) }
  validates :note, length: { maximum: 2000 }

  before_update  { raise ImmutableEventError, "employee data request events are append-only" }
  before_destroy(prepend: true) { raise ImmutableEventError, "employee data request events are append-only" }
end
