#!/bin/bash
set -e
cd "$(dirname "$0")/../frontend"
npm run build
rm -rf ../Sources/BarkVisor/Resources/frontend
mkdir -p ../Sources/BarkVisor/Resources/frontend
cp -r dist/ ../Sources/BarkVisor/Resources/frontend/dist/
echo "Frontend built and copied to Resources/frontend/dist/"
