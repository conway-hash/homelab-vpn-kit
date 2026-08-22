# homelab-vpn-kit

OpenTofu + Ansible, running from GitHub Actions, that stand up **two**
machines and everything on them: a small GCP VM running a self-hosted
[Tailscale](https://tailscale.com)-compatible coordination server
([Headscale](https://github.com/juanfont/headscale) behind
[Caddy](https://caddyserver.com), with
[Headplane](https://github.com/tale/headplane) as the admin UI) — and a
Proxmox VM, on your home network, running the tailnet's reverse proxy
server: a second Caddy that gives every tailnet-only device (Proxmox
itself, and whatever else gets added later) a real HTTPS cert and a clean
name, `*.ts.conway-hash.com`, instead of a self-signed cert on some random
port.

One repo, both machines — deliberately. The two boxes do genuinely different
jobs, but they share vars that must never drift between them
(`tailnet_base_domain`, `headscale_server_url`), and splitting them into
separate repos meant that sharing needed real plumbing (a shared collection,
composite GitHub Actions, cross-repo fetches) to avoid duplicating those
values. One repo removes the problem instead of solving it.

- Coordination server: `https://vpn.conway-hash.com`
- Tailnet device names (MagicDNS): `*.ts.conway-hash.com`
- Reverse proxy server (Proxmox, home network): `https://proxy.ts.conway-hash.com`
  and one hostname per fronted device, e.g. `https://pve.ts.conway-hash.com`

**Why the reverse proxy server runs on Proxmox, not the GCP box**: it would
have been one fewer machine to fold it into the coordination server. But
every request to a home-network device (Proxmox's own web UI, its
interactive noVNC console especially) would then round-trip out to GCP's
region and back for no reason — the device being fronted is sitting right
next to the reverse proxy server either way, so it stays local specifically
to keep that traffic local-speed.

## Using this as a template

This is the author's own real, running config — `conway-hash.com` and its
subdomains are genuine, not placeholders, and left in place deliberately
(a real worked example beats a sterile one). "Use this template" copies
files byte-for-byte, though — nothing here auto-substitutes your domain.
Before deploying your own copy:

- `ansible/group_vars/all/vars.yml` — `tailnet_base_domain`,
  `headscale_server_url`, `acme_email`

That's the whole list — all three live in the one file, and each is marked
`# <-- change this` on the line above it. There's deliberately nothing to
change in `coordination_server/vars.yml` or `reverse_proxy_server/vars.yml`:
those hold only per-machine values (paths, version pins, the short tailnet
hostname), and `domain` isn't declared at all — it's derived from
`headscale_server_url`, since they're the same fact in two forms. Skip the
edits above and your deploy will think it's serving `conway-hash.com`'s
tailnet, not yours. [`SETUP.md`](./SETUP.md) walks through the rest (GCP project,
Proxmox, Cloudflare, secrets) with `export`-style placeholders you fill in
as you go.

## Architecture

```
        you / any tailscale client
                     │
                     │  :443
                     ▼
        ┌────────────────────────────────────────────┐
        │ vpn.conway-hash.com  (GCP)                 │
        ├────────────────────────────────────────────┤
        │ Caddy — automatic TLS, ACME HTTP-01        │
        ├────────────────────────────────────────────┤
        │ /admin*  ──▶  headplane:3000               │
        │ /*       ──▶  headscale:8080               │
        └────────────────────────────────────────────┘
                     │
                     ▼
        ┌────────────────────────────────────────────┐
        │ headscale + headplane  (one docker network)│
        ├────────────────────────────────────────────┤
        │ headscale — sqlite: tailnet keys, DERP map │
        │   OIDC (Google) → a device joining via     │
        │   `tailscale up`                           │
        ├────────────────────────────────────────────┤
        │ headplane — admin UI at /admin             │
        │   OIDC (Google) → you                      │
        └────────────────────────────────────────────┘


        you / any tailscale client
                     │
                     │  :443
                     ▼
        ┌────────────────────────────────────────────┐
        │ *.ts.conway-hash.com  (Proxmox)            │
        ├────────────────────────────────────────────┤
        │ Caddy — wildcard cert, ACME DNS-01,        │
        │   via the Cloudflare API                   │
        ├────────────────────────────────────────────┤
        │ pve.ts.*    ──▶  100.x.x.x:8006            │
        │ ...one block per fronted device            │
        └────────────────────────────────────────────┘
                     │
                     ▼  joins the tailnet itself (tailscale role)
                        — needs its own tailnet IP to reach the
                        devices it fronts
```

How both of those actually get built and deployed (OpenTofu, then which
Ansible job, over which connection) is in the
["How CI/CD works"](#how-cicd-works) table below, not repeated here as a
third diagram — it's the same information, a table just doesn't get
messy the way a branching ASCII diagram does.

Everything above the VM boundary is provisioned by OpenTofu; everything
inside each VM is configured by Ansible. Neither is ever run by hand against
production — both run from GitHub Actions.

## Repo layout

```
terraform/
  gcp.tf                the coordination server: VPC, firewall, static IP, the VM
  proxmox.tf             the reverse proxy server VM: cloud image import + the VM itself
  providers.tf/versions.tf/variables.tf/outputs.tf   both providers, one state, one GCS backend
ansible/
  site.yml              entrypoint — two plays, one per host group
  group_vars/
    all/vars.yml           golden-base facts shared by both plays (tailnet_base_domain, headscale_server_url, acme_email)
    coordination_server/   stack_dir, headscale/headplane/caddy version pins (domain is derived, not declared)
    reverse_proxy_server/  stack_dir, caddy version pin, tailnet_hostname
  roles/
    docker/                installs Docker Engine + Compose plugin — used by both plays
    tailscale/              joins the reverse proxy server VM to the tailnet (coordination server doesn't need this)
    coordination_server_stack/     Caddyfile, docker-compose.yml, headscale + headplane configs
    reverse_proxy_server_stack/    Caddyfile (wildcard, DNS-01), docker-compose.yml, xcaddy Dockerfile
.github/workflows/
  terraform-plan.yml     PR check: tofu fmt/validate/plan (both providers), posted as a PR comment
  deploy.yml             on merge to main: tofu apply, then two Ansible deploy jobs (one per host)
  ansible-lint.yml       PR check: ansible-lint against site.yml
SETUP.md               one-time bootstrap: GCP + Proxmox + Cloudflare + secrets — run once by hand
renovate.json          dependency updates: GitHub Actions, both terraform providers,
                       Ansible Galaxy collections, and the pinned headscale/headplane/
                       caddy(×2, independently) image versions (see below)
```

## Keeping dependencies current

[Renovate](https://github.com/apps/renovate) (not installed by default — add
it to this repo from the GitHub Marketplace to activate `renovate.json`)
opens PRs for:

- GitHub Actions versions used in `.github/workflows/`
- the `google` provider constraint in `terraform/versions.tf`
- the Ansible Galaxy collections in `ansible/requirements.yml`
- the `headscale_version` / `headplane_version` / `caddy_version` pins in
  `ansible/group_vars/coordination_server/vars.yml`, and the reverse proxy
  server's own separate `caddy_version` pin in
  `ansible/group_vars/reverse_proxy_server/vars.yml` — kept independently
  upgradable on purpose, not shared, so bumping Caddy there doesn't force
  the same bump on the coordination server in the same PR (all read via a
  custom regex rule, since the actual `docker-compose.yml`
  files are Jinja templates Renovate can't parse directly)

GitHub's own Dependabot security alerts and automated security fixes are
also on for this repo — that's independent of Renovate and needs no config
file; see repo Settings → Code security.

## How CI/CD works

| Trigger | What runs |
|---|---|
| PR touching `terraform/**` | `tofu fmt -check`, `tofu validate`, `tofu plan` (both providers, one plan) — posted as a PR comment, nothing is applied |
| PR touching `ansible/**` | `ansible-lint` against `site.yml` |
| Push to `main` | `tofu apply` (both VMs' resources), then two Ansible jobs in parallel: `--limit coordination_server` over an IAP tunnel, `--limit reverse_proxy_server` over the tailnet directly |
| Manual (`workflow_dispatch`) | Re-run `deploy.yml` on demand — e.g. after rotating a secret |

No infrastructure is ever applied from a PR — only a plan. Applying happens
exactly once, on merge to `main`.

## Security choices worth knowing about

- **No long-lived GCP keys anywhere.** GitHub Actions authenticates via
  [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation) —
  GCP trusts GitHub's own OIDC token, scoped to this one repository.
- **SSH has no public listener.** The firewall only allows port 22 from
  Google's [Identity-Aware Proxy](https://cloud.google.com/iap/docs/using-tcp-forwarding)
  range; Ansible reaches the VM through `gcloud compute start-iap-tunnel`,
  authenticated by the same Workload Identity as the rest of the deploy.
- **Shielded VM** (secure boot, vTPM, integrity monitoring) enabled by
  default.
- **The VM has no service account at all.** Nothing running on it ever calls
  a GCP API, so it has zero standing access by construction — not narrowly
  scoped access, none. (This also keeps the deployer identity's own
  permissions smaller: it never needs `iam.serviceAccountAdmin` or
  project-level `setIamPolicy` to stand the VM up.)
- **Runtime secrets never live in this repo.** The Headscale API key and the
  Headplane cookie secret are generated on the box itself on first deploy and
  persisted root-only outside git. The Google OIDC client ID/secret are
  GitHub Secrets, materialized into a gitignored file only inside the CI job
  that needs them.
- **Joining the tailnet requires being on an explicit allowlist.** One Google
  OAuth client backs two separate logins — headscale's own OIDC (a device
  running `tailscale up`) and Headplane's OIDC (you, into `/admin`) — and the
  playbook refuses to deploy at all if `oidc_allowed_users` is empty. Without
  that check, anyone with a Google account could authenticate a device onto
  your VPN.
- **The reverse proxy server's DNS-01 credential never touches the coordination server, or
  vice versa.** `CLOUDFLARE_API_TOKEN` and the Google OIDC secrets are
  written into different jobs' gitignored `group_vars/<group>/secrets.yml`
  files — even though it's one repo, the two machines' secrets stay scoped
  to the job that actually deploys to that machine.
- **The reverse proxy server VM's cert on port 8006 (Proxmox's own UI) never
  gets replaced or exposed further** — it only *fronts* it over the tailnet; nothing
  here opens Proxmox to the public internet.

## Running it yourself

1. Follow [`SETUP.md`](./SETUP.md) once — creates the GCP project, the
   Proxmox API token, the Cloudflare DNS-01 token, the Headscale pre-auth
   keys, and all the GitHub secrets/variables this repo's workflows expect.
2. Open a PR touching `terraform/` to see the plan-comment flow, then merge
   to `main` to deploy both machines.
3. Point `vpn.conway-hash.com`'s DNS A record at the static IP OpenTofu
   creates (shown in the `deploy` workflow's output). The reverse proxy
   server needs no DNS record at all — its names are Headscale MagicDNS,
   not public DNS.
4. To front another home-network device: add one `@matcher`/`handle` block
   to `ansible/roles/reverse_proxy_server_stack/templates/Caddyfile.j2` and redeploy — no
   new cert, no new DNS, the wildcard already covers it.

## Known limitations / possible follow-ups

- Defaults target GCP's **Always Free** tier: `e2-micro` in `us-central1`
  with a 30 GB `pd-standard` disk. That's one free instance per *billing
  account* (not per project), 1 GB RAM (a 2 GB swapfile is provisioned as
  headroom, not a fix), and ~1 GB/month of free egress — a VPN relaying real
  traffic can exceed that. See "Staying inside GCP's Always Free tier" in
  `SETUP.md` before assuming this costs nothing.
- The Headscale API key minted for Headplane expires after 90 days and isn't
  auto-rotated (see "Rotating things" in `SETUP.md`).
- No observability stack (logs/metrics ship nowhere yet beyond what the VM's
  service account permissions allow) — Cloud Logging's Ops Agent would be the
  natural next step.
- No automated backup of `/var/lib/headscale` (the tailnet's state lives only
  on the VM's boot disk).

## License

MIT — see [`LICENSE`](./LICENSE).
