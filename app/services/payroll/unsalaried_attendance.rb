module Payroll
  # Read-only: the employees with attendance in a payroll period on days when
  # no salary profile is in force (Salary::ProfileTimeline — a profile never
  # applies before its effective_from). Those days earn nothing; an employee
  # with no profile in force on any day of the period gets no payroll entry at
  # all (Payroll::EntryCalculator). Shown on the period page so a missing
  # salary profile is found before the period is finalized.
  #
  # users: the employees the viewer may see (PayrollEntryPolicy.visible_employees).
  class UnsalariedAttendance
    Row = Struct.new(:user, :unpaid_days, :first_date, :last_date, :in_payroll, keyword_init: true) do
      def in_payroll? = in_payroll
    end

    def initialize(period:, users:)
      @period = period
      @users  = users
    end

    def rows
      dates_by_user = AttendanceRecord.active
                                      .where(user_id: @users.where(business_id: @period.business_id).select(:id),
                                             work_date: @period.period_start..@period.period_end)
                                      .distinct.pluck(:user_id, :work_date)
                                      .group_by(&:first).transform_values { |pairs| pairs.map(&:second) }
      return [] if dates_by_user.empty?

      in_payroll = @period.payroll_entries.where(user_id: dates_by_user.keys).pluck(:user_id).to_set
      User.where(id: dates_by_user.keys).includes(:salary_profiles).filter_map do |user|
        timeline = Salary::ProfileTimeline.for(user)
        unpaid   = dates_by_user[user.id].reject { |date| timeline.profile_on(date) }.sort
        next if unpaid.empty?

        Row.new(user: user, unpaid_days: unpaid.size, first_date: unpaid.first, last_date: unpaid.last,
                in_payroll: in_payroll.include?(user.id))
      end.sort_by { |row| [ row.in_payroll? ? 1 : 0, row.user.full_name.to_s ] }
    end
  end
end
