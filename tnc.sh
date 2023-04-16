#!/usr/bin/env bash

source "$1"

/usr/bin/direwolf $DIREWOLF_ARGS 2>&1 | \
/usr/local/bin/sender.sh -a direwolf -p $SOCAT_PORT

