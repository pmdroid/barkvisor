#!/bin/bash
# Wrapper script for BarkVisor to ensure runtime directories exist

BARKVISOR_USER="_barkvisor"

# Create runtime directory if it doesn't exist (cleared on reboot)
if [ ! -d /var/run/barkvisor ]; then
    mkdir -p /var/run/barkvisor
    chown $BARKVISOR_USER:$BARKVISOR_USER /var/run/barkvisor
fi

exec /usr/local/bin/barkvisor "$@"
