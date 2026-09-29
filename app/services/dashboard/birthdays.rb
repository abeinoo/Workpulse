module Dashboard
  # Today's birthdays for the dashboard.
  #
  # "Today" is always the business day (BusinessDay.current) in the business's
  # timezone — never the browser or server calendar day. Birthdays match on
  # day + month only; nothing is stored per year, so every employee becomes
  # eligible again automatically on their next birthday.
  #
  # Visibility never widens: the team list is built from the caller-supplied
  # `visible_users` relation (policy_scope(User) in the controller), so a
  # viewer only ever sees birthdays for employees they can already access.
  class Birthdays
    Entry = Struct.new(:user, :branch_name, keyword_init: true)

    # Employees (excluding the viewer) in `visible_users` whose birthday is
    # `date`. Two queries total: the users, then their current branch names.
    def self.team(visible_users, viewer:, date:)
      users = visible_users.active
                           .where.not(id: viewer.id)
                           .birthday_on(date)
                           .order(:first_name, :last_name)
                           .to_a
      return [] if users.empty?

      branch_names = ShiftAssignment.branch_names_by_user(users.map(&:id), from: date, to: date)
      users.map { |u| Entry.new(user: u, branch_name: branch_names[u.id]) }
    end

    # Lightweight "already celebrated today" marker. Keyed by user + business
    # day so it expires on its own and never needs cleanup; employee records
    # are left untouched.
    module Celebration
      module_function

      def shown?(user, date)
        Rails.cache.exist?(cache_key(user, date))
      end

      def mark_shown!(user, date)
        Rails.cache.write(cache_key(user, date), true, expires_in: 2.days)
      end

      def cache_key(user, date)
        "birthday_celebration/v1/#{user.id}/#{date.iso8601}"
      end
    end
  end
end
