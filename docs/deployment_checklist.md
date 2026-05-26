# Production Deployment Checklist

**Schema version:** `2026_05_27_000003`  
**Release date:** 2026-05-26  
**Release branch:** `release/stable-2026-05-26`

---

## Pre-Deployment (24 h before)

### Code
- [ ] All specs pass locally: `bundle exec rspec` → 0 failures (1 527 examples)
- [ ] Brakeman clean: `bin/brakeman --no-pager` → 0 warnings
- [ ] Bundle audit clean: `bin/bundler-audit` → no vulnerabilities
- [ ] Gemfile.lock committed (includes devise 5.0.4 security patch)
- [ ] No `binding.pry` / `debugger` / `byebug` calls in source
- [ ] `git diff main release/stable-2026-05-26` reviewed by a second person

### Database
- [ ] 0 pending migrations (`rails db:migrate:status` → all `up`)
- [ ] No new migrations are irreversible (verify each `change` method has a safe `down`)
- [ ] DB backup taken and verified restorable (see Backup Strategy)

### Infrastructure
- [ ] All required ENV vars present in production server (see ENV Checklist below)
- [ ] Cloudflare R2 bucket accessible and credentials valid
- [ ] `APP_HOST` set to production domain
- [ ] `RAILS_LOG_LEVEL=info` set
- [ ] `WEB_CONCURRENCY` and `RAILS_MAX_THREADS` tuned for server RAM
- [ ] Solid Cache DB writable (`:cache` DB connection configured)
- [ ] Solid Queue DB writable (`:queue` DB connection configured)

---

## ENV Checklist

| Variable | Required | Notes |
|---|---|---|
| `SECRET_KEY_BASE` | YES | 128-char hex, from credentials or env |
| `DATABASE_URL` | YES | Primary PostgreSQL |
| `R2_ACCESS_KEY_ID` | YES | Cloudflare R2 |
| `R2_SECRET_ACCESS_KEY` | YES | Cloudflare R2 |
| `R2_BUCKET` | YES | Cloudflare R2 bucket name |
| `R2_ENDPOINT` | YES | `https://<account>.r2.cloudflarestorage.com` |
| `APP_HOST` | YES | e.g. `app.workpulse.io` |
| `RAILS_LOG_LEVEL` | NO | defaults to `info` |
| `WEB_CONCURRENCY` | NO | Puma workers, default 2 |
| `SOLID_QUEUE_IN_PUMA` | NO | Set to `1` for single-process deployments |
| `RAILS_MASTER_KEY` | YES | contents of `config/master.key` |

---

## Deployment Steps

### Step 1 — Take DB snapshot
```bash
pg_dump $DATABASE_URL -Fc -f workpulse_pre_deploy_$(date +%Y%m%d_%H%M).dump
```
Store snapshot in S3/R2 retention bucket. Verify restore takes < 10 min.

### Step 2 — Pull release branch
```bash
git fetch origin
git checkout release/stable-2026-05-26
```

### Step 3 — Install dependencies
```bash
bundle install --without development test
```

### Step 4 — Run migrations (zero downtime aware)
All migrations in this release are additive (new columns with defaults, new tables, new indexes). No column removals or renames.
```bash
RAILS_ENV=production bundle exec rails db:migrate
```
Expected output: schema version `2026_05_27_000003`, no errors.

### Step 5 — Precompile assets
```bash
RAILS_ENV=production bundle exec rails assets:precompile
```

### Step 6 — Rolling restart (if using Kamal/Docker)
```bash
kamal deploy
```
Or for manual Puma restart:
```bash
kill -USR2 $(cat tmp/pids/puma.pid)
```

### Step 7 — Health check
```bash
curl -s https://<APP_HOST>/up
# Expected: HTTP 200 "OK"
```

### Step 8 — Smoke tests (manual, 5 min)
- [ ] Login as owner → payroll index loads
- [ ] Login as branch manager → sees only managed branches' entries
- [ ] Login as employee → redirected to own payroll entry
- [ ] Create a new payroll period (draft → under_review)
- [ ] Check attendance record source filter works
- [ ] Arabic locale switch works and RTL layout renders
- [ ] File upload (employee photo) succeeds

### Step 9 — Monitor for 30 min
Watch production logs: `tail -f log/production.log | grep "ERROR\|WARN\|\[Payroll\]\|\[Attendance\]"`

---

## Post-Deployment Verification

- [ ] `rails db:migrate:status` → all `up`
- [ ] Log tail shows no ERROR lines in first 30 min of traffic
- [ ] Check Solid Queue dashboard — jobs processing normally
- [ ] Verify at least one payroll notification was sent successfully
- [ ] No 500 errors in first 1 000 requests (check server/app logs)

---

## Rollback Triggers

Initiate rollback immediately if:
- Health check `/up` returns non-200 after deploy
- Error rate on any page exceeds 1% within 15 min
- Any `Pundit::NotAuthorizedError` appearing for unexpected roles (cross-tenant leak indicator)
- Payroll period state machine stuck (entries not saving)
- ActiveStorage uploads failing (R2 credentials issue)
