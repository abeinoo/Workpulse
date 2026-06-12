# Read-only analytics for the performance dashboard / reports.
#
# Every query is scoped to a single business (passed in) and leans on the
# composite indexes added in the reviews/observations migration:
#   - performance_reviews [business_id, status], [business_id, review_year, ...]
#   - performance_observations [business_id, observation_type, criterion]
#
# Rankings are based on FINALIZED reviews only, so drafts in progress never move
# the numbers. An optional year narrows every report to one calendar year.
module Performance
  class Analytics
    Ranked      = Struct.new(:id, :name, :average, :reviews_count, keyword_init: true)
    TrendPoint  = Struct.new(:year, :month, :average, keyword_init: true)
    WeakArea    = Struct.new(:criterion_id, :criterion_name, :department_name, :negative_count, keyword_init: true)

    def initialize(business, year: nil)
      @business = business
      @year     = year.presence&.to_i
    end

    # [{ id, name, average, reviews_count }] sorted best → worst.
    def employee_rankings
      rows = finalized_reviews
        .group(:employee_id)
        .pluck(:employee_id, Arel.sql("AVG(average_score)"), Arel.sql("COUNT(*)"))

      names = User.where(id: rows.map(&:first)).pluck(:id, :first_name, :last_name).to_h do |id, f, l|
        [ id, "#{f} #{l}".strip ]
      end

      rows.map { |id, avg, count|
        Ranked.new(id: id, name: names[id], average: avg&.to_f&.round(2), reviews_count: count)
      }.sort_by { |r| -(r.average || 0) }
    end

    def top_employees(limit = 10)
      employee_rankings.first(limit)
    end

    def lowest_employees(limit = 10)
      employee_rankings.reverse.first(limit)
    end

    # Department average across finalized reviews, best → worst.
    def department_rankings
      rows = finalized_reviews
        .group(:department_id)
        .pluck(:department_id, Arel.sql("AVG(average_score)"), Arel.sql("COUNT(*)"))

      names = Department.where(id: rows.map(&:first)).pluck(:id, :name).to_h

      rows.map { |id, avg, count|
        Ranked.new(id: id, name: names[id], average: avg&.to_f&.round(2), reviews_count: count)
      }.sort_by { |r| -(r.average || 0) }
    end

    # Month-by-month average score. With an employee, it's that person's history;
    # without, it's the whole business. Ordered chronologically.
    def monthly_trend(employee: nil)
      relation = finalized_reviews
      relation = relation.where(employee_id: employee.id) if employee

      relation
        .group(:review_year, :review_month)
        .order(:review_year, :review_month)
        .pluck(:review_year, :review_month, Arel.sql("AVG(average_score)"))
        .map { |y, m, avg| TrendPoint.new(year: y, month: m, average: avg&.to_f&.round(2)) }
    end

    # Criteria with the most NEGATIVE observations — the "weak areas" report.
    def weak_areas(limit = 10)
      rows = negative_observations
        .group(:evaluation_criterion_id)
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(limit)
        .pluck(:evaluation_criterion_id, Arel.sql("COUNT(*)"))

      criteria = EvaluationCriterion
        .where(id: rows.map(&:first))
        .includes(:evaluation_template)
        .index_by(&:id)

      rows.map { |cid, count|
        criterion = criteria[cid]
        WeakArea.new(
          criterion_id:    cid,
          criterion_name:  criterion&.name,
          department_name: criterion&.evaluation_template&.department&.name,
          negative_count:  count
        )
      }
    end

    private

    def finalized_reviews
      scope = @business.performance_reviews.finalized_reviews.where.not(average_score: nil)
      @year ? scope.where(review_year: @year) : scope
    end

    def negative_observations
      scope = @business.performance_observations.where(observation_type: "negative")
      return scope unless @year

      scope.where(observation_date: Date.new(@year, 1, 1)..Date.new(@year, 12, 31))
    end
  end
end
