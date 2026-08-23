# homelab-vpn-kit

OpenTofu + Ansible, running from GitHub Actions, that stand up a small GCP
VM running a self-hosted [Tailscale](https://tailscale.com)-compatible
coordination server ([Headscale](https://github.com/juanfont/headscale)
behind [Caddy](https://caddyserver.com), with
[Headplane](https://github.com/tale/headplane) as the admin UI).

- Coordination server: `https://vpn.conway-hash.com`
- Tailnet device names (MagicDNS): `*.ts.conway-hash.com`

Fronting individual home-network devices with their own reverse proxy (e.g.
Caddy on that device itself) is left to each device, added as needed — not
built into this repo. A single shared reverse-proxy machine was tried and
retired: it meant a DNS-01 credential and a wildcard cert living on a third
box for a "nice URL" nobody was blocked on, when every device is already
directly reachable over the tailnet by its own MagicDNS name.

## Using this as a template

This is the author's own real, running config — `conway-hash.com` and its
subdomains are genuine, not placeholders, and left in place deliberately
(a real worked example beats a sterile one). "Use this template" copies
files byte-for-byte, though — nothing here auto-substitutes your domain.
Before deploying your own copy:

- `ansible/group_vars/coordination_server/vars.yml` — `tailnet_base_domain`,
  `headscale_server_url`, `acme_email`

That's the whole list — all three live in the one file, and each is marked
`# <-- change this` on the line above it. There's deliberately nothing to
change in `coordination_server/vars.yml`: it holds only per-machine values
(paths, version pins), and `domain` isn't declared at all — it's derived
from `headscale_server_url`, since they're the same fact in two forms. Skip
the edits above and your deploy will think it's serving `conway-hash.com`'s
tailnet, not yours. [`SETUP.md`](./SETUP.md) walks through the rest (GCP
project, secrets) with `export`-style placeholders you fill in as you go.

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
```

How that gets built and deployed (OpenTofu, then which Ansible job, over
which connection) is in the ["How CI/CD works"](#how-cicd-works) table
below.

Everything above the VM boundary is provisioned by OpenTofu; everything
inside the VM is configured by Ansible. Neither is ever run by hand against
production — both run from GitHub Actions.

## Repo layout

```
terraform/
  gcp.tf                the coordination server: VPC, firewall, static IP, the VM
  providers.tf/versions.tf/variables.tf/outputs.tf   the google provider, one GCS backend
ansible/
  site.yml              entrypoint — one play
  group_vars/
    coordination_server/   tailnet_base_domain, headscale_server_url, acme_email, stack_dir, headscale/headplane/caddy version pins (domain is derived, not declared)
  roles/
    docker/                installs Docker Engine + Compose plugin
    coordination_server_stack/     Caddyfile, docker-compose.yml, headscale + headplane configs
.github/workflows/
  terraform-plan.yml     PR check: tofu fmt/validate/plan, posted as a PR comment
  deploy.yml             on merge to main: tofu apply, then the Ansible deploy job
  ansible-lint.yml       PR check: ansible-lint against site.yml
SETUP.md               one-time bootstrap: GCP + secrets — run once by hand
renovate.json          dependency updates: GitHub Actions, the terraform provider,
                       Ansible Galaxy collections, and the pinned headscale/headplane/
                       caddy image versions (see below)
```

## Keeping dependencies current

[Renovate](https://github.com/apps/renovate) (not installed by default — add
it to this repo from the GitHub Marketplace to activate `renovate.json`)
opens PRs for:

- GitHub Actions versions used in `.github/workflows/`
- the `google` provider constraint in `terraform/versions.tf`
- the Ansible Galaxy collections in `ansible/requirements.yml`
- the `headscale_version` / `headplane_version` / `caddy_version` pins in
  `ansible/group_vars/coordination_server/vars.yml` (read via a custom
  regex rule, since the actual `docker-compose.yml` file is a Jinja
  template Renovate can't parse directly)

GitHub's own Dependabot security alerts and automated security fixes are
also on for this repo — that's independent of Renovate and needs no config
file; see repo Settings → Code security.

## How CI/CD works

| Trigger | What runs |
|---|---|
| PR touching `terraform/**` | `tofu fmt -check`, `tofu validate`, `tofu plan` — posted as a PR comment, nothing is applied |
| PR touching `ansible/**` | `ansible-lint` against `site.yml` |
| Push to `main` | `tofu apply`, then the Ansible deploy job (`--limit coordination_server`) over an IAP tunnel |
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

## Running it yourself

1. Follow [`SETUP.md`](./SETUP.md) once — creates the GCP project, the
   Headscale OIDC client, and all the GitHub secrets/variables this repo's
   workflows expect.
2. Open a PR touching `terraform/` to see the plan-comment flow, then merge
   to `main` to deploy.
3. Point `vpn.conway-hash.com`'s DNS A record at the static IP OpenTofu
   creates (shown in the `deploy` workflow's output).

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
