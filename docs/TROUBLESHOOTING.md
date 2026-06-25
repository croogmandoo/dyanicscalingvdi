# Troubleshooting

## Template build (`20`/`21`)

**`import-from` fails / unknown option.** Your Proxmox is older than 7.2. Either
upgrade, or replace the `qm set --scsiN ...,import-from=...` line with the older
two-step flow: `qm importdisk <vmid> <img> <storage>` then attach the resulting
`vm-<vmid>-disk-0`.

**VM never powers off (build times out).** The vendor-data script finishes with
`poweroff`. If it hangs it almost always means **no outbound network** on the
bridge — the VM couldn't reach apt or Docker Hub. Open the Proxmox console for
the VM and check `cloud-init status` / `/var/log/cloud-init-output.log`. Ensure
the bridge has DHCP + internet, then re-run with `--force`.

**`cicustom` vendor snippet not found.** The snippet is written to
`/var/lib/vz/snippets/` and referenced as `local:snippets/...`. The `local`
storage must have the **snippets** content type enabled
(Datacenter → Storage → local → Content → check *Snippets*), or set
`TEMPLATE_SNIPPET_STORAGE`/path to a storage that does.

**SSH key not injected.** `SSH_PUBKEY_FILE` must point at a real `.pub`. It's only
for you to debug the template; clones get their identity from Kasm at provision.

## Proxmox setup / token (`10`, `40`)

**`40-configure-autoscale.sh` says the token request failed.**
- `PROXMOX_API_TOKEN_SECRET` not exported, or wrong (it's shown only once —
  re-mint with `10-proxmox-setup.sh --rotate-token`).
- Self-signed cert: keep `PROXMOX_VERIFY_TLS=false`.
- ACL/role: re-run `10-proxmox-setup.sh`; confirm with
  `pveum user permissions kasm@pve` on the node.

**Kasm clones a VM but the agent never registers.** The classic cause is missing
`qemu-guest-agent` in the template (Kasm can't read the clone's IP). Confirm the
template has it enabled. Also check the clone actually got a DHCP lease on the
bridge/VLAN Kasm is configured for.

**Clone fails with a privilege error.** A privilege is missing from the role.
Privilege names vary by version — read the exact one from the Proxmox task log
(Datacenter → the failed task) and add it to `ROLE_PRIVS` in
`10-proxmox-setup.sh`, then re-run.

## Kasm control plane (`30`)

**Installer download 404.** `KASM_VERSION` doesn't match a published release. Check
Kasm's releases and set a valid version (e.g. `1.16.1`).

**Lost the admin password.** The installer prints it once. Reset it from the Kasm
host with the bundled `kasm_release` admin tooling, or reinstall.

## Scale test (`50`)

**`pool` never moves.** Autoscaling isn't firing. In order: is the Autoscale
Config attached to the deployment zone and enabled? Does `40-configure-autoscale.sh`
pass all four checks? Is the VM Provider's token valid in the Kasm UI?

**Sessions fail to launch via API.** `KASM_API_KEY`/`KASM_API_KEY_SECRET` must be a
valid Developer API key. The script auto-resolves the first image/user; if you
have many, set `TEST_IMAGE_NAME` to the exact friendly name. Use `--observe` and
launch from the UI if the API path is fiddly on your version.

**Scale-down doesn't happen.** It's delayed by `AUTOSCALE_DOWNSCALE_BACKOFF`
(default 600s). Increase `TEST_DURATION_SECONDS` to watch long enough, and make
sure no session is still attached to the agent.

## General

- Re-running any script is safe; existing objects are detected.
- `FORCE=1` skips confirmation prompts (teardown) and `--force` rebuilds
  templates.
- The agent proxy in some environments blocks `kasmweb.com`/`docs.kasm.com`; that
  only affects fetching docs, not the scripts running against your own infra.
