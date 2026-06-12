class BackfillDepartmentsFromUsers < ActiveRecord::Migration[8.1]
  # Data migration. Promotes the free-text users.department string into
  # first-class Department records and links users via department_id.
  #
  # Normalization rules (per the approved plan):
  #   - trim leading/trailing whitespace
  #   - collapse internal whitespace runs to a single space
  #   - dedup case-insensitively on the normalized key, so "Reception",
  #     " reception " and "Reception  Desk" variants don't create duplicates.
  #
  # The canonical display name for each group is the most common original
  # spelling (ties broken by first seen). A report of blank/unmapped users is
  # printed to the migration log at the end.
  def up
    report = { businesses: 0, departments_created: 0, users_linked: 0, blank_users: 0 }

    business_ids = select_values("SELECT id FROM businesses ORDER BY id")

    business_ids.each do |business_id|
      report[:businesses] += 1

      rows = select_all("SELECT id, department FROM users WHERE business_id = #{q(business_id)}")

      # normalized_key => { variants: Hash(original=>count), user_ids: [] }
      groups = Hash.new { |h, k| h[k] = { variants: Hash.new(0), user_ids: [] } }

      rows.each do |row|
        normalized = row["department"].to_s.strip.gsub(/\s+/, " ")
        if normalized.blank?
          report[:blank_users] += 1
          next
        end
        key = normalized.downcase
        groups[key][:variants][normalized] += 1
        groups[key][:user_ids] << row["id"]
      end

      groups.each_value do |group|
        canonical = group[:variants].max_by { |_name, count| count }.first

        dept_id = insert_department(business_id, canonical)
        report[:departments_created] += 1

        id_list = group[:user_ids].map { |id| q(id) }.join(", ")
        execute("UPDATE users SET department_id = #{q(dept_id)} WHERE id IN (#{id_list})")
        report[:users_linked] += group[:user_ids].size
      end
    end

    log_report(report)
  end

  def down
    # Reversible: just unlink. The departments table itself is dropped by the
    # paired create-table migration's rollback.
    execute("UPDATE users SET department_id = NULL")
    execute("DELETE FROM departments")
  end

  private

  def q(value)
    connection.quote(value)
  end

  def insert_department(business_id, name)
    now = q(Time.current)
    select_value(
      "INSERT INTO departments (business_id, name, active, created_at, updated_at) " \
      "VALUES (#{q(business_id)}, #{q(name)}, TRUE, #{now}, #{now}) RETURNING id"
    )
  end

  def log_report(report)
    say "Department backfill complete:"
    say "businesses scanned ...... #{report[:businesses]}",      true
    say "departments created ..... #{report[:departments_created]}", true
    say "users linked ............ #{report[:users_linked]}",    true
    say "users with blank dept ... #{report[:blank_users]} (left unmapped — department_id is NULL)", true
  end
end
