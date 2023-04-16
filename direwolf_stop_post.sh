#!/usr/bin/env bash

source "$1"

echo 'stopped.' | /usr/local/bin/sender.sh -a direwolf -p $SOCAT_PORT
