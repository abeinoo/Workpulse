module Payroll
  # The per-business payroll-status advisory lock (R3.2; roadmap revision 19,
  # OD-12, §19.14). It closes the gap row locks cannot: a backdated attendance
  # requirement change may cover a month that has no payroll period row yet.
  #
  #   shared    — a backdated requirement change (through
  #               Payroll::RequirementDateProtection), before it locks the
  #               overlapping period rows; changes never wait for each other
  #   exclusive — Payroll::SubmitForReview, before it locks the period row, so
  #               a period cannot become protected while a change that
  #               overlaps it is in flight, and vice versa
  #
  # Transaction-scoped (pg_advisory_xact_lock*): released at commit or rollback.
  # Lock order: employee lock (Workforce) → this lock → period rows. Payroll
  # services never take the Workforce employee lock.
  module StatusLock
    NAMESPACE = 0x5053 # "PS" — distinct from every other advisory lock in app/

    class OutsideTransaction < StandardError; end

    module_function

    def shared!(business_id:)
      acquire("pg_advisory_xact_lock_shared", business_id)
    end

    def exclusive!(business_id:)
      acquire("pg_advisory_xact_lock", business_id)
    end

    def acquire(function, business_id)
      connection = PayrollPeriod.connection
      raise OutsideTransaction, "#{function} needs an open transaction" unless connection.transaction_open?

      connection.execute("SELECT #{function}(#{NAMESPACE}, #{Integer(business_id)})")
    end
    private_class_method :acquire
  end
end
