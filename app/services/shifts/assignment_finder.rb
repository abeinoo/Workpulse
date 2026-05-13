module Shifts
  class AssignmentFinder
    # Returns the active ShiftAssignment for a user on a given date,
    # preferring the most-recently started assignment when multiple exist.
    def self.for(user:, branch: nil, date: Date.current)
      scope = ShiftAssignment
        .includes(:shift, :branch)
        .where(user: user)
        .active_on(date)
        .order(effective_from: :desc)

      scope = scope.where(branch: branch) if branch
      scope.first
    end
  end
end
