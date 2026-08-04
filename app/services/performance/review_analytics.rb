# Read-only, filter-driven aggregate stats over PerformanceReview.
#
# Every number here is computed in SQL (AVG/COUNT/GROUP BY/window aggregates)
# against the database — never by loading reviews into memory and reducing in
# Ruby — so it stays cheap regardless of how many reviews match the filters.
#
# Takes a base relation (the caller's already-permission-scoped
# `policy_scope(PerformanceReview)`) plus a filters hash, and layers the
# filters on top in SQL. `#relation` exposes the fully-filtered relation so a
# paginated table can be built from the exact same scope the stats are
# computed from — the two can never drift apart.
#
# This is the single entry point for review-level analytics; any screen that
# needs review stats (the Monthly Reviews filter/analytics panel, the
# Employee Summary tab, the Excel/PDF exporters) instantiates this rather
# than re-deriving the numbers. Branch/department analytics prefer the
# per-review snapshot columns (`branch_id`/`department_id`, captured once at
# review creation — see PerformanceReview#snapshot_branch_and_department) so
# a later employee transfer never rewrites historical analytics; reviews
# created before the snapshot existed have a nil branch_id and are handled
# nil-safely wherever they're grouped.
module Performance
  class ReviewAnalytics
    MIN_REVIEWS_FOR_RANKING = 3
    TREND_DELTA_THRESHOLD   = 0.3
    LOW_RATING_THRESHOLD    = 3.5
    HIGH_RATING_THRESHOLD   = 4.5

    EmployeeSummary       = Struct.new(:average, :reviews_count, :highest, :lowest, keyword_init: true)
    TrendPoint            = Struct.new(:label, :average, :count, keyword_init: true)
    DepartmentSummary     = Struct.new(:department_id, :department_name, :review_count, :average_rating, keyword_init: true)
    BranchSummary         = Struct.new(:branch_id, :branch_name, :review_count, :average_rating, keyword_init: true)
    EmployeeRanking       = Struct.new(:employee_id, :employee_name, :average_rating, :review_count, keyword_init: true)
    PeriodComparison      = Struct.new(:previous_average_rating, :rating_delta,
                                        :previous_review_count, :review_count_delta, keyword_init: true)
    EmployeeSummaryRow    = Struct.new(:employee_id, :employee_name, :branch_name, :department_name,
                                        :reviews_count, :average_rating, :highest_rating, :lowest_rating,
                                        :trend, :last_review_at, keyword_init: true)
    EmployeeSummaryOverview = Struct.new(
      :employees_reviewed, :average_employee_rating,
      :highest_rated_employee_name, :highest_rated_employee_rating,
      :lowest_rated_employee_name, :lowest_rated_employee_rating,
      :employees_below_threshold, :employees_above_threshold,
      keyword_init: true
    )

    EMPLOYEE_SUMMARY_SORT_COLUMNS = {
      "average_rating"   => "avg_score",
      "review_count"     => "reviews_count",
      "employee_name"    => "first_name, last_name",
      "last_review_date" => "last_review_at"
    }.freeze

    def initialize(base_relation, filters = {})
      @base_relation = base_relation
      @filters = (filters || {}).symbolize_keys
    end

    # The base relation with every filter applied — the source of truth for
    # both the stat cards below and the paginated table on the page.
    def relation
      @relation ||= build_relation
    end

    def total_reviews
      @total_reviews ||= relation.count
    end

    # AVG ignores NULL average_score (draft reviews with no scores yet).
    def average_rating
      @average_rating ||= relation.average(:average_score)&.round(2)
    end

    def highest_rating
      @highest_rating ||= relation.maximum(:average_score)
    end

    def lowest_rating
      @lowest_rating ||= relation.minimum(:average_score)
    end

    # { 1 => count, 2 => count, ..., 5 => count } — every key present even
    # when zero, so the view never has to guard against a missing star.
    def star_distribution
      @star_distribution ||= begin
        rows = relation.where.not(average_score: nil)
                        .group(Arel.sql("ROUND(average_score)::int"))
                        .count
        (1..5).index_with { |star| rows[star] || 0 }
      end
    end

    # { 1 => { count:, percentage: }, ... } — percentage of total_reviews
    # (not just scored reviews), per the dashboard spec.
    def star_distribution_with_percentage
      @star_distribution_with_percentage ||= begin
        total = total_reviews
        star_distribution.transform_values do |count|
          { count: count, percentage: total.zero? ? 0 : ((count * 100.0 / total).round) }
        end
      end
    end

    # One row per department present in the filtered set, best → worst.
    # Meaningful in the UI once there's more than one — see #multiple_departments?.
    def department_summaries
      @department_summaries ||= begin
        rows = relation.group(:department_id)
                        .pluck(:department_id, Arel.sql("COUNT(*)"), Arel.sql("AVG(average_score)"))
        names = Department.where(id: rows.map(&:first).compact).pluck(:id, :name).to_h

        rows.map { |id, count, avg|
          DepartmentSummary.new(department_id: id, department_name: names[id],
                                 review_count: count, average_rating: avg&.to_f&.round(2))
        }.sort_by { |r| -(r.average_rating || 0) }
      end
    end

    def multiple_departments?
      department_summaries.size > 1
    end

    # One row per branch snapshot present in the filtered set, best → worst.
    # A nil branch_id (pre-snapshot legacy review) groups as its own
    # "unassigned" row rather than being dropped.
    def branch_summaries
      @branch_summaries ||= begin
        rows = relation.group(:branch_id)
                        .pluck(:branch_id, Arel.sql("COUNT(*)"), Arel.sql("AVG(average_score)"))
        names = Branch.where(id: rows.map(&:first).compact).pluck(:id, :name).to_h

        rows.map { |id, count, avg|
          BranchSummary.new(branch_id: id, branch_name: names[id],
                             review_count: count, average_rating: avg&.to_f&.round(2))
        }.sort_by { |r| -(r.average_rating || 0) }
      end
    end

    def multiple_branches?
      branch_summaries.count { |r| r.branch_id.present? } > 1
    end

    # Employees with >= MIN_REVIEWS_FOR_RANKING scored reviews in the filtered
    # set, so a single lucky/unlucky score can't dominate a ranking.
    def qualifying_employee_rankings
      @qualifying_employee_rankings ||= begin
        rows = relation.where.not(average_score: nil)
                        .group(:employee_id)
                        .having("COUNT(*) >= ?", MIN_REVIEWS_FOR_RANKING)
                        .pluck(:employee_id, Arel.sql("AVG(average_score)"), Arel.sql("COUNT(*)"))
        names = employee_names(rows.map(&:first))

        rows.map { |id, avg, count|
          EmployeeRanking.new(employee_id: id, employee_name: names[id],
                               average_rating: avg&.to_f&.round(2), review_count: count)
        }
      end
    end

    def top_employees(limit = 5)
      qualifying_employee_rankings.sort_by { |r| -(r.average_rating || 0) }.first(limit)
    end

    def bottom_employees(limit = 5)
      qualifying_employee_rankings.sort_by { |r| (r.average_rating || 0) }.first(limit)
    end

    # Compares the current filtered period against an equal-length preceding
    # period, derived automatically from filters[:from_date]/[:to_date]
    # (e.g. "last 30 days" compares against the 30 days before that). Returns
    # nil when the filters don't pin down a date range to mirror.
    def previous_period_comparison
      return @previous_period_comparison if defined?(@previous_period_comparison)

      @previous_period_comparison = build_previous_period_comparison
    end

    # Chronological trend, grouped at a granularity chosen automatically from
    # the selected date range: <= 31 days -> by day, <= 12 months -> by
    # month, otherwise by year. Day-level buckets use the review's created_at
    # (the only day-precision timestamp available); month/year buckets use
    # review_year/review_month — the period the review actually covers.
    def rating_trend
      @rating_trend ||= case trend_granularity
      when :day  then daily_trend
      when :year then yearly_trend
      else            monthly_trend_points
      end
    end

    # Stats for a single employee within the filtered set — meaningful when
    # the caller has narrowed the filters to exactly one employee.
    def employee_summary(employee_id)
      scope = relation.where(employee_id: employee_id)
      EmployeeSummary.new(
        average:       scope.average(:average_score)&.round(2),
        reviews_count: scope.count,
        highest:       scope.maximum(:average_score),
        lowest:        scope.minimum(:average_score)
      )
    end

    # One row per employee in the filtered set, aggregated across every
    # review they have in range. `per_page: nil` returns every matching
    # employee (used by exports, which must ignore on-screen pagination).
    def employee_summary_rows(sort: "average_rating", direction: "desc", page: 1, per_page: 25)
      column = EMPLOYEE_SUMMARY_SORT_COLUMNS.fetch(sort.to_s, EMPLOYEE_SUMMARY_SORT_COLUMNS["average_rating"])
      dir    = direction.to_s.casecmp("asc").zero? ? "ASC" : "DESC"

      scope = per_employee_scope.order(Arel.sql("#{column} #{dir} NULLS LAST"))
      if per_page.present?
        offset = [ page.to_i - 1, 0 ].max * per_page.to_i
        scope  = scope.limit(per_page.to_i).offset(offset)
      end

      hydrate_employee_summary_rows(scope.to_a)
    end

    def employee_summary_total_count
      @employee_summary_total_count ||= relation.distinct.count(:employee_id)
    end

    def employee_summary_overview
      @employee_summary_overview ||= build_employee_summary_overview
    end

    private

    def build_relation
      scope = @base_relation
      scope = apply_date_range(scope)
      scope = scope.where(status: @filters[:status])                 if @filters[:status].present?
      scope = scope.where(employee_id: @filters[:employee_id])       if @filters[:employee_id].present?
      scope = scope.where(reviewer_id: @filters[:reviewer_id])       if @filters[:reviewer_id].present?
      scope = scope.where(department_id: @filters[:department_id])   if @filters[:department_id].present?
      apply_branch_filter(scope)
    end

    # review_year/review_month has no single date column, so the range is
    # compared as a single sortable key (year * 12 + month) rather than two
    # separate integer comparisons.
    def apply_date_range(scope)
      from_key = period_key(@filters[:from_date])
      to_key   = period_key(@filters[:to_date])
      scope = scope.where("(performance_reviews.review_year * 12 + performance_reviews.review_month) >= ?", from_key) if from_key
      scope = scope.where("(performance_reviews.review_year * 12 + performance_reviews.review_month) <= ?", to_key) if to_key
      scope
    end

    def period_key(date_value)
      date = parse_date(date_value)
      return nil unless date

      (date.year * 12) + date.month
    end

    def parse_date(value)
      return nil if value.blank?

      value.is_a?(Date) ? value : Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # Branch filtering prefers the per-review snapshot (branch_id): a review
    # matches either because it was snapshotted in that branch, or — for
    # legacy reviews predating the snapshot (branch_id nil) — because the
    # employee is *currently* a member of that branch, so old data doesn't
    # simply vanish from branch filtering after the migration ships.
    def apply_branch_filter(scope)
      return scope if @filters[:branch_id].blank?

      branch_id = @filters[:branch_id]
      legacy_member_ids = BranchMembership.current_member_ids([ branch_id ])
      scope.where(branch_id: branch_id)
           .or(scope.where(branch_id: nil).where(employee_id: legacy_member_ids))
    end

    def employee_names(ids)
      User.where(id: ids).pluck(:id, :first_name, :last_name).to_h { |id, f, l| [ id, "#{f} #{l}".strip ] }
    end

    def build_previous_period_comparison
      from = parse_date(@filters[:from_date])
      to   = parse_date(@filters[:to_date])
      return nil unless from && to && from <= to

      span      = (to - from).to_i + 1
      prev_to   = from - 1
      prev_from = prev_to - span + 1

      previous_analytics = self.class.new(@base_relation, @filters.merge(from_date: prev_from, to_date: prev_to))
      prev_avg   = previous_analytics.average_rating
      prev_count = previous_analytics.total_reviews

      PeriodComparison.new(
        previous_average_rating: prev_avg,
        rating_delta:            (average_rating && prev_avg) ? (average_rating - prev_avg).round(2) : nil,
        previous_review_count:   prev_count,
        review_count_delta:      total_reviews - prev_count
      )
    end

    def trend_granularity
      from = parse_date(@filters[:from_date])
      to   = parse_date(@filters[:to_date])
      return :month unless from && to && from <= to

      span_days = (to - from).to_i
      return :day   if span_days <= 31
      return :month if span_days <= 366

      :year
    end

    def daily_trend
      relation.where.not(average_score: nil)
              .group(Arel.sql("DATE(created_at)"))
              .order(Arel.sql("DATE(created_at)"))
              .pluck(Arel.sql("DATE(created_at)"), Arel.sql("AVG(average_score)"), Arel.sql("COUNT(*)"))
              .map { |date, avg, count| TrendPoint.new(label: I18n.l(date), average: avg&.to_f&.round(2), count: count) }
    end

    def monthly_trend_points
      relation.where.not(average_score: nil)
              .group(:review_year, :review_month)
              .order(:review_year, :review_month)
              .pluck(:review_year, :review_month, Arel.sql("AVG(average_score)"), Arel.sql("COUNT(*)"))
              .map { |y, m, avg, count|
                TrendPoint.new(label: I18n.l(Date.new(y, m, 1), format: "%B %Y"), average: avg&.to_f&.round(2), count: count)
              }
    end

    def yearly_trend
      relation.where.not(average_score: nil)
              .group(:review_year)
              .order(:review_year)
              .pluck(:review_year, Arel.sql("AVG(average_score)"), Arel.sql("COUNT(*)"))
              .map { |y, avg, count| TrendPoint.new(label: y.to_s, average: avg&.to_f&.round(2), count: count) }
    end

    # One row per employee with reviews_count/avg/highest/lowest/last_review_at,
    # plus the first- and last-scored review's average_score (via ARRAY_AGG,
    # ordered chronologically) so trend classification and the branch/
    # department snapshot to display can be derived without a second query
    # per employee. All computed server-side in a single grouped query.
    def per_employee_scope
      relation
        .joins(:employee)
        .group("performance_reviews.employee_id", "users.first_name", "users.last_name")
        .select(
          "performance_reviews.employee_id AS employee_id",
          "users.first_name AS first_name",
          "users.last_name AS last_name",
          "COUNT(*) AS reviews_count",
          "AVG(performance_reviews.average_score) AS avg_score",
          "MAX(performance_reviews.average_score) AS highest_score",
          "MIN(performance_reviews.average_score) AS lowest_score",
          "MAX(performance_reviews.created_at) AS last_review_at",
          "(ARRAY_AGG(performance_reviews.average_score ORDER BY performance_reviews.review_year, " \
            "performance_reviews.review_month, performance_reviews.created_at) " \
            "FILTER (WHERE performance_reviews.average_score IS NOT NULL))[1] AS first_score",
          "(ARRAY_AGG(performance_reviews.average_score ORDER BY performance_reviews.review_year DESC, " \
            "performance_reviews.review_month DESC, performance_reviews.created_at DESC) " \
            "FILTER (WHERE performance_reviews.average_score IS NOT NULL))[1] AS latest_score",
          "(ARRAY_AGG(performance_reviews.branch_id ORDER BY performance_reviews.review_year DESC, " \
            "performance_reviews.review_month DESC, performance_reviews.created_at DESC))[1] AS last_branch_id",
          "(ARRAY_AGG(performance_reviews.department_id ORDER BY performance_reviews.review_year DESC, " \
            "performance_reviews.review_month DESC, performance_reviews.created_at DESC))[1] AS last_department_id"
        )
    end

    def hydrate_employee_summary_rows(records)
      branch_ids = records.filter_map { |r| r["last_branch_id"] }.uniq
      dept_ids   = records.filter_map { |r| r["last_department_id"] }.uniq
      branch_names = Branch.where(id: branch_ids).pluck(:id, :name).to_h
      dept_names   = Department.where(id: dept_ids).pluck(:id, :name).to_h

      records.map do |r|
        EmployeeSummaryRow.new(
          employee_id:     r["employee_id"],
          employee_name:   "#{r["first_name"]} #{r["last_name"]}".strip,
          branch_name:     branch_names[r["last_branch_id"]],
          department_name: dept_names[r["last_department_id"]],
          reviews_count:   r["reviews_count"],
          average_rating:  r["avg_score"]&.to_f&.round(2),
          highest_rating:  r["highest_score"]&.to_f,
          lowest_rating:   r["lowest_score"]&.to_f,
          trend:           classify_trend(r["first_score"], r["latest_score"]),
          last_review_at:  r["last_review_at"]
        )
      end
    end

    def classify_trend(first_score, latest_score)
      return nil if first_score.nil? || latest_score.nil?

      diff = latest_score.to_f - first_score.to_f
      return "improving" if diff >= TREND_DELTA_THRESHOLD
      return "declining" if diff <= -TREND_DELTA_THRESHOLD

      "stable"
    end

    def per_employee_average_scope
      relation.where.not(average_score: nil)
              .group(:employee_id)
              .select(:employee_id, Arel.sql("AVG(average_score) AS avg_score"))
    end

    def build_employee_summary_overview
      wrapped = PerformanceReview.from(per_employee_average_scope, :employee_averages)

      count, avg, below, above = wrapped.pluck(
        Arel.sql("COUNT(*)"),
        Arel.sql("AVG(avg_score)"),
        Arel.sql("COUNT(*) FILTER (WHERE avg_score < #{LOW_RATING_THRESHOLD})"),
        Arel.sql("COUNT(*) FILTER (WHERE avg_score > #{HIGH_RATING_THRESHOLD})")
      ).first

      highest = wrapped.reorder(Arel.sql("avg_score DESC NULLS LAST")).limit(1)
                        .pluck(:employee_id, Arel.sql("avg_score")).first
      lowest  = wrapped.reorder(Arel.sql("avg_score ASC NULLS LAST")).limit(1)
                        .pluck(:employee_id, Arel.sql("avg_score")).first
      names = employee_names([ highest&.first, lowest&.first ].compact)

      EmployeeSummaryOverview.new(
        employees_reviewed:            count,
        average_employee_rating:       avg&.to_f&.round(2),
        highest_rated_employee_name:   highest && names[highest[0]],
        highest_rated_employee_rating: highest&.last&.to_f&.round(2),
        lowest_rated_employee_name:    lowest && names[lowest[0]],
        lowest_rated_employee_rating:  lowest&.last&.to_f&.round(2),
        employees_below_threshold:     below,
        employees_above_threshold:     above
      )
    end
  end
end
