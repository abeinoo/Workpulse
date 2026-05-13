# WorkPulse — Production Deployment Guide (Hetzner VPS / Ubuntu)

This guide walks you through deploying WorkPulse on a fresh Ubuntu 22.04/24.04 Hetzner VPS
using Docker Compose. The stack is: **Puma + Thruster (Rails 8) · PostgreSQL 16 · Docker Compose**.

---

## 1. Provision the Hetzner VPS

Recommended minimum spec: **CPX21** (3 vCPU, 4 GB RAM, 80 GB SSD).  
Choose **Ubuntu 22.04** or **24.04** as the OS image.

Enable the Hetzner Firewall and open only:
- Port 22 (SSH)
- Port 80 (HTTP — Thruster will redirect to HTTPS)
- Port 443 (HTTPS)

---

## 2. Initial Server Setup

SSH in as root, then run:

```bash
# Create a deploy user
adduser deploy
usermod -aG sudo deploy
# Copy your SSH key to the new user
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
```

Switch to the deploy user for all remaining steps:

```bash
su - deploy
```

---

## 3. Install Docker Engine

```bash
# Remove any conflicting packages
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null || true
done

# Add Docker's official GPG key and repo
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Allow deploy user to run docker without sudo
sudo usermod -aG docker deploy
newgrp docker

# Verify
docker --version
docker compose version
```

---

## 4. Deploy the Application

### 4a. Copy code to the server

Option A — clone from Git:
```bash
git clone https://github.com/your-org/work-pulse.git /home/deploy/work_pulse
cd /home/deploy/work_pulse
```

Option B — rsync from your local machine (run locally):
```bash
rsync -avz --exclude='.git' --exclude='node_modules' --exclude='tmp' \
  . deploy@YOUR_SERVER_IP:/home/deploy/work_pulse/
```

### 4b. Create the .env file

```bash
cd /home/deploy/work_pulse
cp .env.example .env
nano .env   # fill in real values — see comments in the file
```

Required values to set:

| Variable | How to get it |
|---|---|
| `POSTGRES_PASSWORD` | Choose a strong random password |
| `DATABASE_URL` | `postgresql://work_pulse:<POSTGRES_PASSWORD>@db/work_pulse_production` |
| `RAILS_MASTER_KEY` | Copy the content of `config/master.key` from your development machine |
| `APP_HOST` | Your domain name, e.g. `workpulse.example.com` |

> **Never commit `.env` to Git.** It is already listed in `.gitignore`.

Generate a strong random password:
```bash
openssl rand -hex 32
```

### 4c. Build and start the containers

```bash
cd /home/deploy/work_pulse

# Build the Rails image
docker compose build

# Start PostgreSQL first (wait for healthy), then Rails
docker compose up -d

# Confirm both containers are running
docker compose ps

# Watch logs
docker compose logs -f web
```

The first boot automatically runs `rails db:prepare`, which:
1. Creates the PostgreSQL database
2. Loads the schema (all tables including solid_cache / solid_queue / solid_cable)
3. Seeds if applicable

---

## 5. Configure a Reverse Proxy with SSL (Nginx + Certbot)

Thruster handles basic HTTP compression and X-Sendfile, but for production you
should terminate SSL at Nginx and proxy to Docker.

```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
```

Create `/etc/nginx/sites-available/work_pulse`:
```nginx
server {
    listen 80;
    server_name workpulse.example.com;

    location /up {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host $host;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name workpulse.example.com;

    ssl_certificate     /etc/letsencrypt/live/workpulse.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/workpulse.example.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 100M;

    location / {
        proxy_pass         http://127.0.0.1:80;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/work_pulse /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Obtain a free Let's Encrypt certificate
sudo certbot --nginx -d workpulse.example.com
```

---

## 6. Manage the Application

### View logs
```bash
docker compose logs -f web     # Rails
docker compose logs -f db      # PostgreSQL
```

### Run Rails console
```bash
docker compose exec web ./bin/rails console
```

### Run a one-off task
```bash
docker compose exec web ./bin/rails db:migrate
docker compose exec web ./bin/rails runner "User.count"
```

### Connect to PostgreSQL directly
```bash
docker compose exec db psql -U work_pulse -d work_pulse_production
```

### Deploy a new version

```bash
cd /home/deploy/work_pulse
git pull                          # or rsync new code
docker compose build web          # rebuild the Rails image
docker compose up -d --no-deps web  # zero-ish downtime rolling replace
```

---

## 7. Automatic Container Restart

`restart: unless-stopped` is set in docker-compose.yml, so containers start
automatically after a server reboot. Verify with:

```bash
sudo reboot
# After reconnecting:
docker compose -f /home/deploy/work_pulse/docker-compose.yml ps
```

Optionally register a systemd service for a cleaner lifecycle:

```bash
sudo nano /etc/systemd/system/work_pulse.service
```
```ini
[Unit]
Description=WorkPulse Docker Compose
After=docker.service network-online.target
Requires=docker.service

[Service]
WorkingDirectory=/home/deploy/work_pulse
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
User=deploy

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now work_pulse
```

---

## 8. Database Backups

Schedule a daily PostgreSQL dump:

```bash
# Create a backup script
cat > /home/deploy/backup_db.sh << 'EOF'
#!/bin/bash
BACKUP_DIR=/home/deploy/backups
mkdir -p "$BACKUP_DIR"
FILENAME="$BACKUP_DIR/work_pulse_$(date +%Y%m%d_%H%M%S).dump"
docker compose -f /home/deploy/work_pulse/docker-compose.yml exec -T db \
  pg_dump -U work_pulse -Fc work_pulse_production > "$FILENAME"
# Keep only the last 7 days
find "$BACKUP_DIR" -name "*.dump" -mtime +7 -delete
echo "Backup written to $FILENAME"
EOF

chmod +x /home/deploy/backup_db.sh

# Schedule via cron (runs daily at 2 AM)
(crontab -l 2>/dev/null; echo "0 2 * * * /home/deploy/backup_db.sh >> /home/deploy/backup.log 2>&1") | crontab -
```

Restore from a backup:
```bash
docker compose exec -T db \
  pg_restore -U work_pulse -d work_pulse_production < backup.dump
```

---

## 9. Security Checklist

- [ ] `.env` contains strong, random passwords — never committed to Git
- [ ] `config/master.key` never committed (already in `.gitignore`)
- [ ] Hetzner Firewall limits inbound to ports 22, 80, 443
- [ ] SSH password authentication disabled (`PasswordAuthentication no` in sshd_config)
- [ ] Certbot auto-renew active: `sudo certbot renew --dry-run`
- [ ] `RAILS_MASTER_KEY` set in `.env` (not `RAILS_ENV` — that is baked into the Docker image)
- [ ] Backups tested and stored off-server (e.g. Hetzner Object Storage / S3)
