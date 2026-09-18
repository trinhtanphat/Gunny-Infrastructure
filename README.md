# Gunny Infrastructure

Single-source endpoint management for the two Windows game stacks on one host:

- Gunny legacy **v389 family / 3.8.9**: web 80, game 9200, center 9202, fight 9208. The client content patch chain is forward-moving and must remain at version 389 or newer (currently v391).
- DDTank **3.0**: web 8083, game 9300, center 9302, fight 9308.

## One server: change the IP in one place

The live manifest is `C:\Gunny-Infra\server-instance.json`. Only `publicHost` changes when the public IPv4 address changes; edition ports stay in the same manifest.

Apply/verify the current manifest:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Gunny-Infra\Apply-AllGunnyInstances.ps1 -Apply
```

Change the public IP and apply both stacks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Gunny-Infra\Set-GunnyPublicHost.ps1 -PublicHost <NEW_IP>
```

The new IPv4 address must already be assigned to the server NIC. A changed host restarts only the affected stack by default. Each apply backs up managed runtime files, DB `Server_List` rows and IIS bindings before mutation, then verifies config, DB, IIS, listeners, HTTP endpoints and v389 client version.

## Fleet / 100 servers

Copy `fleet.example.json` to `fleet.json` and keep every server's `computerName` and `publicHost` in that one inventory. Runtime manifests are generated from `server-instance.example.json`; credentials are never stored in inventory.

Dry-run the entire fleet without contacting remote hosts:

```powershell
.\Deploy-GunnyFleet.ps1 -InventoryPath .\fleet.json
```

Sync the bundle/manifests over PowerShell Remoting and apply all enabled nodes:

```powershell
.\Deploy-GunnyFleet.ps1 -InventoryPath .\fleet.json -Apply
```

Use `-Credential (Get-Credential)` if current Windows credentials cannot authenticate to the remote servers. WinRM/PowerShell Remoting must already be allowed between the management host and the target servers.

## Repository safety

Production `server-instance.json`, `fleet.json`, backups and logs are gitignored. The committed examples use RFC 5737 TEST-NET addresses. The `lib` directory contains the versioned endpoint apply engines, so the bundle does not depend on a `_recover` worktree or a particular Git checkout path on production servers.

## Agent / automation endpoint rule

Automated agents must read the root `AGENTS.md` before changing any Gunny/DDTank endpoint. Public-IP migration is manifest-driven only: `server-instance.json -> publicHost -> Set-GunnyPublicHost.ps1`. Direct cross-repository/runtime search-replace of production IPs is prohibited. If a location is not covered, extend the infrastructure apply/test contract first and then re-apply from the manifest.
