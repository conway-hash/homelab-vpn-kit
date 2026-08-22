# One-time setup

Everything here is run **once**, by a human, from a machine with `gcloud` and
`gh` installed and authenticated. After this, pushes/PRs to this repo do all
the work.

## This repo now also deploys the tailnet's reverse proxy server (Proxmox, home network)

No separate repo, no shared collection to install — it's one repo now, so
`tailnet_base_domain`/`headscale_server_url` just live in
`ansible/group_vars/all/vars.yml` directly. Steps 0-8 are the GCP
coordination server; steps 9-13 add the reverse proxy server's VM.

**Run them in that order, and don't skip ahead.** The two halves are
sequenced on purpose, not just for tidiness: CI joins the tailnet with a
Headscale pre-auth key (`TS_AUTHKEY`), and that key can only be minted by
running `headscale preauthkeys create` **on the coordination server** — which
step 8 is what creates. So the Proxmox half genuinely cannot be set up until
the GCP half is live.

That's why `ENABLE_PROXY` exists. Until you set that repo variable to
`true` (step 12), `tofu` manages the GCP coordination server alone: the
Proxmox resources are counted out to zero, the tailnet-join steps are
skipped, and the `ansible-deploy-proxy` job doesn't run. Step 8's first
deploy therefore needs none of the Proxmox, Cloudflare, or Tailscale
secrets — a fresh copy of this repo can get to a working coordination
server with nothing but steps 0-8.

## Staying inside GCP's Always Free tier

This repo's defaults (`terraform/variables.tf`) target Compute Engine's
Always Free allowance:

- **`e2-micro`**, and only in **`us-west1`, `us-central1`, or `us-east1`**
  (default: `us-central1`) — any other machine type or region is billed
  normally.
- **One `pd-standard` boot disk up to 30 GB** — `pd-balanced`/`pd-ssd` are
  never free, at any size.
- **One free instance per billing account**, not per project — if you (or
  anything else on this billing account) already runs a free-tier VM
  elsewhere, this one will be billed too.
- The static IP is free *while attached to a running instance*. If you ever
  stop the instance without releasing the IP, GCP starts charging for the
  now-idle reservation.
- Network egress: ~1 GB/month to most destinations is free; a VPN
  relaying real traffic can exceed that fairly easily — check the Billing
  page after the first month rather than assuming it's zero.
- `e2-micro` has 1 GB RAM. The playbook adds a 2 GB swapfile as headroom for
  Docker + Headplane, but this is not a machine with slack to spare — expect
  to upsize to `e2-small`/`e2-medium` (both billed) if the tailnet grows.

## 0. Fill in these values

```bash
export PROJECT_ID="your-gcp-project-id"        # must not already exist, or already be yours
export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"  # gcloud billing accounts list
export REPO="conway-hash/homelab-vpn-kit" # GitHub owner/repo
export DOMAIN="vpn.conway-hash.com"            # must match headscale_server_url's hostname in ansible/group_vars/all/vars.yml
export TAILNET_DOMAIN="ts.conway-hash.com"     # must match tailnet_base_domain in ansible/group_vars/all/vars.yml
export REGION="us-central1"                    # Always Free tier: us-west1 | us-central1 | us-east1 only
export ZONE="us-central1-a"
export SA_NAME="gh-actions-deployer"
export POOL_ID="github-pool"
export PROVIDER_ID="github-provider"
```

## 1. Create the GCP project and enable APIs

```bash
gcloud projects create "$PROJECT_ID"
gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

gcloud services enable \
  compute.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  --project "$PROJECT_ID"
```

## 2. Create the OpenTofu state bucket

```bash
gsutil mb -l EU -b on "gs://${PROJECT_ID}-tofu-state"
gsutil versioning set on "gs://${PROJECT_ID}-tofu-state"
```

## 3. Create the deployer service account

This is the identity GitHub Actions assumes. It gets only what it needs to
manage this VM's network/compute resources and to tunnel SSH through IAP —
nothing account-wide.

```bash
gcloud iam service-accounts create "$SA_NAME" \
  --project "$PROJECT_ID" \
  --display-name "GitHub Actions deployer"

export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in roles/compute.instanceAdmin.v1 roles/compute.networkAdmin \
            roles/compute.securityAdmin roles/iam.serviceAccountUser \
            roles/iap.tunnelResourceAccessor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None
done

gsutil iam ch "serviceAccount:${SA_EMAIL}:roles/storage.objectAdmin" \
  "gs://${PROJECT_ID}-tofu-state"
```

## 4. Workload Identity Federation (no long-lived key ever leaves GCP)

```bash
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" --location="global" \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

export WIF_POOL=$(gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location=global --format="value(name)")

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WIF_POOL}/attribute.repository/${REPO}"

echo "GCP_WORKLOAD_IDENTITY_PROVIDER = ${WIF_POOL}/providers/${PROVIDER_ID}"
echo "GCP_SERVICE_ACCOUNT_EMAIL      = ${SA_EMAIL}"
```

The `--attribute-condition` above pins this exactly to `$REPO` — no other
repository can ever assume this identity, even if it also uses GitHub's OIDC
issuer.

## 5. SSH keypair for Ansible (goes over the IAP tunnel, never a public port)

```bash
ssh-keygen -t ed25519 -f ./deploy_key -N "" -C "gh-actions-ansible"
```

## 6. Google OAuth client — used by TWO separate login flows

This one client covers both:

- **Headscale's own OIDC** — lets `tailscale up --login-server=https://$DOMAIN`
  authenticate a device via Google SSO instead of a pre-auth key.
- **Headplane's OIDC** — lets you log into the admin UI at `/admin`.

Console → **APIs & Services → Credentials → Create Credentials → OAuth client
ID** → Application type "Web application". Add **both** authorized redirect
URIs to it:

- `https://${DOMAIN}/oidc/callback` (headscale — fixed path, not configurable)
- `https://${DOMAIN}/admin/oidc/callback` (headplane — double-check this one
  against the Headplane version you're running; it logs the redirect URI it
  expects on its first OIDC attempt if this is wrong)

Note the generated **Client ID** and **Client secret**.

**Also decide who's allowed to join the tailnet.** Without this, any Google
account on the internet could authenticate a device against your headscale
server — the playbook refuses to deploy if it's empty, on purpose.

```bash
export ALLOWED_USERS="you@gmail.com"   # comma-separated if more than one
```

## 7. Push everything into GitHub secrets/variables

```bash
gh secret set GCP_PROJECT_ID                --body "$PROJECT_ID" -R "$REPO"
gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body "${WIF_POOL}/providers/${PROVIDER_ID}" -R "$REPO"
gh secret set GCP_SERVICE_ACCOUNT_EMAIL      --body "$SA_EMAIL" -R "$REPO"
gh secret set TF_STATE_BUCKET                --body "${PROJECT_ID}-tofu-state" -R "$REPO"
gh secret set SSH_PUBLIC_KEY                 --body "$(cat deploy_key.pub)" -R "$REPO"
gh secret set SSH_PRIVATE_KEY                --body "$(cat deploy_key)" -R "$REPO"
gh secret set GOOGLE_OIDC_CLIENT_ID          --body "PASTE_CLIENT_ID" -R "$REPO"
gh secret set GOOGLE_OIDC_CLIENT_SECRET      --body "PASTE_CLIENT_SECRET" -R "$REPO"

gh variable set GCP_REGION                 --body "$REGION" -R "$REPO"
gh variable set GCP_ZONE                   --body "$ZONE" -R "$REPO"
gh variable set INSTANCE_NAME              --body "coordination-server" -R "$REPO"
gh variable set MACHINE_TYPE               --body "e2-micro" -R "$REPO"
gh variable set HEADSCALE_ALLOWED_OIDC_USERS --body "$ALLOWED_USERS" -R "$REPO"
```

No `DOMAIN` variable here on purpose — `deploy.yml` derives it from
`headscale_server_url` in `ansible/group_vars/all/vars.yml` at run time,
same as `HEADSCALE_SERVER_URL`/`TAILNET_BASE_DOMAIN`. The `$DOMAIN` you
exported above is only for the commands in this file — make sure it
actually matches what you put in `group_vars/all/vars.yml`.

Now delete `deploy_key` and `deploy_key.pub` from your local disk — they're
in GitHub Secrets now and don't need to exist anywhere else.

## 8. First run

1. Open a PR touching anything under `terraform/` (or just push a no-op
   change) → the **OpenTofu Plan** workflow runs and comments the plan.
2. Merge to `main` → **Deploy Coordination Server** applies the infra, then
   runs the Ansible playbook against the new VM.
3. Take the `external_ip` from the tofu output (or the GCP Console) and point
   `$DOMAIN`'s DNS **A record** at it. Caddy retries ACME issuance until the
   record resolves, so it's fine to apply first and add DNS a few minutes
   later.
4. Visit `https://$DOMAIN/admin` and log in via Google OIDC.
5. Join a device: `tailscale up --login-server=https://$DOMAIN` — it opens a
   browser for the same Google login, checked against
   `HEADSCALE_ALLOWED_OIDC_USERS`.

## 9. Reverse proxy server VM (Proxmox) — Cloudflare DNS-01 token

Cloudflare dashboard → My Profile → API Tokens → Create Token → custom:

- Permission: `Zone / DNS / Edit`
- Zone Resources: `Include / Specific zone / conway-hash.com`

Nothing broader — this token can create/delete DNS records on that zone,
scope it to only that.

## 10. Reverse proxy server VM (Proxmox) — Proxmox API token

Datacenter → Permissions → API Tokens → Add. Give the token's user a role
limited to VM/storage management (`PVEVMAdmin` or a custom role), not
`Administrator`. Note the full token string: `user@realm!tokenid=uuid`.

## 11. Two Headscale pre-auth keys — these are NOT interchangeable

Run on the coordination server itself (`gcloud compute ssh coordination-server --tunnel-through-iap --zone=$ZONE`, then `docker exec headscale headscale preauthkeys create ...`):

```bash
# CI runner joins: reusable, ephemeral (cleans itself up after each run).
# --expiration 99y instead of a short window on purpose — this key is
# reused by every CI run indefinitely, and Headscale has no separate
# "never expires" option (Prometheus-style duration parser under the
# hood, capped around ~290y — 99y is comfortably inside that, just long
# enough to not think about again). Reusable + tailnet-only + a GitHub
# secret never exposed to forks is the actual protection here, not the
# expiration — see "Rotating things" below if you'd rather it stay short.
headscale preauthkeys create --reusable --expiration 99y --ephemeral
# → TS_AUTHKEY secret

# Reverse proxy server VM's own join: one-shot, must persist, so NOT
# ephemeral — but only needs to survive long enough for first deploy to
# use it once, so a short expiration is correct here, unlike TS_AUTHKEY.
headscale preauthkeys create --expiration 1h
# → PROXY_NODE_TS_AUTHKEY secret (used once, on first deploy)
```

Using `--ephemeral` for the reverse proxy server VM by mistake means
Headscale deregisters it the moment it briefly drops off the tailnet — don't.

## 12. Push the reverse proxy server's secrets/variables

```bash
gh secret set TS_AUTHKEY             --body "PASTE_CI_KEY" -R "$REPO"
gh secret set PROXY_NODE_TS_AUTHKEY  --body "PASTE_PROXY_KEY" -R "$REPO"
gh secret set CLOUDFLARE_API_TOKEN   --body "PASTE_CF_TOKEN" -R "$REPO"
gh secret set PROXMOX_API_TOKEN      --body "user@realm!tokenid=uuid" -R "$REPO"

gh variable set PROXMOX_HOST --body "pve" -R "$REPO"  # <-- your Proxmox box's tailnet hostname, short name only
gh variable set PROXMOX_NODE --body "pve" -R "$REPO"  # <-- its Proxmox cluster node name

# Last: flips the reverse proxy server on. Until this is "true", every
# workflow above treats the Proxmox half as not existing.
gh variable set ENABLE_PROXY --body "true" -R "$REPO"
```

`PROXMOX_HOST` is deliberately just the short hostname, not a URL — the API
endpoint is assembled as `https://$PROXMOX_HOST.<tailnet_base_domain>:8006/`
with the base domain read from `ansible/group_vars/all/vars.yml`. Storing the
whole URL here would mean a second copy of the base domain that could drift
from the real one (and, in an earlier draft of this file, produced a
`pve.ts.ts.conway-hash.com` that resolved nowhere).

Also fill in `acme_email` (shared by both Caddys) in `ansible/group_vars/all/vars.yml`
— it's currently a placeholder — and commit that (it's not a secret).

**Not needed as secrets/variables**: `HEADSCALE_SERVER_URL` /
`TAILNET_BASE_DOMAIN`. Every workflow reads those straight out of
`ansible/group_vars/all/vars.yml` at run time — nothing to retype, no way
for a copy to drift from the real value, since there's only one repo now.

## 13. First reverse proxy server deploy

Push to `main` (or run `deploy.yml` manually) once steps 9-12 are done. The
`ansible-deploy-proxy` job's last step curls
`https://proxy.ts.conway-hash.com/` — the VM's own MagicDNS name, which is
what the wildcard cert actually covers — and fails loudly if Caddy didn't get
a cert and come up cleanly — green means genuinely reachable, not just
"ansible said ok."

## Rotating things

- **Headscale API key**: SSH in (`gcloud compute ssh coordination-server
  --tunnel-through-iap --zone=$ZONE`), delete
  `/opt/coordination_server_stack/headplane/.api_key`, re-run the `deploy` workflow.
- **Headplane cookie secret**: same idea, delete `.cookie_secret` instead —
  this invalidates existing Headplane sessions.
- **Google OIDC client secret**: rotate in Google Cloud Console, then
  `gh secret set GOOGLE_OIDC_CLIENT_SECRET --body "NEW_VALUE" -R "$REPO"` and
  re-run the deploy workflow.
- **PROXY_NODE_TS_AUTHKEY**: only used on the reverse proxy server VM's first join — rotating
  it does nothing until the VM is recreated. To force a rejoin, mint a new
  non-ephemeral key (step 11) and re-run `deploy.yml` after removing the old
  Tailscale state on the box (`tailscale logout` over SSH, then redeploy).
- **CLOUDFLARE_API_TOKEN**: rotate in the Cloudflare dashboard, update the
  GitHub secret, re-run `deploy.yml` — Caddy picks it up on next container
  recreate, no manual cert re-issuance needed.
- **TS_AUTHKEY**: created with `--expiration 99y` (step 11) specifically so
  this isn't a recurring task — every `tofu apply`/`tofu plan`/
  `ansible-deploy-proxy` run reuses it to join the tailnet, and Headscale
  has no true "never expires" option, so 99y is the practical version of
  that. If you'd rather it stay short-lived (smaller exposure window if
  the GitHub secret ever leaked, at the cost of remembering to rotate it),
  mint one with a shorter `--expiration` instead and rotate the same way:
  new key, `gh secret set TS_AUTHKEY`, before the old one lapses. Nothing
  rotates it automatically either way — see the earlier note in this repo
  about why automating that would need a *more* dangerous permanent
  credential than the thing it's rotating.
