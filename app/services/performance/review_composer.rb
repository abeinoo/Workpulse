# Builds the data behind the monthly review screen.
#
# For a given employee + period, it resolves the active evaluation template for
# the employee's department, pre-builds a score row per active criterion, and
# groups that month's observations under each criterion with positive/negative/
# neutral counts.
#
# Used by Performance::ReviewsController#new and #show. Pure read/build — never
# persists anything.
module Performance
  class ReviewComposer
    CriterionRow = Struct.new(
      :criterion, :score, :observations,
      :positive_count, :negative_count, :neutral_count,
      keyword_init: true
    )

    attr_reader :employee, :department, :year, :month, :template

    def initialize(employee:, year:, month:, department: nil, review: nil)
      @employee   = employee
      @department = department || employee.department
      @year       = year.to_i
      @month      = month.to_i
      @review     = review
      @template   = active_template
    end

    # One row per active criterion (plus any historical criterion already scored
    # on a persisted review, so finalized reviews still render fully even after a
    # criterion is deactivated).
    def criterion_rows
      observations_by_criterion = month_observations.group_by(&:evaluation_criterion_id)
      scores_by_criterion       = persisted_scores.index_by(&:evaluation_criterion_id)

      criteria_for_display.map do |criterion|
        obs = observations_by_criterion[criterion.id] || []
        CriterionRow.new(
          criterion:      criterion,
          score:          scores_by_criterion[criterion.id]&.score,
          observations:   obs.sort_by { |o| [ o.observation_date, o.created_at ] }.reverse,
          positive_count: obs.count(&:type_positive?),
          negative_count: obs.count(&:type_negative?),
          neutral_count:  obs.count(&:type_neutral?)
        )
      end
    end

    def template?
      template.present?
    end

    private

    def active_template
      return nil unless department

      department.evaluation_templates.active.ordered.first
    end

    # Active template criteria, unioned with any criteria already scored on a
    # persisted review (covers later-deactivated criteria on historical reviews).
    def criteria_for_display
      active = template ? template.active_criteria.to_a : []
      return active unless @review&.persisted?

      historical_ids = persisted_scores.map(&:evaluation_criterion_id)
      missing = historical_ids - active.map(&:id)
      active + EvaluationCriterion.where(id: missing).ordered.to_a
    end

    def persisted_scores
      @persisted_scores ||= @review&.persisted? ? @review.performance_review_scores.to_a : []
    end

    def month_observations
      @month_observations ||= PerformanceObservation
        .for_employee(employee)
        .for_month(year, month)
        .includes(:observed_by, :evaluation_criterion)
        .to_a
    end
  end
end
