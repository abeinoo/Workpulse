class Admin::JobTitlesController < Admin::BaseController
  before_action :set_job_title, only: [ :edit, :update ]

  def index
    authorize JobTitle
    @job_titles      = policy_scope(JobTitle).ordered
    @employee_counts = current_user.business.users.where.not(job_title: [ nil, "" ])
                                   .group(Arel.sql("lower(job_title)")).count
  end

  def new
    @job_title = current_user.business.job_titles.new(active: true)
    authorize @job_title
  end

  def create
    @job_title = current_user.business.job_titles.new(job_title_params)
    authorize @job_title
    if @job_title.save
      redirect_to admin_job_titles_path, notice: t("admin.job_titles.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @job_title
  end

  # Renaming changes the list only; employees keep the name they were saved with.
  def update
    authorize @job_title
    if @job_title.update(job_title_params)
      redirect_to admin_job_titles_path, notice: t("admin.job_titles.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_job_title
    @job_title = policy_scope(JobTitle).find(params[:id])
  end

  def job_title_params
    params.require(:job_title).permit(:name, :active)
  end
end
