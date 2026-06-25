# Testing the scaling

## 1. Validate the pipeline without touching infra

Every script is shellcheck- and `bash -n`-clean. Run the same checks CI runs:

```bash
make lint                 # needs shellcheck
# or:
for f in lib/*.sh scripts/*.sh scripts/**/*.sh; do bash -n "$f"; done
```

`scripts/00-preflight.sh` is the safe end-to-end dry run: it makes **no
changes**, only verifies tooling, `.env`, SSH, storage/bridge, and (if exported)
the Proxmox API token and Kasm health.

## 2. Watch autoscaling on a real node

After `40-configure-autoscale.sh` validates and you've entered the VM Provider +
Autoscale Config in Kasm:

```bash
# Drive demand + observe (needs KASM_API_KEY / KASM_API_KEY_SECRET in .env):
./scripts/test/50-scale-test.sh

# Or just watch the pool while you launch sessions by hand in the Kasm UI:
./scripts/test/50-scale-test.sh --observe
```

What good looks like, with `standby_cores=0`:

```
10:00:01  pool=0   running=0   baseline
10:00:01  pool=0   running=0   sessions requested -> expect pool to grow
10:00:21  pool=1   running=1
10:02:31  pool=1   running=1   sessions expired -> expect scale-down after backoff
10:12:40  pool=0   running=0
```

`pool` = non-template VMs in the autoscale pool; `running` = of those, powered on.
Scale-down lags by `AUTOSCALE_DOWNSCALE_BACKOFF`.

## 3. The five performance questions

See `docs/HORIZON-COMPARISON.md` → "Performance — what to actually test".
`50-scale-test.sh` timestamps cover session-ready time, scale-up latency, and
scale-down. For interactivity/density, drive real workloads and watch node CPU/
RAM/IO (`pvesh get /nodes/<node>/status`, or the Proxmox graphs).

## 4. Reset between runs

```bash
# In Kasm: disable the autoscale config so no new clones spawn, and let any
# running clones drain (or destroy them in the UI). Then:
./scripts/90-teardown.sh        # removes templates/token/pool/role
FORCE=1 ./scripts/90-teardown.sh   # no prompts
```

## 5. CI on self-hosted Forgejo

`.forgejo/workflows/ci.yml` lints + syntax-checks on push/PR. To enable it after
migrating the repo to Forgejo:

1. Install the Forgejo Actions runner and register it against your instance
   (`forgejo-runner register`), label it `ubuntu-latest` (or edit `runs-on`).
2. Enable Actions for the repo (Settings → Actions).
3. Push — the `shellcheck` and `syntax` jobs run automatically.

The workflow is GitHub-Actions-syntax compatible; copy it to
`.github/workflows/ci.yml` if you also want it to run here.

Future idea: a Forgejo runner *on the Proxmox node itself* could run the template
build (`20`/`21`) as a scheduled job, so your golden image is rebuilt and
re-templated automatically whenever you bump `KASM_VERSION` or a base image CVE
lands.
