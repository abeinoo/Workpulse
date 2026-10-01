module OrganizationAccess
  # Assigns a role to — or removes the role from — an existing user and saves it
  # (the role screen's assign/remove actions). The decision is RoleAssignmentRule;
  # this service only loads the user inside the actor's business and persists.
  #
  # A user of another business raises ActiveRecord::RecordNotFound (404 for the
  # web), and an invalid user raises ActiveRecord::RecordInvalid, exactly as the
  # controller code this replaces did. Role changes are not audited (plan D1).
  class ChangeUserRole
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(user_id, actor:, role_id:)
      @user_id = user_id
      @actor   = actor
      @role_id = role_id
    end

    def call
      user     = @actor.business.users.find(@user_id)
      decision = RoleAssignmentRule.decide(actor: @actor, user: user, role_id: @role_id)
      return Result.new(ok: false, record: user, error: :not_authorized) unless decision.allowed?

      user.update!(permission_role: decision.role)
      Result.new(ok: true, record: user)
    end
  end
end
