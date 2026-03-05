# valkey — In-Memory Cache

Valkey is a BSD 3-Clause licensed in-memory data store, maintained by the Linux Foundation. It is a drop-in replacement for Redis.

## Auto-Dependency

Valkey is automatically enabled when you enable modules that require it:

- **sso** — session and cache backend (when available)

## Enable / Disable

```bash
./module.sh enable valkey
./module.sh disable valkey
```

Valkey cannot be disabled while modules that depend on it are active.

## Data

Persistence directory: `data/valkey/`
