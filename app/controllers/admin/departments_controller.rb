class Admin::DepartmentsController < Admin::BaseController
  before_action :set_department, only: [ :edit, :update, :destroy ]

  def index
    authorize Department
    @departments = policy_scope(Department).ordered
  end

  def new
    @department = current_user.business.departments.new(active: true)
    authorize @department
  end

  def create
    @department = current_user.business.departments.new(department_params)
    authorize @department
    if @department.save
      redirect_to admin_departments_path, notice: t("admin.departments.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @department
  end

  def update
    authorize @department
    if @department.update(department_params)
      redirect_to admin_departments_path, notice: t("admin.departments.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Soft-delete is the norm (toggle active in the form). Hard destroy is allowed
  # only when nothing depends on the department — restrict_with_error otherwise.
  def destroy
    authorize @department
    if @department.destroy
      redirect_to admin_departments_path, notice: t("admin.departments.destroyed")
    else
      redirect_to admin_departments_path, alert: @department.errors.full_messages.to_sentence
    end
  end

  private

  def set_department
    @department = policy_scope(Department).find(params[:id])
  end

  def department_params
    params.require(:department).permit(:name, :active)
  end
end
