module Finance
  module PosImports
    # Matches parsed CSV rows to existing DailyReconciliation records using
    # branch name (fuzzy, case-insensitive) and transaction date.
    #
    # Usage:
    #   matcher = DrMatcher.new(business)
    #   result  = matcher.match(valid_rows)
    #   result.dr_id_for(row)     # => Integer or nil
    #   result.unmatched_groups   # => [{ branch_name:, date:, count: }, ...]
    #   result.matched_count      # => Integer
    #   result.unmatched_count    # => Integer
    class DrMatcher
      MatchResult = Struct.new(:row_dr_ids, :unmatched_groups, keyword_init: true) do
        def matched_count   = row_dr_ids.values.count(&:itself)
        def unmatched_count = row_dr_ids.values.count(&:nil?)
        def dr_id_for(row)  = row_dr_ids[row.object_id]
        def affected_dr_ids = row_dr_ids.values.compact.uniq
      end

      def initialize(business)
        @business = business
        @branch_lookup   = nil
        @dr_lookup       = nil
      end

      # Returns a MatchResult. Loads branches and DRs lazily.
      def match(valid_rows)
        build_lookups!(valid_rows)

        row_dr_ids       = {}
        unmatched_tally  = Hash.new(0)   # "branch_name|date" => count

        valid_rows.each do |row|
          branch_id = @branch_lookup[normalize(row["branch_name"])]
          dr_id     = branch_id && @dr_lookup[[branch_id, row["transaction_date"]]]

          row_dr_ids[row.object_id] = dr_id

          unless dr_id
            key = "#{row['branch_name']}|#{row['transaction_date']}"
            unmatched_tally[key] += 1
          end
        end

        unmatched_groups = unmatched_tally.map do |key, count|
          branch_name, date = key.split("|", 2)
          { branch_name: branch_name, date: date, count: count }
        end.sort_by { |g| [g[:branch_name], g[:date]] }

        MatchResult.new(row_dr_ids: row_dr_ids, unmatched_groups: unmatched_groups)
      end

      private

      def normalize(str)
        str.to_s.downcase.strip
      end

      def build_lookups!(valid_rows)
        @branch_lookup = @business.branches
                                  .pluck(:id, :name)
                                  .each_with_object({}) { |(id, name), h| h[normalize(name)] = id }

        # Determine the date range from the CSV rows to limit the DR query.
        dates = valid_rows.filter_map { |r| r["transaction_date"] }.uniq

        if dates.any?
          @dr_lookup = DailyReconciliation
                         .where(business: @business, business_date: dates)
                         .pluck(:branch_id, :business_date, :id)
                         .each_with_object({}) do |(branch_id, date, dr_id), h|
                           h[[branch_id, date.to_s]] = dr_id
                         end
        else
          @dr_lookup = {}
        end
      end
    end
  end
end
