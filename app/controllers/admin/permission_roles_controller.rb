class Admin::PermissionRolesController < Admin::BaseController
  # Allow users with manage_roles permission in addition to super_admin.
  skip_before_action :require_admin_access!
  before_action :require_roles_management_access!
  before_action :set_permission_role, only: [ :show, :edit, :update, :destroy, :assign_user, :remove_user ]

  def index
    @permission_roles = policy_scope(PermissionRole)
                          .includes(:users)
                          .ordered
  end

  def show
    authorize @permission_role
    @users = @permission_role.users.includes(profile_photo_attachment: :blob).order(:first_name, :last_name)
    @available_users = current_user.business.users
                                   .where(permission_role_id: [ nil, @permission_role.id ])
                                   .where.not(id: current_user.business.owner_id)
                                   .order(:first_name, :last_name)
  end

  def new
    @permission_role = current_user.business.permission_roles.new
    authorize @permission_role
  end

  def create
    authorize PermissionRole

    result = OrganizationAccess::CreateRole.new(actor: current_user, attributes: permission_role_params).call
    raise Pundit::NotAuthorizedError if result.error == :not_authorized

    @permission_role = result.record

    if result.ok?
      redirect_to admin_permission_role_path(@permission_role),
                  notice: t("flash.permission_role_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @permission_role
  end

  def update
    authorize @permission_role

    result = OrganizationAccess::UpdateRole.new(@permission_role.id, actor: current_user,
                                                attributes: permission_role_params).call
    raise Pundit::NotAuthorizedError if result.error == :not_authorized

    @permission_role = result.record

    if result.ok?
      redirect_to admin_permission_role_path(@permission_role),
                  notice: t("flash.permission_role_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @permission_role

    result = OrganizationAccess::DeleteRole.new(@permission_role.id, actor: current_user).call
    raise Pundit::NotAuthorizedError if result.error == :not_authorized

    if result.ok?
      redirect_to admin_permission_roles_path,
                  notice: t("flash.permission_role_deleted")
    else
      redirect_to admin_permission_roles_path,
                  alert: t("flash.permission_role_has_users")
    end
  end

  def assign_user
    authorize @permission_role, :update?

    result = OrganizationAccess::ChangeUserRole.new(params[:user_id], actor: current_user,
                                                    role_id: @permission_role.id).call
    return redirect_to admin_permission_role_path(@permission_role), alert: t("flash.not_authorized") unless result.ok?

    redirect_to admin_permission_role_path(@permission_role),
                notice: t("flash.permission_role_user_assigned", name: result.record.full_name)
  end

  def remove_user
    authorize @permission_role, :update?

    result = OrganizationAccess::ChangeUserRole.new(params[:user_id], actor: current_user, role_id: nil).call
    return redirect_to admin_permission_role_path(@permission_role), alert: t("flash.not_authorized") unless result.ok?

    redirect_to admin_permission_role_path(@permission_role),
                notice: t("flash.permission_role_user_removed", name: result.record.full_name)
  end

  private

  def set_permission_role
    @permission_role = current_user.business.permission_roles.find(params[:id])
  end

  def permission_role_params
    params.require(:permission_role)
          .permit(:name, :description, :role_type, :workspace, permissions: [], permission_scopes: {})
  end

  def require_roles_management_access!
    unless current_user.can?(:manage_roles)
      redirect_to root_path, alert: t("flash.not_authorized")
    end
  end
end
