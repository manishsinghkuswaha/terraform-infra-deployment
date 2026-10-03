# Remote state bootstrap

This root starts with local state because the remote bucket does not exist yet. It creates a private, versioned S3 bucket, blocks public access, enables SSE-KMS, and denies insecure transport. Protect the ignored local state file; it manages the bucket and key.

Review costs and plan before applying. Keep this backend after destroying the dev demo. After apply, run ../scripts/configure-backend.sh from the repository root. To retire the backend later, migrate state, empty all object versions and delete markers, then destroy this root.
