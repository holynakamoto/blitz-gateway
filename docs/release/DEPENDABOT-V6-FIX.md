# Fixing docker/build-push-action@v6 Compatibility

## The Problem

When Dependabot upgrades `docker/build-push-action` from v5 to v6, it creates PRs that fail CI because:

1. **v6 requires new permissions** that weren't needed in v5
2. **v6 enables build summaries by default**, which needs additional permissions
3. Dependabot only updates the version number, not the workflow configuration

## The Solution

### Option 1: Add Required Permissions (Recommended)

Update your workflow to include the required permissions:

```yaml
jobs:
  container:
    permissions:
      contents: read      # Already required
      packages: write     # Already required
      attestations: write # NEW: Required for v6 provenance/SBOM
      id-token: write     # NEW: Required for OIDC authentication
```

### Option 2: Disable Build Summary (Simpler)

If you don't need the new build summary feature, disable it:

```yaml
- name: Build and push
  uses: docker/build-push-action@v6
  env:
    DOCKER_BUILD_SUMMARY: "false"  # Disables new v6 feature
  with:
    # ... your existing config
```

### Option 3: Both (Best Practice)

Combine both approaches for full compatibility:

```yaml
jobs:
  container:
    permissions:
      contents: read
      packages: write
      attestations: write
      id-token: write
    steps:
      - name: Build and push
        uses: docker/build-push-action@v6
        env:
          DOCKER_BUILD_SUMMARY: "false"
        with:
          # ... your config
```

## What We Did

We updated `.github/workflows/ci-cd.yml` to:
- ✅ Upgrade to `docker/build-push-action@v6`
- ✅ Add `attestations: write` and `id-token: write` permissions
- ✅ Disable build summary to avoid permission overhead

## Future Prevention

When Dependabot opens PRs for major version bumps:

1. Check the action's release notes for breaking changes
2. Update permissions as needed
3. Test the workflow before merging
4. Consider manual review for major version bumps

## References

- [docker/build-push-action v6 release notes](https://github.com/docker/build-push-action/releases/tag/v6.0.0)
- [GitHub Actions permissions](https://docs.github.com/en/actions/security-guides/automatic-token-authentication#permissions-for-the-github_token)

