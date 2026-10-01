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
    @permission_role = current_user.business.permission_roles.new(permission_role_params)
    authorize @permission_role

    if grants_ungrantable_permissions?(@permission_role, previous_permissions: [])
      render :new, status: :unprocessable_entity
    elsif @permission_role.save
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

    previous_permissions = @permission_role.permissions.dup
    @permission_role.assign_attributes(permission_role_params)

    if grants_ungrantable_permissions?(@permission_role, previous_permissions: previous_permissions)
      render :edit, status: :unprocessable_entity
    elsif @permission_role.save
      redirect_to admin_permission_role_path(@permission_role),
                  notice: t("flash.permission_role_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @permission_role

    if @permission_role.users.any?
      redirect_to admin_permission_roles_path,
                  alert: t("flash.permission_role_has_users")
    else
      @permission_role.destroy
      redirect_to admin_permission_roles_path,
                  notice: t("flash.permission_role_deleted")
    end
  end

  def assign_user
    authorize @permission_role, :update?

    user = current_user.business.users.find(params[:user_id])

    unless PermissionGrants.can_change_role?(actor: current_user, target: user,
                                             from: user.permission_role, to: @permission_role)
      return redirect_to admin_permission_role_path(@permission_role),
                         alert: t("flash.not_authorized")
    end

    user.update!(permission_role: @permission_role)

    redirect_to admin_permission_role_path(@permission_role),
                notice: t("flash.permission_role_user_assigned", name: user.full_name)
  end

  def remove_user
    authorize @permission_role, :update?

    user = current_user.business.users.find(params[:user_id])

    unless PermissionGrants.can_change_role?(actor: current_user, target: user,
                                             from: user.permission_role, to: nil)
      return redirect_to admin_permission_role_path(@permission_role),
                         alert: t("flash.not_authorized")
    end

    user.update!(permission_role: nil)

    redirect_to admin_permission_role_path(@permission_role),
                notice: t("flash.permission_role_user_removed", name: user.full_name)
  end

  private

  def set_permission_role
    @permission_role = current_user.business.permission_roles.find(params[:id])
  end

  def permission_role_params
    params.require(:permission_role)
          .permit(:name, :description, :role_type, :workspace, permissions: [], permission_scopes: {})
  end

  # A non-owner may only add permissions they hold themselves (PermissionGrants).
  # Checked after validation so role_type defaults and normalization are
  # included; permissions the role already had are not re-checked.
  # Also refuses permissions granted at a scope broader than the actor's own
  # scope for them (PermissionGrants.overbroad_scopes).
  def grants_ungrantable_permissions?(role, previous_permissions:)
    role.validate
    denied    = PermissionGrants.ungrantable(current_user, role.permissions - previous_permissions)
    overbroad = PermissionGrants.overbroad_scopes(current_user, role)
    return false if denied.empty? && overbroad.empty?

    if denied.any?
      role.errors.add(:permissions, t("admin.permission_roles.errors.cannot_grant", permissions: denied.join(", ")))
    end
    if overbroad.any?
      role.errors.add(:permission_scopes, t("admin.permission_roles.errors.scope_too_broad", permissions: overbroad.join(", ")))
    end
    true
  end

  def require_roles_management_access!
    unless current_user.can?(:manage_roles)
      redirect_to root_path, alert: t("flash.not_authorized")
    end
  end
end
