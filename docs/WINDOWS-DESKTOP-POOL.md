# Windows desktop pool (Horizon-style)

The closest analog to an Omnissa Horizon instant-clone Windows pool: Kasm clones
a **full Windows VM** per user from a Proxmox template and brokers the desktop
over **RDP**. This is heavier than the Docker-agent pool but it's what most
Horizon estates actually run.

> The Proxmox prep (`10-proxmox-setup.sh`: role, token, pool) is identical to the
> Linux paths. Only the template differs — and Windows can't be cloud-init'd, so
> the build is semi-automated.

## The shape of it

```
Windows ISO  ─┐
virtio-win  ──┤  22-build-windows-template.sh           sysprep /generalize
answer ISO  ──┘     │ creates VM (OVMF+TPM+virtio)            │
   (autounattend +  │ unattended install                     ▼
    bootstrap.ps1 + │ bootstrap.ps1: virtio guest agent,   --finalize:
    cloudbase cfg)  │ Cloudbase-Init, enable RDP           detach ISOs, add
                    ▼                                       cloud-init drive,
              Windows desktop, ready ───────────────────►  qm template
                                                                │
                              Kasm Server-pool autoscale config ▼
                              clones template → reads IP via guest agent →
                              brokers RDP (3389) → destroys on idle backoff
```

## Why each piece exists

| Piece | Why |
|-------|-----|
| **OVMF (UEFI) + TPM 2.0** | Windows 11 requires both. `win10`/server can skip TPM. |
| **virtio-scsi + NetKVM** | Paravirtualized disk/NIC for performance; drivers injected during Setup from the virtio-win ISO. |
| **qemu-guest-agent** | Kasm/Proxmox read the clone's IP and lifecycle through it. **Without it the clone never registers.** |
| **autounattend.xml** | Zero-touch Windows Setup: partitions, account, OOBE skip, RDP, runs bootstrap. |
| **bootstrap.ps1** | First-logon: installs guest agent + Cloudbase-Init, hardens RDP. |
| **Cloudbase-Init** | The Windows cloud-init — gives each clone a unique hostname/SID and reads per-provision config from the Proxmox cloud-init drive. |
| **sysprep /generalize** | Strips the machine SID so clones aren't duplicates on the domain/network. |

## Prerequisites

1. A **Windows ISO** you're licensed for, and the **virtio-win ISO**
   (https://fedorapeople.org/groups/virt/virtio-win/). Upload both to the node's
   ISO storage (`Datacenter → storage → ISO Images → Upload`, or scp into
   `/var/lib/vz/template/iso/`).
2. An ISO builder on the node: `apt-get install -y genisoimage`.
3. `.env` filled in — the `WIN_*` block (VMID, ISO names, admin user/password,
   ostype, edition, locale, timezone).

## Build it

```bash
# 1. Build phase: render answer file, build answer ISO, create + start the VM
./scripts/proxmox/22-build-windows-template.sh
#    (--force to rebuild an existing VMID)

# 2. Watch the Proxmox console. Windows installs unattended, then bootstrap.ps1
#    runs. Confirm when it's at the desktop:
#      - services.msc -> "QEMU Guest Agent" is Running
#      - C:\kasm-bootstrap.log ends with "Bootstrap complete"

# 3. Seal it: generalize + shut down from inside the VM
#      cd "C:\Windows\System32\Sysprep"
#      .\sysprep.exe /generalize /oobe /shutdown ^
#         /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"

# 4. Finalize: detach ISOs, add cloud-init drive, convert to template
./scripts/proxmox/22-build-windows-template.sh --finalize
```

## Wire up Kasm (Server-pool autoscale)

In the Kasm admin UI (labels vary slightly by version — match by meaning):

1. **VM Provider** — the same Proxmox provider from `40-configure-autoscale.sh`
   (or add one). It needs the token, node, pool, storage, bridge.
2. **Autoscale Config** → type **Server**:
   - VM Provider: the Proxmox one
   - Template / VMID: `WIN_TEMPLATE_VMID` (9002 by default)
   - Connection type: **RDP**, port **3389**
   - Credentials: `WIN_ADMIN_USER` / its password (or inject per-provision via
     Cloudbase-Init)
   - Standby / max servers, downscale backoff: as in `.env`
3. Attach the config to your deployment zone, then launch a session — Kasm clones
   the template, waits for the guest agent to report an IP, and connects over RDP.

Watch it scale with the same tool as the Linux pools:

```bash
./scripts/test/50-scale-test.sh --observe   # then launch sessions from the UI
```

## Security notes

- `autounattend.xml` and the auto-logon store the admin password **in plaintext**
  on the answer ISO and briefly in the registry. Use a throwaway
  `WIN_ADMIN_PASSWORD`, and rotate it (or inject per-clone via Cloudbase-Init)
  after the template is built. Delete the answer ISO from the node afterwards:
  `rm /var/lib/vz/template/iso/kasm-win-answer-9002.iso`.
- For domain-joined desktops, add the join in Cloudbase-Init user-data or a
  bootstrap step, and store credentials in a secret store, not the image.

## Performance vs. Horizon, specifically for Windows

This is where Horizon's Blast/PCoIP lead is most visible (codec tuning, USB/RTAV,
multi-monitor over WAN). On a LAN with modern RDP (RemoteFX/AVC444), Kasm-brokered
Windows desktops feel good for office/dev work. Benchmark the five metrics in
`docs/HORIZON-COMPARISON.md` against your actual apps before committing — the
clone speed (step "scale-up latency") depends heavily on your Proxmox storage
(ZFS/Ceph/LVM-thin) and whether linked clones are available.
