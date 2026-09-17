# Agent policy: Gunny endpoint/IP ownership

This policy is mandatory for automated agents and human operators working on Gunny v389 / DDTank 3.0 endpoint changes.

## Public IP single source of truth

- The production public-IP authority is `C:\Gunny-Infra\server-instance.json` on **DESKTOP-603JII9**, field `publicHost`.
- The versioned schema/apply logic lives in **trinhtanphat/Gunny-Infrastructure**.
- IP/host values found in runtime configs, IIS bindings, database `Server_List`, launcher/web files, `GunnyFileExe`, `DDTank-3.0`, or `BaseGunnyII` are materialized outputs or implementation details. They are **not** an independent migration source of truth.

## Mandatory IP-change procedure

For a public-IP migration, do **not** manually search/replace IP literals across repos or runtime files. On DESKTOP-603JII9 run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Gunny-Infra\Set-GunnyPublicHost.ps1 -PublicHost <NEW_IP>
```

The infra tooling owns backup, propagation, IIS/DB/config updates, listener/HTTP checks, and affected-stack restart behavior.

## Drift handling

If an endpoint still contains an old/wrong public IP:

1. Treat it as **drift or missing infra coverage**, not permission to patch that file directly.
2. Diagnose/re-run the canonical apply path.
3. If the apply engine missed that location, fix **Gunny-Infrastructure** first, add/update contract coverage, then re-apply from the manifest.
4. Never leave a one-off runtime/repo edit that bypasses `publicHost`.

A literal production IP may still appear in backups, snapshots, logs, or generated runtime output. Do not convert those artifacts into a second source of truth.

## Machine roles

- **DESKTOP-PHA1S90**: local/source-data machine; use C:/D:/E: as data sources and launch the client/launcher for user testing. Do not build/deploy Gunny server stacks here.
- **DESKTOP-603JII9**: Gunny build/deploy/runtime server. Production applies and endpoint migrations run here.

## Stack ports

- Gunny v389 / 3.8.9: web 80, game 9200, center 9202, fight 9208.
- DDTank 3.0: web 8083, game 9300, center 9302, fight 9308.

Changing `publicHost` does not imply changing these edition ports.

## Required verification

Before declaring endpoint work complete, run the infrastructure contract tests and verify the canonical apply result. Any new endpoint-bearing location must be brought under the infra apply/test contract instead of being maintained manually.


## Project scope isolation

- A Gunny task may touch only Gunny/DDTank infrastructure, source, runtime, resources, launcher/client-test artifacts, and explicitly named supporting repos.
- Do not mutate unrelated projects such as QS3D, robot-boxing, ping-booster, invoice tooling, or other repositories merely because their worktrees/processes are visible on the same machine.
- In a Gunny conversation, `continue all` means continue all pending work **inside the current Gunny scope** unless the user explicitly names another project.
- Stale/background processes belonging to another project are unrelated machine state; ignore or leave them alone unless they directly block the Gunny task.
