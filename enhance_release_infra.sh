#!/usr/bin/env bash
set -e

ROOT="$(pwd)"
echo "Enhancing project release & CI infra in $ROOT..."

# --- 1) standard-version configuration
cat > .versionrc.json << 'EOF'
{
  "types": [
    { "type": "feat", "section": "Features" },
    { "type": "fix", "section": "Bug Fixes" },
    { "type": "perf", "section": "Performance Improvements" },
    { "type": "revert", "section": "Reverts" },
    { "type": "docs", "section": "Documentation" },
    { "type": "style", "hidden": true },
    { "type": "refactor", "section": "Refactors" },
    { "type": "test", "hidden": true }
  ],
  "ignore": ["chore", "ci"]
}
EOF

echo "Created .versionrc.json (standard-version changelog grouping)."

# --- 2) Commitizen config + npm scripts
npm install --save-dev commitizen cz-conventional-changelog --save-exact

# Add config section to package.json (commitizen adapter)
npx npm-add-script -k "commit" -v "cz"
jq '.config.commitizen={"path":"cz-conventional-changelog"}' package.json > package.tmp.json
mv package.tmp.json package.json

echo "Configured Commitizen and added 'commit' script."

# --- 3) Slither GitHub Actions workflow
mkdir -p .github/workflows
cat > .github/workflows/slither-analysis.yml << 'EOF'
name: Slither Static Analysis

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["main"]

jobs:
  slither:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Slither analysis
        uses: crytic/slither-action@v0.4.1
        with:
          node-version: 18
          sarif: results.sarif
          fail-on: none
          slither-config: slither.config.json

      - name: Upload SARIF report
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
EOF

echo "Added Slither GitHub Action (CI)."

# --- 4) Slither baseline config
cat > slither.config.json << 'EOF'
{
  "solc-remaps": ["@openzeppelin/=lib/openzeppelin-contracts/"],
  "exclude": ["node_modules", "test", "scripts"],
  "just-version": false,
  "severity": {
    "low": true,
    "medium": true,
    "high": true
  },
  "detectors": {
    "reentrancy-vulnerabilities": true,
    "unused-return-values": true
  }
}
EOF

echo "Created slither.config.json (baseline config)."

# --- 5) Optional .czrc file for commitizen
cat > .czrc << 'EOF'
{
  "path": "cz-conventional-changelog"
}
EOF

echo "Created .czrc (commitizen adapter)."

echo "Enhancements applied. Run 'npm install' and then: "
echo "  npm run commit"
echo "  npm run release   # or 'standard-version'"
echo "Review .github/workflows/slither-analysis.yml and commit!"
