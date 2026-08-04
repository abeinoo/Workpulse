class Performance::ReviewsController < Performance::BaseController
  # Employees with no module permission may still view their OWN finalized
  # reviews. policy_scope restricts them to exactly that; every write action
  # remains gated by Pundit (manage_reviews / finalize_reviews). The analytics/
  # export actions are read-only views over the same policy_scope, so they
  # share the same access as index.
  ANALYTICS_ACTIONS = %i[index employee_summary export_xlsx export_pdf
                          employee_summary_export_xlsx employee_summary_export_pdf].freeze
  skip_before_action :require_performance_access!, only: ANALYTICS_ACTIONS + [ :show ]

  before_action :set_review, only: [ :show, :edit, :update, :submit, :finalize, :destroy ]
  before_action :build_analytics, only: ANALYTICS_ACTIONS

  def index
    @reviews = @analytics.relation.includes(:employee, :department, :reviewer).recent_first
  end

  def employee_summary
    @sort      = params[:sort].presence_in(Performance::ReviewAnalytics::EMPLOYEE_SUMMARY_SORT_COLUMNS.keys) || "average_rating"
    @direction = params[:direction].to_s.casecmp("asc").zero? ? "asc" : "desc"
    @page      = [ params[:page].to_i, 1 ].max
    @per_page  = 25
    @rows      = @analytics.employee_summary_rows(sort: @sort, direction: @direction, page: @page, per_page: @per_page)
    @overview  = @analytics.employee_summary_overview
    @total_count = @analytics.employee_summary_total_count
  end

  def export_xlsx
    stream = Performance::Exports::ReviewsWorkbook.new(@analytics).call
    send_data stream.read, filename: "review_analytics_#{Date.current.iso8601}.xlsx",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def export_pdf
    html = render_to_string(template: "performance/reviews/export_pdf", layout: "pdf")
    send_data Performance::Exports::PdfRenderer.render(html),
              filename: "review_analytics_#{Date.current.iso8601}.pdf", type: "application/pdf"
  end

  def employee_summary_export_xlsx
    sort      = params[:sort].presence_in(Performance::ReviewAnalytics::EMPLOYEE_SUMMARY_SORT_COLUMNS.keys) || "average_rating"
    direction = params[:direction].to_s.casecmp("asc").zero? ? "asc" : "desc"
    stream = Performance::Exports::EmployeeSummaryWorkbook.new(@analytics, sort: sort, direction: direction).call
    send_data stream.read, filename: "employee_summary_#{Date.current.iso8601}.xlsx",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def employee_summary_export_pdf
    @sort      = params[:sort].presence_in(Performance::ReviewAnalytics::EMPLOYEE_SUMMARY_SORT_COLUMNS.keys) || "average_rating"
    @direction = params[:direction].to_s.casecmp("asc").zero? ? "asc" : "desc"
    @rows      = @analytics.employee_summary_rows(sort: @sort, direction: @direction, per_page: nil)
    @overview  = @analytics.employee_summary_overview

    html = render_to_string(template: "performance/reviews/employee_summary_export_pdf", layout: "pdf")
    send_data Performance::Exports::PdfRenderer.render(html),
              filename: "employee_summary_#{Date.current.iso8601}.pdf", type: "application/pdf"
  end

  def show
    authorize @review
    @composer = composer_for(@review)
  end

  # Two-step: without employee/period params, render the selection form;
  # with them, render the full scoring screen pre-built from the template.
  def new
    @review = current_user.business.performance_reviews.new(
      review_year:  (params[:review_year].presence  || Date.current.year).to_i,
      review_month: (params[:review_month].presence || Date.current.month).to_i,
      employee_id:  params[:employee_id]
    )
    authorize @review

    @employees = selectable_employees

    if @review.employee_id.present?
      @review.department_id = @review.employee&.department_id
      @composer = composer_for(@review)
      build_scores_from(@composer)
    end
  end

  def create
    @review = current_user.business.performance_reviews.new(review_params)
    @review.reviewer = current_user
    authorize @review

    if @review.save
      redirect_to performance_review_path(@review), notice: t("performance.reviews.created")
    else
      @employees = selectable_employees
      @composer  = composer_for(@review)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @review
    @composer = composer_for(@review)
    build_scores_from(@composer)
  end

  def update
    authorize @review
    if @review.update(review_params)
      redirect_to performance_review_path(@review), notice: t("performance.reviews.updated")
    else
      @composer = composer_for(@review)
      render :edit, status: :unprocessable_entity
    end
  end

  def submit
    authorize @review
    @review.update(status: "submitted")
    redirect_to performance_review_path(@review), notice: t("performance.reviews.submitted")
  end

  def finalize
    authorize @review
    @review.finalize!
    redirect_to performance_review_path(@review), notice: t("performance.reviews.finalized")
  end

  def destroy
    authorize @review, :update?
    @review.destroy
    redirect_to performance_reviews_path, notice: t("performance.reviews.destroyed")
  end

  private

  def build_analytics
    # All analytics/export actions share index?'s "scope handles isolation" gate.
    authorize PerformanceReview, :index?
    @filters   = filter_params
    @analytics = Performance::ReviewAnalytics.new(policy_scope(PerformanceReview), @filters)

    @filter_branches    = current_user.business.branches.active.order(:name)
    @filter_departments = current_user.business.departments.active.ordered
    @filter_employees   = selectable_employees
    @filter_reviewers   = User.where(id: policy_scope(PerformanceReview).select(:reviewer_id).distinct)
                               .order(:first_name, :last_name)
  end

  def filter_params
    params.permit(:from_date, :to_date, :branch_id, :department_id, :employee_id, :status, :reviewer_id)
          .to_h.symbolize_keys
  end

  def set_review
    @review = policy_scope(PerformanceReview).find(params[:id])
  end

  def composer_for(review)
    Performance::ReviewComposer.new(
      employee:   review.employee,
      department: review.department,
      year:       review.review_year,
      month:      review.review_month,
      review:     review
    )
  end

  # Pre-builds an unsaved score row for each criterion that doesn't yet have one,
  # so the form renders a star control per criterion.
  def build_scores_from(composer)
    existing = @review.performance_review_scores.index_by(&:evaluation_criterion_id)
    composer.criterion_rows.each do |row|
      next if existing.key?(row.criterion.id)

      @review.performance_review_scores.build(evaluation_criterion_id: row.criterion.id)
    end
  end

  def review_params
    params.require(:performance_review).permit(
      :employee_id, :department_id, :review_year, :review_month, :review_period, :notes,
      performance_review_scores_attributes: [ :id, :evaluation_criterion_id, :score, :_destroy ]
    )
  end
end
