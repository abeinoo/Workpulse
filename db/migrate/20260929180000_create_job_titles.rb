# Managed job-title list (المسمى الوظيفي) per business — the single source of
# truth for the job-title dropdown on the employee form and the employee data
# request. users.job_title stays the employee's field (a name from this list),
# so nothing that reads it changes.
#
# Backfill: every distinct job title already on a business's employees becomes
# an active entry (whitespace-collapsed, case-insensitively de-duplicated), so
# no existing employee is left with a value missing from the list.
class CreateJobTitles < ActiveRecord::Migration[8.1]
  def up
    create_table :job_titles do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,   null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :job_titles, "business_id, lower((name)::text)", unique: true,
              name: "index_job_titles_on_business_id_and_lower_name"

    execute <<~SQL
      INSERT INTO job_titles (business_id, name, active, created_at, updated_at)
      SELECT DISTINCT ON (u.business_id, lower(t.name))
             u.business_id, t.name, TRUE, NOW(), NOW()
      FROM users u
      CROSS JOIN LATERAL (
        SELECT btrim(regexp_replace(u.job_title, '\\s+', ' ', 'g')) AS name
      ) t
      WHERE u.business_id IS NOT NULL AND t.name <> ''
      ORDER BY u.business_id, lower(t.name), t.name
    SQL
  end

  def down
    drop_table :job_titles
  end
end
