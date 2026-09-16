# Settings: Audit Log

The **Audit Log** tab records changes and the credentials used to make them.

![Settings Audit Log tab](img/settings-audit-log.png)

## Filtering

One select filters entries by resource group:

- VM
- Disk
- Network
- API Key
- SSH Key
- System

## Reading entries

Each row shows:

| Field | Meaning |
|-------|---------|
| Time | When the action happened |
| User | Authenticated principal |
| Action | What was attempted |
| Resource | Which object it hit |
| Auth | Authentication method recorded for the request |

Pair it with [Logs](using-logs.md): audit says who changed what, logs say what happened next inside the system.

## Related

- [Logs](using-logs.md)
- [Settings: API Keys](settings-api-keys.md)
