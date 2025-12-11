#!/bin/bash
# Setup script for flash-arb-template

set -e

echo "🚀 Setting up Flash Arbitrage Template..."

# Check if Foundry is installed
if ! command -v forge &> /dev/null; then
    echo "⚠️  Foundry not found. Installing..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
else
    echo "✅ Foundry is installed"
    forge --version
fi

# Check if .env file exists
if [ ! -f .env ]; then
    echo "📝 Creating .env file from .env.example..."
    cp .env.example .env
    echo "⚠️  Please update .env with your RPC_URL before running tests"
else
    echo "✅ .env file exists"
fi

# Install dependencies
echo "📦 Installing dependencies..."
forge install foundry-rs/forge-std --no-commit 2>/dev/null || echo "forge-std already installed"

# Build the project
echo "🔨 Building contracts..."
forge build

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Update .env file with your RPC_URL"
echo "2. Run tests: forge test --fork-url \$RPC_URL -vv"
echo "3. See README.md for more information"
