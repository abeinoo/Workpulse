module Finance
  # Resolves the executive dashboard's unified filter bar (date range, branch,
  # cashier, payment source, payment method) once per request. Each dashboard
  # section applies only the filters meaningful to its own model — a filter
  # that doesn't apply to a given entity (e.g. payment_source on custody
  # balances) is simply not used by that section, not force-fit.
  Result = Struct.new(:from, :to, :branch_ids, :cashier_id, :payment_source,
                       :payment_method_id, keyword_init: true)

  class DashboardFilters
    def initialize(user, params)
      @user   = user
      @params = params
    end

    def resolve
      Result.new(
        from:               from,
        to:                 to,
        branch_ids:         branch_ids,
        cashier_id:         cashier_id,
        payment_source:     payment_source,
        payment_method_id:  payment_method_id
      )
    end

    private

    def from
      parse_date(@params[:from]) || Date.current.beginning_of_month
    end

    def to
      parse_date(@params[:to]) || Date.current.end_of_month
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue ArgumentError
      nil
    end

    # Blank/absent → every branch the user can see (BranchScope default).
    # A single explicit branch_id narrows to just that branch, provided the
    # user actually has access to it.
    def branch_ids
      # BranchScope#default_ids already returns business.branches.pluck(:id)
      # for an owner — skip it instead of running that same query twice.
      allowed = @user.owner? ? @user.business.branches.pluck(:id) : BranchScope.new(@user).default_ids
      requested = @params[:branch_id].presence&.to_i
      return allowed if requested.blank?

      allowed.include?(requested) ? [ requested ] : allowed
    end

    def cashier_id
      requested = @params[:cashier_id].presence&.to_i
      return nil if requested.blank?

      EmployeeScope.new(@user).relation.exists?(requested) || requested == @user.id ? requested : nil
    end

    def payment_source
      value = @params[:payment_source].presence
      Expense::PAYMENT_SOURCES.include?(value) ? value : nil
    end

    def payment_method_id
      requested = @params[:payment_method_id].presence&.to_i
      return nil if requested.blank?

      PaymentMethod.where(business: @user.business).exists?(requested) ? requested : nil
    end
  end
end
