# Rollback Strategy

**Schema version before this release:** `2026_05_26_145050`  
**Schema version after this release:** `2026_05_27_000003`  
**Migrations added in this release:** 3 (`20260527000001`, `20260527000002`, `20260527000003`)

---

## Decision Matrix

| Symptom | Severity | Action |
|---|---|---|
| Health check fails | Critical | Immediate rollback (Step A) |
| 500s on login / auth flow | Critical | Immediate rollback |
| Cross-business data visible | Critical | Immediate rollback + security incident |
| Payroll period state stuck | High | Investigate first; rollback if not resolved in 15 min |
| Attendance source filter broken | Medium | Hot-fix in 1–2 h; no rollback needed |
| i18n key missing (UI shows raw key) | Low | Hot-fix; no rollback needed |

---

## Step A — Application Rollback (code only, keep DB)

Use this when migrations are safe to leave in place (all additive) but the code has a bug.

```bash
# Switch Kamal to previous image
kamal rollback

# Or manually:
git checkout main          # or previous release tag
bundle install
RAILS_ENV=production bundle exec rails assets:precompile
kill -USR2 $(cat tmp/pids/puma.pid)
curl -s https://<APP_HOST>/up   # confirm 200
```

**When safe:** The 3 migrations in this release are additive only (no column drops, no renames). Running the previous code against the new schema is safe — old code ignores unknown columns.

---

## Step B — Full DB Rollback (code + database)

Use this only if the new migrations themselves caused data corruption or a critical logic error that the old code cannot tolerate.

```bash
# Step B1: Roll back migrations (reverse order)
RAILS_ENV=production bundle exec rails db:migrate:down VERSION=20260527000003
RAILS_ENV=production bundle exec rails db:migrate:down VERSION=20260527000002
RAILS_ENV=production bundle exec rails db:migrate:down VERSION=20260527000001

# Step B2: Confirm schema version
RAILS_ENV=production bundle exec rails db:version
# Expected: Current version: 20260526145050

# Step B3: Roll back code (same as Step A)
git checkout main
bundle install
RAILS_ENV=production bundle exec rails assets:precompile
kill -USR2 $(cat tmp/pids/puma.pid)
curl -s https://<APP_HOST>/up
```

---

## Step C — Full DB Restore from Snapshot

Use only when Step B is not possible (e.g., a migration ran `DROP TABLE` or corrupted data irreversibly).

```bash
# Step C1: Stop the app
kamal app stop   # or kill -TERM $(cat tmp/pids/puma.pid)

# Step C2: Restore snapshot
pg_restore --clean --if-exists -d $DATABASE_URL workpulse_pre_deploy_<timestamp>.dump

# Step C3: Roll back code
git checkout main
bundle install
RAILS_ENV=production bundle exec rails assets:precompile

# Step C4: Restart
kamal app start
curl -s https://<APP_HOST>/up
```

**Expected restore time:** < 10 min for a typical WorkPulse DB size.  
**Data loss window:** All writes between the snapshot and the restore are lost. Communicate to users.

---

## Migration Safety Analysis (this release)

| Migration | Type | Reversible | Risk |
|---|---|---|---|
| `20260527000001` | Add column (additive) | YES — `remove_column` | None |
| `20260527000002` | Add index (concurrent-safe) | YES — `remove_index` | None |
| `20260527000003` | Add column with default | YES — `remove_column` | None |

All three migrations are safe to roll back without data loss.

---

## Backup Strategy

### Automated (recommended setup)
```bash
# Cron: daily at 02:00 UTC
0 2 * * * pg_dump $DATABASE_URL -Fc -f /backups/workpulse_$(date +\%Y\%m\%d).dump
# Retain 30 days, then move to cold storage
find /backups -name "*.dump" -mtime +30 -exec rclone move {} r2:workpulse-backups/ \;
```

### Pre-deploy manual
```bash
pg_dump $DATABASE_URL -Fc -f workpulse_pre_deploy_$(date +%Y%m%d_%H%M).dump
# Upload to R2
rclone copy workpulse_pre_deploy_*.dump r2:workpulse-backups/pre-deploy/
```

### Verify restore quarterly
```bash
pg_restore --list workpulse_pre_deploy_<date>.dump | head -20
# Restore to staging DB and run spec suite against it
```

---

## Post-Rollback Checklist

- [ ] Health check passes
- [ ] Owner can log in and see payroll periods
- [ ] Branch manager sees correct scope
- [ ] Attendance records load
- [ ] Notify affected users of downtime window
- [ ] File post-mortem within 48 h: root cause, timeline, fix plan
