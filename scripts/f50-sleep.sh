#!/bin/sh
# The static MU300 BusyBox supports fractional waits on this OpenWrt image.
exec /opt/mu300/bin/busybox sleep "$@"
