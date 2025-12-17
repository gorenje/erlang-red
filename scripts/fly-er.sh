#!/usr/bin/env bash
# This script is mostly a very thin wrapper around the flyctl utility
# to launch a new app from this repository
set -e

THIS_SCRIPT=$(basename $0)
FLY_DOCKERFILE="dockerfiles/Dockerfile.fly"

# Make sure they have `fly or try to help them find it.
hash fly 2>/dev/null || {
	echo >&2 "${THIS_SCRIPT} requires the flyctl program in your path as 'fly'."
	echo >&2 "   ...opening web documentation"
	sleep 3
	open "https://fly.io/docs/flyctl/install/"
	exit 1
}

# If they are logged in it will say who they are...
# if not, it will attempt to log them in
echo "=> Ensuring logged in to fly CLI..."
fly auth whoami

# Ask them for an appname.  We cannot easily determine if it
# fits fly naming rules (and is available).. so just take any string
read -p "Provide a fly app name: " APPNAME

read -p "Use basic auth to protect this instance? [yN] " DO_BASIC

if [[ "Y" == ${DO_BASIC}  || "y" == ${DO_BASIC} ]]; then
	# Gather them now, but it needs to be launched before
	# they can be applied.
	# It's only a line below, but it's a relatively long
	# time in the flow of a run.
	read -p "Site user: " ERED_USER
	read -p "Site pass: " ERED_PASS
fi

echo "=> Attempting to launch ${APPNAME}..."
fly launch --name="${APPNAME}" --ha="false" --vm-cpu-kind="shared" --vm-cpus=4 --vm-memory=4096 --dockerfile "${FLY_DOCKERFILE}"

if [[ "Y" == ${DO_BASIC}  || "y" == ${DO_BASIC} ]]; then
	echo "==> Setting secrets for basic auth...";
	# Fly secrets are put into environment variables when
	# the application is started
	echo "   ...user";
	fly secrets set ERED_USER="${ERED_USER}"
	echo "   ...password";
	fly secrets set ERED_PASS="${ERED_PASS}"
fi

# Warn them that the config file might be sort of ephemeral
# in its current location
echo "fly.toml will appear in this directory."
echo "   ...make a copy for safe keeping if desired."
sleep 2
# Try to open the page to the correct place
open "https://${APPNAME}.fly.dev/node-red"

exit 0
