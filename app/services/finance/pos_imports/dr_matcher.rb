module Finance
  module PosImports
    # Matches parsed CSV rows to existing DailyReconciliation records and
    # validates employee + payment-method existence in four ordered steps:
    #
    #   1. Resolve Branch   — case-insensitive name match
    #   2. Find DR          — branch_id + business_date
    #   3. Validate Employee — cashier_name matches a WorkPulse User (full name)
    #   4. Validate Payment Method — matches an active PaymentMethod for this business
    #
    # Every unmatched row carries an exact failure_reason:
    #
    #   :branch_not_found       — branch_name doesn't match any WorkPulse branch
    #   :no_dr                  — branch found but no DR exists for that branch+date
    #   :employee_not_found     — cashier_name doesn't match any WorkPulse employee
    #   :unknown_payment_method — payment_method_name not in this business's active methods
    #
    # Usage:
    #   matcher = DrMatcher.new(business)
    #   result  = matcher.match(valid_rows)
    #   result.dr_id_for(row)     # => Integer or nil
    #   result.unmatched_groups   # => [{ branch_name:, cashier_name:, payment_method_name:,
    #                             #        date:, count:, reason: }, ...]
    class DrMatcher
      MatchResult = Struct.new(:row_dr_ids, :unmatched_groups, keyword_init: true) do
        def matched_count   = row_dr_ids.values.count(&:itself)
        def unmatched_count = row_dr_ids.values.count(&:nil?)
        def dr_id_for(row)  = row_dr_ids[row.object_id]
        def affected_dr_ids = row_dr_ids.values.compact.uniq
      end

      def initialize(business)
        @business               = business
        @branch_lookup          = nil
        @dr_lookup              = nil
        @user_lookup            = nil
        @payment_method_lookup  = nil
      end

      # Returns a MatchResult. Loads all lookups once before processing rows.
      def match(valid_rows)
        build_lookups!(valid_rows)


        row_dr_ids      = {}
        unmatched_tally = {}   # group_key => { count:, reason:, branch_name:, cashier_name:, payment_method_name:, date: }

        valid_rows.each do |row|
          dr_id, failure_reason = resolve_row(row)
          row_dr_ids[row.object_id] = dr_id

          unless dr_id
            key   = group_key(row, failure_reason)
            entry = unmatched_tally[key] ||= {
              count:               0,
              reason:              failure_reason,
              branch_name:         row["branch_name"].to_s.strip.presence,
              cashier_name:        failure_reason == :employee_not_found     ? row["cashier_name"].to_s.strip.presence        : nil,
              payment_method_name: failure_reason == :unknown_payment_method ? row["payment_method_name"].to_s.strip.presence : nil,
              date:                row["transaction_date"]
            }
            entry[:count] += 1
          end
        end

        unmatched_groups = unmatched_tally.values
                                          .sort_by { |g| [g[:branch_name].to_s, g[:cashier_name].to_s, g[:payment_method_name].to_s, g[:date].to_s] }

        MatchResult.new(row_dr_ids: row_dr_ids, unmatched_groups: unmatched_groups)
      end

      private

      def normalize(str)
        str.to_s.downcase.strip
      end

      # Four-step validation. Returns [dr_id, nil] on success or [nil, reason] on failure.
      def resolve_row(row)
        # Step 1: branch
        branch_id = @branch_lookup[normalize(row["branch_name"])]
        return [nil, :branch_not_found] unless branch_id

        # Step 2: DR
        dr_id = @dr_lookup[[branch_id, row["transaction_date"]]]
        return [nil, :no_dr] unless dr_id

        # Step 3: employee
        return [nil, :employee_not_found] unless @user_lookup[normalize(row["cashier_name"])]

        # Step 4: payment method
        return [nil, :unknown_payment_method] unless @payment_method_lookup[normalize(row["payment_method_name"])]

        [dr_id, nil]
      end

      # Group key for diagnostic table.  Employee failures are grouped by cashier + date;
      # payment-method failures by method + date; everything else by branch + date.
      def group_key(row, failure_reason)
        case failure_reason
        when :employee_not_found
          "employee:#{row['cashier_name'].to_s.strip}|#{row['transaction_date']}"
        when :unknown_payment_method
          "payment:#{row['payment_method_name'].to_s.strip}|#{row['transaction_date']}"
        else
          "branch:#{row['branch_name'].to_s.strip}|#{row['transaction_date']}"
        end
      end

      def build_lookups!(valid_rows)
        @branch_lookup = @business.branches
                                  .pluck(:id, :name)
                                  .each_with_object({}) { |(id, name), h| h[normalize(name)] = id }

        dates = valid_rows.filter_map { |r| r["transaction_date"] }.uniq
        @dr_lookup = if dates.any?
                       DailyReconciliation
                         .where(business: @business, business_date: dates)
                         .pluck(:branch_id, :business_date, :id)
                         .each_with_object({}) { |(branch_id, date, dr_id), h| h[[branch_id, date.to_s]] = dr_id }
                     else
                       {}
                     end

        # User lookup keyed by normalised full_name (first + last).
        @user_lookup = @business.users
                                .pluck(:first_name, :last_name)
                                .each_with_object({}) do |(first, last), h|
                                  h[normalize("#{first} #{last}")] = true
                                end

        # Payment-method lookup keyed by normalised English name.
        @payment_method_lookup = PaymentMethod.for_business(@business)
                                              .active
                                              .pluck(:name)
                                              .each_with_object({}) { |name, h| h[normalize(name)] = true }
      end
    end
  end
end
