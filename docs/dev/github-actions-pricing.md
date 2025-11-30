# GitHub Actions Pricing Guide

## 💰 Overage Rates for Private Repositories

### Per-Minute Rates (GitHub-Hosted Runners)

| Operating System | Rate per Minute | Multiplier |
|------------------|-----------------|------------|
| **Linux** | $0.008 | 1x |
| **Windows** | $0.016 | 2x |
| **macOS** (Intel) | $0.08 | 10x |
| **macOS** (M1/M2) | $0.08 | 10x |

### Free Tier Limits

| Plan | Free Minutes/Month | Free Storage |
|------|-------------------|--------------|
| **GitHub Free** | 2,000 | 500 MB |
| **GitHub Team** | 3,000 | 2 GB |
| **GitHub Enterprise** | 50,000 | 50 GB |

## 📊 Cost Calculation Example

For GitHub Free plan (2,000 free minutes):

- 1,500 minutes on Linux → **$0.00** (free)
- 800 minutes on Windows → **$12.80** (800 × $0.016)
- 200 minutes on macOS → **$16.00** (200 × $0.08)

**Total Cost**: $28.80/month

## 🛑 Spending Controls

### Setting Spending Limits:
1. Repository Settings → Billing & plans
2. Set 'Monthly spending limit' to $0 for Actions
3. Workflows stop when quota is exhausted

### Default Behavior:
- **No limit set**: Continues running and bills account
- **Limit = $0**: Workflows disabled when quota reached

## 💡 Cost Optimization for Blitz Gateway

### Recommended Strategies:

1. **Linux-Only Runners** - Server code tests perfectly on Linux
2. **Zero Spending Limit** - Prevents unexpected charges
3. **Optimized Triggers** - Use `paths:` and `paths-ignore:` filters
4. **Dependency Caching** - Cache Zig builds and dependencies
5. **Selective Testing** - Full suite only on main/develop branches

### Estimated Monthly Cost:
**$0-50/month** for active development (Linux runners only)

## 📈 Monitoring Usage

- **Location**: Repository Settings → Billing & plans → Actions
- **Data**: Current month usage, costs, and historical trends
- **Alerts**: Configurable spending notifications

## 🎯 Blitz Gateway Specifics

### Workflow Optimization:
```yaml
on:
  push:
    branches: [main, develop]
    paths:
      - 'src/**'
      - 'build.zig'
      - '!docs/**'
      - '!README.md'
```

### Self-Hosted Runner Option:
For performance benchmarking, consider self-hosted runners on dedicated hardware - **0 cost for Actions minutes**, only infrastructure costs.

## 🔗 Additional Resources

- [GitHub Actions Pricing](https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions)
- [Cost Optimization](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#usage-limits)
- [Self-Hosted Runners](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners)
