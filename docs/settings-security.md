# Settings: Security

Open **Settings → Security** to choose when this Device requires sign-in.

| Option | Who can use the console |
|--------|-------------------------|
| **Require sign-in** | Users who sign in. This is the default. |
| **Skip sign-in on this computer** | Direct local browser connections get access without signing in. Network connections still require sign-in. |
| **Skip sign-in for my whole network** | Anyone who can reach this Device gets full control. |

Turning off sign-in for the whole network asks you to type the Device name to confirm. That access includes starting, stopping, and deleting workloads.

Passkeys and API Keys are hidden for a session that skips sign-in. They return when sign-in is required again.

If you use a reverse proxy, keep **Require sign-in** enabled. Local-only bypass is intended for a browser connecting directly on the same computer.

If the service has `BARKVISOR_AUTH_MODE` set, the page explains that the environment setting overrides the UI. An administrator must change the service configuration to unlock these choices.

## Related

- [Passkeys](settings-passkeys.md)
- [API Keys](settings-api-keys.md)
- [First launch](getting-started-first-launch.md)
