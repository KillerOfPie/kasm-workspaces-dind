#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

./upgrade.sh || (echo 'Upgrade Failed, attempting install...' && ./install.sh)