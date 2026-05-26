module Payroll
  # Captures a lightweight JSON snapshot of a payroll period's current totals
  # and per-employee net amounts. Called before regeneration so diffs can be
  # shown afterwards and rollback is possible at the data level.
  class SnapshotService
    Result = Struct.new(:success, :snapshot, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, taken_by:, trigger: "pre_regenerate")
      new(period: period, taken_by: taken_by, trigger: trigger).call
    end

    def initialize(period:, taken_by:, trigger:)
      @period   = period
      @taken_by = taken_by
      @trigger  = trigger
    end

    def call
      entries = @period.payroll_entries.to_a

      employee_details = entries.map do |e|
        {
          "user_id"    => e.user_id,
          "net"        => e.net_salary.to_f,
          "base"       => e.base_salary.to_f,
          "overtime"   => e.total_overtime.to_f,
          "deductions" => e.total_deductions.to_f,
          "bonuses"    => e.total_bonuses.to_f,
        }
      end

      snapshot = PayrollSnapshot.create!(
        payroll_period:  @period,
        taken_by:        @taken_by,
        trigger:         @trigger,
        employee_count:  entries.size,
        total_net:       entries.sum { |e| e.net_salary.to_f },
        total_base:      entries.sum { |e| e.base_salary.to_f },
        total_overtime:  entries.sum { |e| e.total_overtime.to_f },
        total_deductions: entries.sum { |e| e.total_deductions.to_f },
        total_bonuses:   entries.sum { |e| e.total_bonuses.to_f },
        employee_details: employee_details
      )

      Result.new(success: true, snapshot: snapshot)
    rescue StandardError => e
      Result.new(success: false, error: e.message)
    end
  end
end
