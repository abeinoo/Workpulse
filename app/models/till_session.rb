class TillSession < ApplicationRecord
  include AuditLoggable

  # TillSession is a pure operational child of DailyReconciliation.
  # It stores custody state: who holds the till, who deposited, who closed it.
  # All accounting lifecycle state (dates, business_date, state) lives on DR.
  belongs_to :daily_reconciliation, inverse_of: :till_session

  belongs_to :current_holder, class_name: "User", optional: true
  belongs_to :depositor,      class_name: "User", optional: true
  belongs_to :closed_by, class_name: "User", optional: true
end
