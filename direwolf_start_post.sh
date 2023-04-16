#!/usr/bin/env bash

source "$1"
# Make sure direwolf is listening on KISS port before declaring victory
/usr/bin/timeout 5 while ! /usr/bin/nc -z 127.0.0.1 $KISS_PORT
do 
	sleep 0.1
done

