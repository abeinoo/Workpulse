class Performance::ReviewsController < Performance::BaseController
  # Employees with no module permission may still view their OWN finalized
  # reviews. policy_scope restricts them to exactly that; every write action
  # remains gated by Pundit (manage_reviews / finalize_reviews).
  skip_before_action :require_performance_access!, only: [ :index, :show ]

  before_action :set_review, only: [ :show, :edit, :update, :submit, :finalize, :destroy ]

  def index
    authorize PerformanceReview
    @reviews = policy_scope(PerformanceReview)
                 .includes(:employee, :department, :reviewer)
                 .recent_first
    @reviews = @reviews.where(status: params[:status]) if params[:status].present?
    @reviews = @reviews.where(employee_id: params[:employee_id]) if params[:employee_id].present?
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
    @review.department_id ||= @review.employee&.department_id
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
