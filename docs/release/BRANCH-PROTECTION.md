# Branch Protection Rules & Release Strategy

## Branch Structure

```
main (production)
├── develop (staging)
├── release/v*
└── feature/*
    hotfix/*
    perf/*
```

## Branch Protection Configuration

### `main` Branch (Production)

**Required Settings:**

- ✅ Require pull request before merging
  - Required approvals: 2
  - Dismiss stale reviews: enabled
  - Require review from Code Owners: enabled
  - Require approval of most recent push: enabled
  
- ✅ Require status checks to pass
  - Require branches to be up to date: enabled
  - Required checks:
    - `Lint & Format Check`
    - `Security Scan`
    - `Build (linux-x86_64)`
    - `Build (linux-aarch64)`
    - `Test Suite`
    - `Memory Safety Check`
    - `Container Security Scan`

- ✅ Require conversation resolution before merging

- ✅ Require linear history (no merge commits)

- ✅ Lock branch (only admins can push)

- ⛔ Do not allow bypassing the above settings (including admins)

### `develop` Branch (Staging)

**Required Settings:**

- ✅ Require pull request before merging
  - Required approvals: 1
  - Dismiss stale reviews: enabled
  
- ✅ Require status checks to pass
  - Required checks:
    - `Lint & Format Check`
    - `Security Scan`
    - `Build (linux-x86_64)`
    - `Test Suite`

- ✅ Require conversation resolution before merging

- ✅ Require linear history

### `release/*` Branches

**Required Settings:**

- ✅ Require pull request before merging
  - Required approvals: 2
  - Must include at least one approval from:
    - @maintainers

- ✅ All status checks from `main` branch

- ✅ Require signed commits

- ✅ Lock branch after creation

---

## Pull Request Rules by Type

### Standard Feature PR (`feature/*`)

**Target:** `develop`

**Requirements:**

- 1 approval from any maintainer
- All CI checks pass
- No merge conflicts
- Performance benchmarks run (if touching hot paths)

**Auto-merge:** ✅ Allowed with `automerge` label

### Performance PR (`perf/*`)

**Target:** `develop`

**Requirements:**

- All standard requirements
- Performance benchmarks show improvement OR no regression
- Benchmark results posted in PR

**Auto-merge:** ⛔ Not allowed

### Breaking Change PR

**Target:** `develop`

**Requirements:**

- 2 approvals (1 must be from @maintainers)
- All CI checks pass
- Must include:
  - `!` in PR title (e.g., `feat(core)!: new API`)
  - `breaking-change` label
  - Migration guide in PR description
  - Updated CHANGELOG.md
  - Version bump (major)

**Auto-merge:** ⛔ Not allowed

### Security PR

**Target:** `develop`

**Requirements:**

- 2 approvals (1 must be from @security-team)
- All CI checks pass + security-specific checks
- Security review documented
- CVE documented (if applicable)

**Auto-merge:** ⛔ Not allowed

### Hotfix PR (`hotfix/*`)

**Target:** `main` (directly)

**Requirements:**

- 2 approvals from @maintainers
- All critical CI checks pass
- Includes tests reproducing the issue
- Must be cherry-picked to `develop`

**Auto-merge:** ⛔ Not allowed

### Documentation PR

**Target:** `develop`

**Requirements:**

- 1 approval
- Spelling and link checks pass
- No code changes (docs only)

**Auto-merge:** ✅ Allowed with `automerge` label

---

## Release Strategy

### Versioning Scheme

**Semantic Versioning:** `MAJOR.MINOR.PATCH`

- **MAJOR:** Breaking changes, incompatible API changes
- **MINOR:** New features, backward-compatible
- **PATCH:** Bug fixes, backward-compatible

**Pre-release tags:**

- `v1.2.3-rc.1` - Release candidate
- `v1.2.3-beta.1` - Beta release
- `v1.2.3-alpha.1` - Alpha release

### Release Process

#### 1. Minor/Major Release (from `develop` to `main`)

```bash
# 1. Create release branch
git checkout develop
git pull origin develop
git checkout -b release/v1.2.0

# 2. Update version and changelog
./scripts/release/PUBLISH-RELEASE.sh v1.2.0

# 3. Create PR to main
gh pr create \
  --base main \
  --head release/v1.2.0 \
  --title "Release v1.2.0" \
  --label release

# 4. After approval and merge, tag is created automatically
# 5. CI automatically builds packages and Docker images
# 6. Merge back to develop
git checkout develop
git merge main
git push origin develop
```

#### 2. Patch Release (hotfix)

```bash
# 1. Create hotfix branch from main
git checkout main
git pull origin main
git checkout -b hotfix/v1.2.1

# 2. Fix the bug
# 3. Update version
./scripts/release/PUBLISH-RELEASE.sh v1.2.1

# 4. Create PR to main
gh pr create \
  --base main \
  --head hotfix/v1.2.1 \
  --title "Hotfix v1.2.1: Fix critical memory leak" \
  --label hotfix

# 5. After merge, cherry-pick to develop
git checkout develop
git cherry-pick <hotfix-commits>
git push origin develop
```

#### 3. Release Candidate

```bash
# 1. Tag RC from release branch
git tag -a v1.2.0-rc.1 -m "Release candidate 1.2.0-rc.1"
git push origin v1.2.0-rc.1

# 2. CI builds packages automatically
# 3. Run extensive testing
# 4. If issues found, fix and create rc.2
# 5. If all good, proceed with full release
```

### Release Checklist

**Pre-release:**

- [ ] All tests passing on `develop`
- [ ] No critical/high severity security vulnerabilities
- [ ] Performance benchmarks meet targets
- [ ] CHANGELOG.md updated with all changes
- [ ] Documentation updated
- [ ] Migration guide prepared (if breaking changes)
- [ ] Version bumped in all relevant files
- [ ] Release notes drafted

**Release:**

- [ ] Release branch created
- [ ] PR to `main` created and approved
- [ ] All CI checks pass
- [ ] Tag created
- [ ] GitHub release published
- [ ] .deb package published
- [ ] Docker images published
- [ ] Release notes published

**Post-release:**

- [ ] Merge `main` back to `develop`
- [ ] Close milestone
- [ ] Update roadmap
- [ ] Monitor for issues

---

## CODEOWNERS

```gitignore
# .github/CODEOWNERS

# Global owners
* @holynakamoto/blitz-maintainers

# Core components (require specialized review)
/src/core/ @holynakamoto/core-team
/src/io_uring/ @holynakamoto/performance-team
/src/http/ @holynakamoto/http-team

# Security-critical components
/src/auth/ @holynakamoto/security-team
/src/jwt.zig @holynakamoto/security-team
/src/middleware.zig @holynakamoto/security-team
/src/ratelimit/ @holynakamoto/security-team
/src/ebpf/ @holynakamoto/security-team

# Infrastructure
/.github/ @holynakamoto/ci-team

# Documentation
/docs/ @holynakamoto/docs-team
*.md @holynakamoto/docs-team

# Configuration
packaging/nfpm.yaml @holynakamoto/ops-team
*.toml @holynakamoto/ops-team

# Tests (can be approved by anyone)
/tests/ @holynakamoto/blitz-maintainers

# Build system
build.zig @holynakamoto/build-team
build.zig.zon @holynakamoto/build-team
```

---

## Auto-merge Rules

### Allowed Scenarios

**Label:** `automerge`

**Conditions:**

- PR author is a maintainer OR has 2+ approvals
- All required checks pass
- No `do-not-merge` label
- Not a draft PR
- No breaking changes (no `!` in title)
- Target branch is `develop` (not `main`)
- PR size is small or medium (< 1000 lines)
- No security-critical files changed

### Blocked Scenarios

**Never auto-merge:**

- Breaking changes
- Security-related PRs
- Hotfixes
- Release PRs
- PRs with `do-not-merge` label
- PRs targeting `main` branch
- PRs modifying:
  - `src/auth/**`
  - `src/jwt.zig`
  - `.github/workflows/**`
  - `packaging/nfpm.yaml`

---

## Emergency Procedures

### Critical Production Bug

**Process:**

1. Create hotfix branch from `main`
2. Fix bug with minimal changes
3. Add regression test
4. Fast-track PR review
5. Deploy to staging
6. Run smoke tests
7. Deploy to production
8. Monitor closely
9. Cherry-pick to `develop`

### Rollback Procedure

**Immediate rollback if:**

- Error rate > 1%
- P99 latency > 200µs
- Memory usage > 2GB
- CPU usage > 90%

**Commands:**

```bash
# Previous version from releases
# Revert to previous tag
git tag latest v1.2.0
git push origin -f latest
```

---

## Metrics & SLOs

### CI/CD Performance Targets

- **PR validation time:** < 10 minutes
- **Full CI pipeline:** < 20 minutes
- **Package build time:** < 5 minutes

### Quality Gates

- **Test coverage:** > 80%
- **Security vulnerabilities:** 0 critical/high
- **Performance regression:** < 5%
- **Build success rate:** > 99%

### Review SLAs

- **Standard PR:** 24 hours
- **Urgent PR:** 4 hours
- **Hotfix PR:** 30 minutes
- **Documentation PR:** 48 hours

