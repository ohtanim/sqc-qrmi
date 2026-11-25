#!/bin/bash
set -e

# MUNGE
mkdir -p /run/munge
chown munge:munge /run/munge
runuser -u munge -- /usr/sbin/munged

# sshd on 2222
/usr/sbin/sshd -p 2222

exec "$@"
