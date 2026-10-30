# Application-Consistent Backup for an InfluxDB VM on Azure

An **Azure Automation runbook** (PowerShell 7.4) that produces an
*application-consistent* backup of a Linux VM running **InfluxDB**, by quiescing the
database and its upstream data pipeline around the snapshot.

> Generalized from a real production task. All subscription names, resource IDs, and
> environment-specific values have been replaced with placeholders.

---

## Why this exists

A VM snapshot taken while a database is actively writing is only **crash-consistent**:
the files on disk are captured mid-write, and on restore the database may need recovery
or, worse, come back with a corrupt dataset. For a time-series database like InfluxDB,
holding a large in-memory state, that risk is real.

To get a clean, reliably restorable point, the database has to be **stopped for the
duration of the snapshot**. In this environment the VM is also fed by a data-ingestion
component ("the feeder") running as a Kubernetes **Deployment on AKS**, which keeps
writing to InfluxDB. Stopping InfluxDB without first pausing the feeder would just pile
up errors upstream. So the two have to be sequenced.

This runbook automates that sequence end to end, on a schedule, with no human in the
loop , and, crucially, **guarantees the environment comes back up even when the backup
fails**.

-

## What it does

```
1. Stop the feeder on AKS      (scale Deployment to 0, wait for pods to terminate)
2. Stop InfluxDB on the VM     (systemctl stop)
3. Back up the VM              (on-demand backup to a Recovery Services vault)
4. Start InfluxDB              (and wait for it to be genuinely active)
5. Start the feeder on AKS     (scale back to the original replica count)
```

Steps **4 and 5 run inside a `finally` block**. Whatever goes wrong in the backup,
InfluxDB and the feeder are brought back up before the runbook exits , the system is
never left in a degraded state. If a restart itself fails, the log prints the exact
manual recovery command.

-

## Architecture

```
  Azure Automation (managed identity)
            │
            │  Connect-AzAccount -Identity
            ▼
   ┌────────────────────┐    Run Command (kubectl)    ┌──────────────────┐
   │   This runbook     │ ──────────────────────────▶ │   AKS cluster    │
   │   (PowerShell 7.4) │        scale 0 / scale N     │   feeder Deploy  │
   └────────┬───────────┘                              └──────────────────┘
            │
            │  Run Command (systemctl)                 ┌──────────────────┐
            ├────────────────────────────────────────▶│   InfluxDB VM    │
            │        stop / start influxdb             └──────────────────┘
            │
            │  Backup-AzRecoveryServicesBackupItem     ┌──────────────────┐
            └────────────────────────────────────────▶│  Recovery Svcs   │
                     on-demand snapshot                │      vault       │
                                                       └──────────────────┘
```

No agent is installed on the VM or the cluster: everything is driven through Azure
**Run Command**, authenticated as the Automation Account's managed identity.

-

## Authentication & permissions

The runbook signs in with the Automation Account's **system-assigned managed
identity** (`Connect-AzAccount -Identity`) , **no secrets, keys, or tokens in code**.

The identity needs these roles, each scoped as tightly as possible:

| Scope | Role | Why |
|---|---|---|
| Recovery Services vault | **Backup Operator** | Trigger the on-demand backup |
| Virtual machine | **Virtual Machine Contributor** (or any role with `.../runCommand/action`) | Run `systemctl` on the VM |
| AKS cluster | **Azure Kubernetes Service Contributor Role** | Use Run Command on the cluster |
| AKS namespace | **Azure Kubernetes Service RBAC Writer** | `get` / `scale` the feeder Deployment |

---

## Configuration

Every environment-specific value is a `param()` placeholder (`<...>`). Set them in the
runbook's parameter defaults, or pass them from the schedule. The script **refuses to
start while any required placeholder is still present**, so a half-configured run can't
touch anything.

| Parameter | Description |
|---|---|
| `SubscriptionId` | Subscription of the VM, vault, and AKS cluster |
| `AksResourceGroup` / `AksClusterName` | AKS cluster hosting the feeder |
| `K8sNamespace` / `DeploymentName` | Namespace and Deployment of the feeder |
| `ManageFeeder` | `$true` = full 5-step flow; `$false` = backup only (AKS params not required) |
| `VaultResourceGroup` / `VaultName` | Recovery Services vault |
| `VmName` | The InfluxDB VM |
| `InfluxService` | systemd service name (default: `influxdb`) |
| `RetentionDays` | Expiry of the on-demand recovery point (see notes below) |

---

## Requirements

- An **Azure Automation Account** with a **PowerShell 7.4** runtime and the **Az** module.
- A VM already **registered for backup** in a Recovery Services vault (the runbook
  triggers on-demand backups on the existing backup item; it does not onboard the VM).
- The managed-identity roles listed above.

---

## Design notes

These are the non-obvious things, written down so they aren't rediscovered the hard way.

- **Run Command hides failures.** Both `Invoke-AzAksRunCommand` and VM Run Command
  report success at the Azure control-plane layer even when the command *inside* the
  target fails. The wrappers inspect the real exit code / output and throw on failure ,
  otherwise a silently failed "stop feeder" would let the backup run against a live
  database, defeating the whole point.

- **The vault enforces a minimum retention.** An on-demand recovery point cannot expire
  sooner than a full day from now. Computing `now + 1 day` and then spending time on the
  earlier steps pushes the effective expiry just *under* that floor, and the vault
  rejects the request. The default is therefore **2 days** for margin. Note that expiry
  alone keeps *approximately* N recent points; to keep *exactly* N, an explicit cleanup
  of the oldest recovery points would be needed.

- **InfluxDB has a slow warm-up.** After a clean stop, InfluxDB rebuilds its in-memory
  cache on start and can stay in systemd state `activating` for **several minutes** on a
  large dataset. The start step polls for up to **15 minutes** before giving up, so the
  feeder is only resumed once the database is truly serving , not the moment the start
  command returns.

- **Azure VM backups are incremental.** The first recovery point is a full; every
  subsequent one transfers only changed blocks. Each point is still **independently
  restorable**, so a short retention (keeping only the latest points) is safe.

---

## Repository

```
.
├── Backup-InfluxVM.ps1   # the runbook
├── README.md             # this file
└── .gitignore            # excludes any file holding real environment values
```

## License

Shared as a reference example. Use at your own risk; review and test in a non-production
environment before adapting to your own setup.
