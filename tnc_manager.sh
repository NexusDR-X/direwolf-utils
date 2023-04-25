#!/bin/bash
#================================================================
# HEADER
#================================================================
#% SYNOPSIS
#+   ${SCRIPT_NAME} [-hv]
#%
#% DESCRIPTION
#%   This script provides a GUI to manage pat and 
#%   Direwolf and ARDOP software TNCs.  It is designed to work 
#%   on the Nexus DR-X.
#%
#% OPTIONS
#%    -h, --help                  Print this help
#%    -v, --version               Print script information
#%
#================================================================
#- IMPLEMENTATION
#-    version         ${SCRIPT_NAME} 2.0.5
#-    author          Steve Magnuson, AG7GN
#-    license         GPL 3.0
#-    script_id       0
#-
#================================================================
#  HISTORY
#     20220822 : Steve Magnuson : Script creation.
# 
#================================================================
#  DEBUG OPTION
#    set -n  # Uncomment to check your syntax, without execution.
#    set -x  # Uncomment to debug this shell script
#
#================================================================
# END_OF_HEADER
#================================================================

SYNTAX=false
DEBUG=false
Optnum=$#

#============================
#  FUNCTIONS
#============================

function KillApps () {
	for APP in pat ardop rigctldvcom rigctld
	do
		systemctl --user stop $(systemd-escape --template $APP@.service "$ARGS_CONFIG") 2>/dev/null
	done
	systemctl --user stop $(systemd-escape --template tnc@.target "$ARGS_CONFIG") 2>/dev/null
	unset SOCAT_PORT
	unset ARGS_CONFIG
	unset VIRTUAL_COM
	unset RIGCTL_PTT_ON
	unset RIGCTL_PTT_OFF
	unset EDITOR
	unset AX25PORTFILE
	unset PAT_CONFIG
	unset DW_CONFIG
	unset setAX25Defaults 
	unset setDirewolfDefaults 
	unset setARDOPDefaults
	unset loadARDOPDefaults
	unset loadAX25Defaults 
	unset loadDirewolfDefaults 
	unset updateAX25Settings 
	unset updateAxports
	unset updateARDOPSettings 
	unset updateDirewolfSettings 
	unset updateStartupSettings 
	unset makeDirewolfConfig 
	unset updateRigctldSettings
	unset editPatPassword 
	unset updatePatSettings 
	unset Sender 
	unset restart 
	unset startStop
	unset argModify
	unset click_help_cmd
	unset save_startup_settings_cmd
	unset load_ax25_defaults_cmd
	unset save_ax25_settings_cmd
	unset save_ardop_settings_cmd
	unset save_direwolf_settings_cmd
	unset save_pat_settings_cmd
	unset GUI_STARTUP_CONFIG_FILE
	unset GUI_DIREWOLF_CONFIG_FILE
	unset GUI_ARDOP_CONFIG_FILE
	unset GUI_AX25_CONFIG_FILE
	unset GUI_RIGCTLD_CONFIG_FILE
	unset GUI_PAT_CONFIG_FILE
}

function SafeExit() {
   trap - INT TERM EXIT SIGINT
	EXIT_CODE=${1:-0}
   kill $MANAGER_PID >/dev/null 2>&1
	KillApps
	[[ -d "${TMPDIR}" ]] && rm -r "${TMPDIR}"
	unset TMPDIR
	kill $MONITOR_PID >/dev/null 2>&1
   exit $EXIT_CODE
}

function ScriptInfo() { 
	HEAD_FILTER="^#-"
	[[ "$1" = "usage" ]] && HEAD_FILTER="^#+"
	[[ "$1" = "full" ]] && HEAD_FILTER="^#[%+]"
	[[ "$1" = "version" ]] && HEAD_FILTER="^#-"
	head -${SCRIPT_HEADSIZE:-99} ${0} | grep -e "${HEAD_FILTER}" | \
	sed -e "s/${HEAD_FILTER}//g" \
	    -e "s/\${SCRIPT_NAME}/${SCRIPT_NAME}/g" \
	    -e "s/\${SPEED}/${SPEED}/g" \
	    -e "s/\${DEFAULT_PORTSTRING}/${DEFAULT_PORTSTRING}/g"
}

function Usage() { 
	printf "Usage: "
	ScriptInfo usage
	exit
}

function Die () {
	echo "${*}"
	SafeExit 1
}

function argModify () {
   local ARG=$(echo $@ | cut -d '=' -f1)
   grep -v "^${ARG}" $ARGS_CONFIG | sponge $ARGS_CONFIG
   cat >> $ARGS_CONFIG <<EOF
$@
EOF
}

function Sender () {
	# Data piped to this function is sent to a socat pipe, prepended by the 
	# app name (optional) and a time stamp
	# To monitor received data, run: socat -u udp-recv:$SOCAT_PORT,reuseaddr -
   declare APP="${1:-}"
   TIME_FORMAT="%Y/%m/%d %H:%M:%S"
   [[ -n $APP ]] && APP=" ${APP}:"
   stdbuf -oL ts "${TIME_FORMAT}${APP}" | socat - udp-sendto:127.255.255.255:$SOCAT_PORT,broadcast 
}

function getPlaybackDevices () {
	if pgrep pulseaudio >/dev/null 2>&1
   then # There may be pulseaudio ALSA devices.  Look for them.
      PLAYBACK_IGNORE="$(pacmd list-sources 2>/dev/null | grep name: | tr -d '\t' | cut -d' ' -f2 | sed 's/^<//;s/>$//' | tr '\n' '|' | sed 's/|/\\|/g')"
      PLAYBACKs="$(aplay -L | egrep -v "$PLAYBACK_IGNORE^ .*|^dshare|^sys|^default|^dmix|^hw|^hdmi|^usbstream|^jack|^pulse|^upmix|^vdownmix|^oss\|^speexrate\|^samplerate\|^surround\|^front\|^lavrate|^ .*" | tr '\n' '!' | sed 's/!$//')"
   else  # pulseaudio isn't running.  Check only for null and plughw devices
      PLAYBACKs="$(aplay -L | grep "^null\|^plughw\|^fepi" | tr '\n' '!' | sed 's/!$//')"
   fi
   echo "$PLAYBACKs"
}

function getCaptureDevices () {
	if pgrep pulseaudio >/dev/null 2>&1
   then # There may be pulseaudio ALSA devices.  Look for them.
      CAPTURE_IGNORE="$(pacmd list-sinks 2>/dev/null | grep name: | tr -d '\t' | cut -d' ' -f2 | sed 's/^<//;s/>$//' | tr '\n' '|' | sed 's/|/\\|/g')"
      CAPTUREs="$(arecord -L | egrep -v "$CAPTURE_IGNORE^ .*|^dsnoop|^sys|^default|^hw|^hdmi|^usbstream|^jack|^pulse|^ .*" | tr '\n' '!' | sed 's/!$//')"
   else  # pulseaudio isn't running.  Check only for null and plughw devices
      CAPTUREs="$(arecord -L | grep "^null\|^plughw\|^fepi" | tr '\n' '!' | sed 's/!$//')"
   fi
   echo "$CAPTUREs"
}

function restart () {
	case $1 in
		ardop)
			if grep -q "^PIARDOPC_ARGS=.*--cat" $ARGS_CONFIG 2>/dev/null
			then
				if pgrep -f "rigctld.*-m 4" >/dev/null 2>&1
				then
					#restart rigctld
					restart rigctldvcom
				else
					echo "ERROR! rigctld rig must be '4' (Flrig). ARDOP PTT disabled." | Sender "ardop"
				fi	
			fi
			systemctl --user stop $(systemd-escape --template ${1}@.service "$ARGS_CONFIG")
			sleep 1
			systemctl --user start $(systemd-escape --template ${1}@.service "$ARGS_CONFIG")	 
			;;
		tnc)
			systemctl --user stop $(systemd-escape --template tnc@.target "$ARGS_CONFIG")
			sleep 1
			systemctl --user start $(systemd-escape --template tnc@.target "$ARGS_CONFIG")	 
			;;
		*)
			systemctl --user stop $(systemd-escape --template ${1}@.service "$ARGS_CONFIG")
			sleep 1
			systemctl --user start $(systemd-escape --template ${1}@.service "$ARGS_CONFIG")	 
			;;
	esac
}

function startStop () {
	[[ -z $1 ]] && return 1
	local TEXT=""
	local BTN_TEXT=""
	local TYPE=""
	local CMD=""
	local NAME=""
	case $1 in
		tnc)
			TYPE='target'
			STATE="$(systemctl --user show -p SubState --value $(systemd-escape \
			--template ${1}@.$TYPE "$ARGS_CONFIG"))"
			NAME="TNC (Direwolf+AX25)"
			if [[ $STATE == "active" && \
			$(systemctl --user show -p SubState --value $(systemd-escape \
			--template direwolf@.service "$ARGS_CONFIG")) == "running" ]]
			then
				TEXT="is running"
				CMD="stop"
			else
				TEXT="is not running"
				CMD="start"
			fi
			;;
		pat|ardop)
			TYPE='service'
			STATE="$(systemctl --user show -p SubState --value $(systemd-escape \
			--template ${1}@.$TYPE "$ARGS_CONFIG"))"
			if [[ $STATE == "running" ]]
			then
				TEXT="is running"
				CMD="stop"
			else
				TEXT="is not running"
				CMD="start"
			fi
			case $1 in
				pat)
					NAME="PAT"
					;;
				ardop)
					NAME="ARDOP"
					;;
			esac
			;;
	esac
	BTN_TEXT="${CMD^} ${1^^}"
#	if systemctl --user is-active --quiet $(systemd-escape --template ${1}@.$TYPE "$ARGS_CONFIG")
	if [[ $CMD == "start" ]]
	then
   	yad --info \
   		--on-top \
   		--title="$NAME" \
   		--text-align=center \
   		--buttons-layout=center \
   		--borders=5 \
   		--text="<b><span color='blue'>${NAME}</span><span color='red'> $TEXT</span></b>" \
   		--button="<b>Cancel</b>":0 \
   		--button="<b>$BTN_TEXT</b>":1
	else
   	yad --info \
   		--on-top \
   		--title="$NAME" \
   		--text-align=center \
   		--buttons-layout=center \
   		--borders=5 \
   		--text="<b><span color='blue'>${NAME}</span><span color='green'> $TEXT</span></b>" \
   		--button="<b>Cancel</b>":0 \
   		--button="<b>$BTN_TEXT</b>":1 \
   		--button="<b>Restart ${1^^}</b>":2
	fi
	case $? in
		1)
			systemctl --user $CMD $(systemd-escape --template ${1}@.$TYPE "$ARGS_CONFIG")
			RESULT=$?
			if [[ $1 == "tnc" && $CMD == "start" && $(systemctl --user show -p SubState \
				--value $(systemd-escape \
				--template direwolf@.service "$ARGS_CONFIG")) != "running" ]]
			then
				systemctl --user start $(systemd-escape --template ${1}@.$TYPE "$ARGS_CONFIG")
				RESULT=$?
			fi
			return $RESULT
			;;
		2)
			systemctl --user stop $(systemd-escape --template ${1}@.$TYPE "$ARGS_CONFIG")
			systemctl --user start $(systemd-escape --template ${1}@.$TYPE "$ARGS_CONFIG")
			RESULT=$?
			if [[ $1 == "tnc" && $(systemctl --user show -p SubState \
				--value $(systemd-escape \
				--template direwolf@.service "$ARGS_CONFIG")) != "running" ]]
			then
				systemctl --user start $(systemd-escape --template ${1}@.$TYPE "$ARGS_CONFIG")
				if [[ $(systemctl --user show -p SubState \
					--value $(systemd-escape \
					--template direwolf@.service "$ARGS_CONFIG")) == "running" ]]
				then
					RESULT=0
				else
					RESULT=1
				fi
			fi
			return $RESULT
			;;
		*)
			return 0
			;;
	esac
}


#============================
#  Startup Functions
#============================

function setStartupDefaults () {
		declare -gA STARTUP_default
   	STARTUP_default[_DIREWOLF_START_]='TRUE'
   	STARTUP_default[_PAT_START_]='FALSE'
   	STARTUP_default[_ARDOP_START_]='FALSE'
   	STARTUP_default[_BOOTSTART_]='disabled'
}

function loadStartupSettings () {
	if [ -s "$GUI_STARTUP_CONFIG_FILE" ]
	then # There is a config file
   	echo "$GUI_STARTUP_CONFIG_FILE found." | Sender "manager"
	else # Set some default values in a new config file
   	echo "Config file $GUI_STARTUP_CONFIG_FILE not found. Creating one." | Sender "manager"
		setStartupDefaults
   	echo "declare -gA STARTUP" > "$GUI_STARTUP_CONFIG_FILE"
      echo "STARTUP[_DIREWOLF_START_]='${STARTUP_default[_DIREWOLF_START_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
      echo "STARTUP[_PAT_START_]='${STARTUP_default[_PAT_START_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
      echo "STARTUP[_ARDOP_START_]='${STARTUP_default[_ARDOP_START_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
		echo "STARTUP[_BOOTSTART_]='${STARTUP_default[_BOOTSTART_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
	fi
	source "$GUI_STARTUP_CONFIG_FILE"
	BOOTSTARTs="disabled!none!1!12!13!14!123!124!134!1234!2!23!234!24!3!34!4"
	[[ $BOOTSTARTs =~ ${STARTUP[_BOOTSTART_]} && ${STARTUP[_BOOTSTART_]} =~ ^(none|[1-4]{1,4})$ ]] && BOOTSTARTs="$(echo "$BOOTSTARTs" | sed "s/!${STARTUP[_BOOTSTART_]}/!\^${STARTUP[_BOOTSTART_]}/1")" || BOOTSTARTs="^$BOOTSTARTs"
}

function updateStartupSettings () {
	PREVIOUS_AUTOSTART="${STARTUP[_BOOTSTART_]}"
  	echo "declare -gA STARTUP" > "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_DIREWOLF_START_]='${1}'" >> "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_PAT_START_]='${2}'" >> "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_ARDOP_START_]='${3}'" >> "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_BOOTSTART_]='${4}'" >> "$GUI_STARTUP_CONFIG_FILE"
	source "$GUI_STARTUP_CONFIG_FILE"
	# Make autostart piano switch script if necessary
	if [[ ${STARTUP[_BOOTSTART_]} == "disabled" ]]
	then # Disable autostart
		[[ $PREVIOUS_AUTOSTART =~ none ]] && SWITCHES="" || SWITCHES="$PREVIOUS_AUTOSTART" 
		# Save previous piano script if it exists
		[[ -s $HOME/piano${SWITCHES}.sh ]] && mv -f $HOME/piano${SWITCHES}.sh $HOME/piano${SWITCHES}.sh.$(date '+%Y%m%d') 
	else # Enable autostart
		if [[ ${PREVIOUS_AUTOSTART} != ${STARTUP[_BOOTSTART_]} ]]
		then # Previous autostart was not the same as the requested autostart
			[[ $PREVIOUS_AUTOSTART =~ none ]] && SWITCHES="" || SWITCHES="$PREVIOUS_AUTOSTART" 
			# Save previous piano script if it exists
			[[ -s $HOME/piano${SWITCHES}.sh ]] && mv -f $HOME/piano${SWITCHES}.sh $HOME/piano${SWITCHES}.sh.$(date '+%Y%m%d') 
			[[ ${STARTUP[_BOOTSTART_]} =~ none ]] && SWITCHES="" || SWITCHES="${STARTUP[_BOOTSTART_]}" 
			echo -e "#!/bin/bash\nsleep 5\n$(command -v $(basename $0)) >/dev/null 2>&1" > $HOME/piano${SWITCHES}.sh
			chmod +x $HOME/piano${SWITCHES}.sh
		fi
	fi
	echo "Startup settings saved." | Sender "manager" 
}

function yadStartup () {
   CMD=(	
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>Startup Configuration</big></big></b>\n\n \
	Click the <b>Save Startup settings</b> button below after you make your changes.\n"
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=10
			--use-interp
			--form
			--columns=2
			--focus-field 1
			--field="Start TNC (Direwolf+AX25)\nwhen this manager starts":CHK
			--field="Start pat when\nthis manager starts":CHK
			--field="Start ARDOP when\nthis manager starts":CHK
			--field="Autostart this manager when\nthese piano switch levers are <b>ON</b>:":CB
			--field="<b>Save Startup settings</b>":FBTN
			--
			"${STARTUP[_DIREWOLF_START_]}"
			"${STARTUP[_PAT_START_]}"
			"${STARTUP[_ARDOP_START_]}"
			"$BOOTSTARTs"
			"$save_startup_settings_cmd"
	)
	"${CMD[@]}" > $TMPDIR/CONFIGURE_STARTUP.txt &
	return $!
}

#============================
#  AX25 Functions
#============================

function updateAxports () {
	# Requires 2 arguments:
	#  arg1: port name (first column in $AX25PORTFILE)
	#  arg2: call sign (second column in $AX25PORTFILE)
	if ! grep -q "^${1}[[:space:]]*${2}[[:space:]]" $AX25PORTFILE 2>/dev/null
	then # PORT CALL entry not found
		# Remove existing lines with PORT
		# Remove any lines with CALL
		# Remove empty lines 
		sudo sed -i -e "s/^${1}[[:space:]].*$//g" \
			-e "s/^[[:alnum:]]*[[:space:]]*${2}[[:space:].*$//g" \
			-e "s/^[[:space:]]*$/d" $AX25PORTFILE
		# Add the entry for $PAT_CALL
		echo "${1}	${2}	0	255	7	Added by TNC manager" | sudo tee --append $AX25PORTFILE >/dev/null
		echo "axport file modified." | Sender "manager"
	fi
	argModify AX25_PORT=\"${1}\"
}

function setAX25Defaults () {
	declare -gA AX25_default
	AX25_default[_PORT_]="wl2k"	# AX25 port
   AX25_default[_TXDELAY_]="200"	# TX Delay
   AX25_default[_TXTAIL_]="50"	# TX Tail
   AX25_default[_PERSIST_]="64"	# Persist
   AX25_default[_SLOTTIME_]="20"	# Slot Time
}

function loadAX25Defaults () {
	setAX25Defaults
   echo "2:${AX25_default[_TXDELAY_]}"
	echo "3:${AX25_default[_TXTAIL_]}"
   echo "4:${AX25_default[_PERSIST_]}"
   echo "5:${AX25_default[_SLOTTIME_]}"
}

function loadAX25Settings () {
	if [[ -s "$GUI_AX25_CONFIG_FILE" ]]
	then # There is a config file
   	echo "$GUI_AX25_CONFIG_FILE found." | Sender "manager"
	else # Set some default values in a new config file
   	echo "Config file $GUI_AX25_CONFIG_FILE not found. Creating one." | Sender "manager"
		setAX25Defaults
   	echo "declare -gA AX25" > "$GUI_AX25_CONFIG_FILE"
		echo "AX25[_PORT_]='${AX25_default[_PORT_]}'" >> "$GUI_AX25_CONFIG_FILE"
		echo "AX25[_TXDELAY_]='${AX25_default[_TXDELAY_]}'" >> "$GUI_AX25_CONFIG_FILE"
		echo "AX25[_TXTAIL_]='${AX25_default[_TXTAIL_]}'" >> "$GUI_AX25_CONFIG_FILE"
		echo "AX25[_PERSIST_]='${AX25_default[_PERSIST_]}'" >> "$GUI_AX25_CONFIG_FILE"
		echo "AX25[_SLOTTIME_]='${AX25_default[_SLOTTIME_]}'" >> "$GUI_AX25_CONFIG_FILE"
	fi
	source "$GUI_AX25_CONFIG_FILE"
}

function updateAX25Settings () {
  	echo "declare -gA AX25" > "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_PORT_]='${1}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_TXDELAY_]='${2}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_TXTAIL_]='${3}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_PERSIST_]='${4}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_SLOTTIME_]='${5}'" >> "$GUI_AX25_CONFIG_FILE"
	local PREVIOUS_PORT="${AX25[_PORT_]}"
	source "$GUI_AX25_CONFIG_FILE"
	if [[ "$PREVIOUS_PORT" != "$1" ]]
	then
		# Port has changed. Update pat and args
		argModify AX25_PORT=\"${1}\"
		cat $PAT_CONFIG | jq --arg O $1 '.ax25.port = $O' | sponge $PAT_CONFIG
		local PAT_CALL="$(jq -r ".mycall" $PAT_CONFIG)"
		updateAxports "${AX25[_PORT_]}" "${PAT_CALL}"
		echo "pat settings saved and axports updated." | Sender "manager"
	else
		echo "pat settings saved." | Sender "manager"
	fi
	argModify KISSPARMS_ARGS=\"-c 1 -p \$AX25_PORT -t $2 -l $3 -s $4 -r $5 -f n\"
}

function yadAX25 () {
   CMD=(	
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>AX25 Timer Configuration</big></big></b>\n\n \
	Click the <b>Save and Apply Settings</b> button after you make your changes.\n"
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=20
			--form
			--columns=2
			--focus-field 1 
			--field="<b>Port name</b>"
			--field="<b>TX Delay</b> (ms)":NUM
			--field="<b>TX Tail</b> (ms)":NUM
			--field="<b>Persist</b>":NUM
			--field="<b>Slot Time</b> (ms)":NUM
			--field="<b>Load Default AX25 Timers</b>":FBTN
	      --field="<b>Save and Apply Settings</b>":FBTN
			--
			"${AX25[_PORT_]}"
			"${AX25[_TXDELAY_]}!0..500!1!"
			"${AX25[_TXTAIL_]}!0..200!10!"
			"${AX25[_PERSIST_]}!0..255!1!"
			"${AX25[_SLOTTIME_]}!0..255!10!"
			"$load_ax25_defaults_cmd"
	      "$save_ax25_settings_cmd"
	)
	"${CMD[@]}" > $TMPDIR/CONFIGURE_AX25.txt &
	return $!
}

#============================
#  ARDOP Functions
#============================

function setARDOPDefaults () {
   declare -gA ARDOP_default
   ARDOP_default[_CAPTURE_]="null"				# Audio capture interface
   ARDOP_default[_PLAYBACK_]="null"				# Audio playback interface (ADEVICE)
   ARDOP_default[_PTT_]="GPIO 12"				# GPIO PTT (BCM pin)
   ARDOP_default[_PORT_]="8515"					# ARDOP Port
   ARDOP_default[_ARGUMENTS_]="--logdir=/dev/null" # Optional piardopc arguments
}

function loadARDOPDefaults () {
	setARDOPDefaults
	echo "4:${ARDOP_default[_PORT_]}"
	echo "5:${ARDOP_default[_ARGUMENTS_]}"
}

function loadARDOPSettings () {
	if [ -s "$GUI_ARDOP_CONFIG_FILE" ]
	then # There is a config file
   	echo "$GUI_ARDOP_CONFIG_FILE found." | Sender "manager"
	else # Set some default values in a new config file
   	echo "Config file $GUI_ARDOP_CONFIG_FILE not found. Creating one." | Sender "manager"
		setARDOPDefaults
   	echo "declare -gA ARDOP" > "$GUI_ARDOP_CONFIG_FILE"
   	echo "ARDOP[_CAPTURE_]='${ARDOP_default[_CAPTURE_]}'" >> "$GUI_ARDOP_CONFIG_FILE"
   	echo "ARDOP[_PLAYBACK_]='${ARDOP_default[_PLAYBACK_]}'" >> "$GUI_ARDOP_CONFIG_FILE"
   	echo "ARDOP[_PTT_]='${ARDOP_default[_PTT_]}'" >> "$GUI_ARDOP_CONFIG_FILE"
   	echo "ARDOP[_PORT_]='${ARDOP_default[_PORT_]}'" >> "$GUI_ARDOP_CONFIG_FILE"
   	echo "ARDOP[_ARGUMENTS_]='${ARDOP_default[_ARGUMENTS_]}'" >> "$GUI_ARDOP_CONFIG_FILE"
	fi
  	source "$GUI_ARDOP_CONFIG_FILE"	
   ARDOP_CAPTUREs="$(getCaptureDevices)"
   ARDOP_PLAYBACKs="$(getPlaybackDevices)"
   [[ -n ${ARDOP[_CAPTURE_]} && $ARDOP_CAPTUREs =~ ${ARDOP[_CAPTURE_]} ]] && ARDOP_CAPTUREs="$(echo "$ARDOP_CAPTUREs" | sed "s/${ARDOP[_CAPTURE_]}/\^${ARDOP[_CAPTURE_]}/")"
   [[ $ARDOP_CAPTUREs == "" ]] && ARDOP_CAPTUREs="null"
   [[ -n ${ARDOP[_PLAYBACK_]} && $ARDOP_PLAYBACKs =~ ${ARDOP[_PLAYBACK_]} ]] && ARDOP_PLAYBACKs="$(echo "$ARDOP_PLAYBACKs" | sed "s/${ARDOP[_PLAYBACK_]}/\^${ARDOP[_PLAYBACK_]}/")"
   [[ $ARDOP_PLAYBACKs == "" ]] && ARDOP_PLAYBACKs="null"
   ARDOP_PTTs="GPIO 12!GPIO 23!rigctld network!Client handles PTT"
   if [[ -z ${ARDOP[_PTT_]} ]]
   then
   	ARDOP_PTTs="$(echo "$ARDOP_PTTs" | sed "s/Client handles PTT/\^Client handles PTT/")"
  	elif [[ $ARDOP_PTTs =~ ${ARDOP[_PTT_]} ]]
   then
      ARDOP_PTTs="$(echo "$ARDOP_PTTs" | sed "s/${ARDOP[_PTT_]}/\^${ARDOP[_PTT_]}/")"
   else
      ARDOP_PTTs+="!^${ARDOP[_PTT_]}"
   fi
}

function updateARDOPSettings () {
  	echo "declare -gA ARDOP" > "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_CAPTURE_]='${1}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_PLAYBACK_]='${2}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_PTT_]='${3}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_PORT_]='${4}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_ARGUMENTS_]='${5}'" >> "$GUI_ARDOP_CONFIG_FILE"
	source "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP settings saved." | Sender "manager" 
	local PIARDOPC_ARGS="${ARDOP[_PORT_]} ${ARDOP[_CAPTURE_]} ${ARDOP[_PLAYBACK_]}"
	[[ -n ${ARDOP[_ARGUMENTS_]} ]] && PIARDOPC_ARGS+=" ${ARDOP[_ARGUMENTS_]}"
	[[ ${ARDOP[_PTT_]} =~ GPIO ]] && PIARDOPC_ARGS+=" -g=${ARDOP[_PTT_]#* }"
	if [[ ${ARDOP[_PTT_]} =~ rigctld ]]
	then
#		if lsof -t -i tcp:$RIGCTLD_PORT 2>&1 >/dev/null
#		then
			PIARDOPC_ARGS+=" --cat=${VIRTUAL_COM} -k $RIGCTL_PTT_ON -u $RIGCTL_PTT_OFF"	
#		else
#			# rigctld isn't running so no point in setting up virtual com port
#			echo "ERROR! rigctld not listening on TCP $RIGCTLD_PORT. Rig type must be '4'. ARDOP PTT disabled." | Sender "manager"
#		fi
	fi
	cat $PAT_CONFIG | jq \
		--arg R "127.0.0.1:${ARDOP[_PORT_]}" '.ardop.addr = $R' | sponge $PAT_CONFIG
	argModify PIARDOPC_ARGS=\"$PIARDOPC_ARGS\"
}

function yadARDOP () {
   CMD=(	
	yad --plug="$ID" --tabnum=$1
		--text="<b><big><big>ARDOP Configuration</big></big></b>\n\n \
<b><u><big>Typical ARDOP Sound Card and PTT Settings for Nexus DR-X</big></u></b>\n \
<span color='blue'><b>LEFT Radio:</b></span> Use Audio \
<b>fepi-capture-left</b> and <b>fepi-playback-left</b> and PTT <b>GPIO 12</b>.\n \
<span color='blue'><b>RIGHT Radio:</b></span> Use Audio \
<b>fepi-capture-right</b> and <b>fepi-playback-right</b> and PTT <b>GPIO 23</b>.\n\n \
Click the <b>Save and Apply settings</b> button below after you make your changes.\n"
		--item-separator="!"
		--separator="|"
  		--text-align=center
  		--align=right
  		--borders=10
		--use-interp
  		--form
		--columns=2
  	  	--field="<b>Audio Capture</b>":CB
  	  	--field="<b>Audio Playback</b>":CB
  	  	--field="<b>PTT</b>":CB
   	--field="<b>Port</b>":NUM
		--field="<b>piardopc</b> arguments\n(Usually not needed)":TEXT
		--field="<b>Load Defaults</b>":FBTN		
		--field="<b>Save and Apply Settings</b>":FBTN
  	  	--focus-field 1
		--
		"$ARDOP_CAPTUREs"
		"$ARDOP_PLAYBACKs"
		"$ARDOP_PTTs"
		"${ARDOP[_PORT_]}!8510..8519!1!"
		"${ARDOP[_ARGUMENTS_]}"
		"$load_ardop_defaults_cmd"
		"$save_ardop_settings_cmd"
	)
  	"${CMD[@]}" > $TMPDIR/CONFIGURE_ARDOP.txt &
  	return $!
}

#============================
#  Direwolf Functions
#============================

function setDirewolfDefaults () {
   declare -gA DW_default
   DW_default[_CALL_]="N0CALL"  	# Call sign
   DW_default[_MODEM_]="1200" 	# Modem
   DW_default[_ADEVICE_CAPTURE_]="null"	# Audio capture interface (ADEVICE)
   DW_default[_ADEVICE_PLAY_]="null" 		# Audio playback interface (ADEVICE)
   DW_default[_ACHANNELS_]='1'
   DW_default[_CHANNEL_]='0'
   DW_default[_PTT_]="GPIO 23" 	# GPIO PTT (BCM pin)
   DW_default[_AGWPORT_]="8001" 	# AGW Port
   DW_default[_KISSPORT_]="8011" # KISS Port
   DW_default[_CDIGIPEAT_]='0 0'		# CDIGIPEAT arguments
   DW_default[_CFILTER_]=''		# CFILTER arguments
   DW_default[_CBEACON_]='delay=1 every=15 info="Nexus DR-X custom digipeater"' # CBEACON arguments
   DW_default[_ARGS_]='-r 48000 -t 2 -d uo' # Command line arguments
   echo "Set Direwolf defaults" | Sender "manager"
}

function loadDirewolfDefaults () {
	setDirewolfDefaults
   #echo "1:${DW_default[_CALL_]}"
   #echo "2:${DW_default[_ADEVICE_CAPTURE_]}"
	#echo "3:${DW_default[_ADEVICE_PLAY_]}"
   #echo "4:${DW_default[_ACHANNELS_]}"
   #echo "5:${DW_default[_CHANNEL_]}"
   #echo "6:${DW_default[_PTT_]}"
   #echo "7:${DW_default[_MODEM_]}"
   echo "8:${DW_default[_AGWPORT_]}"
   echo "9:${DW_default[_KISSPORT_]}"
   echo "10:${DW_default[_CDIGIPEAT_]}"
   echo "11:${DW_default[_CFILTER_]}"
   echo "12:${DW_default[_CBEACON_]}"
   echo "13:${DW_default[_ARGS_]}"
}


function loadDirewolfSettings () {

	if [ -s "$GUI_DIREWOLF_CONFIG_FILE" ]
	then # There is a config file
		if ! grep -q _ACHANNELS_ "$GUI_DIREWOLF_CONFIG_FILE"
		then
  			echo "DW[_ACHANNELS_]='1'" >> "$GUI_DIREWOLF_CONFIG_FILE"
		fi
		if ! grep -q _CHANNEL_ "$GUI_DIREWOLF_CONFIG_FILE"
		then
  			echo "DW[_CHANNEL_]='0'" >> "$GUI_DIREWOLF_CONFIG_FILE"
		fi
		if ! grep -q _ARGS_ "$GUI_DIREWOLF_CONFIG_FILE"
		then
  			echo "DW[_ARGS_]='-r 48000 -t 2 -d uo'" >> "$GUI_DIREWOLF_CONFIG_FILE"
		fi
		sed -i -e '/_ARATE_/d' -e '/_AUDIOSTATS_/d' -e '/_COLORS_/d' "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "$GUI_DIREWOLF_CONFIG_FILE found." | Sender "manager"
	else # Set some default values in a new config file
   	echo "Config file $GUI_DIREWOLF_CONFIG_FILE not found. Creating one." | Sender "manager"
		setDirewolfDefaults
   	echo "declare -gA DW" > "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CALL_]='${DW_default[_CALL_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_MODEM_]='${DW_default[_MODEM_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ADEVICE_CAPTURE_]='${DW_default[_ADEVICE_CAPTURE_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ADEVICE_PLAY_]='${DW_default[_ADEVICE_PLAY_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ACHANNELS_]='${DW_default[_ACHANNELS_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CHANNEL_]='${DW_default[_CHANNEL_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_PTT_]='${DW_default[_PTT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_AGWPORT_]='${DW_default[_AGWPORT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_KISSPORT_]='${DW_default[_KISSPORT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CDIGIPEAT_]='${DW_default[_CDIGIPEAT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CFILTER_]='${DW_default[_CFILTER_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CBEACON_]='${DW_default[_CBEACON_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ARGS_]='${DW_default[_ARGS_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	fi
	sed -i -e "s/^DW._ACHANNEL_.=''$/DW[_ACHANNELS_]='1'/" "$GUI_DIREWOLF_CONFIG_FILE" \
	   -e "s/^DW._CHANNEL_.=''$/DW[_CHANNEL_]='0'/" "$GUI_DIREWOLF_CONFIG_FILE" \
	   -e "s/^DW._ARGS_.=''$/DW[_ARGS_]='-r 48000 -t 2 -d uo'/" \
	   "$GUI_DIREWOLF_CONFIG_FILE"
	source "$GUI_DIREWOLF_CONFIG_FILE"
	MODEMs="300!1200!2400!4800!9600"
	ACHANNELSs="1!2"
	[[ $ACHANNELSs =~ ${DW[_ACHANNELS_]} ]] && ACHANNELSs="$(echo "$ACHANNELSs" | sed "s/${DW[_ACHANNELS_]}/\^${DW[_ACHANNELS_]}/")"
	CHANNELs="0!1"
	[[ $CHANNELs =~ ${DW[_CHANNEL_]} ]] && CHANNELs="$(echo "$CHANNELs" | sed "s/${DW[_CHANNEL_]}/\^${DW[_CHANNEL_]}/")"
   #ARATEs="48000!96000"
   #ARATEs="48000"
   PTTs="GPIO 12!GPIO 23!RIG 2 localhost:4532"
	MYCALL="${DW[_CALL_]}"
   [[ $MODEMs =~ ${DW[_MODEM_]} ]] && MODEMs="$(echo "$MODEMs" | sed "s/${DW[_MODEM_]}/\^${DW[_MODEM_]}/")"
   ADEVICE_CAPTUREs="$(getCaptureDevices)"
   ADEVICE_PLAYBACKs="$(getPlaybackDevices)"
   [[ -n ${DW[_ADEVICE_CAPTURE_]} && $ADEVICE_CAPTUREs =~ ${DW[_ADEVICE_CAPTURE_]} ]] && ADEVICE_CAPTUREs="$(echo "$ADEVICE_CAPTUREs" | sed -e "s/${DW[_ADEVICE_CAPTURE_]}/\^${DW[_ADEVICE_CAPTURE_]}/")"
   [[ $ADEVICE_CAPTUREs == "" ]] && ADEVICE_CAPTUREs="null"
   [[ -n ${DW[_ADEVICE_PLAY_]} && $ADEVICE_PLAYBACKs =~ ${DW[_ADEVICE_PLAY_]} ]] && ADEVICE_PLAYBACKs="$(echo "$ADEVICE_PLAYBACKs" | sed -e "s/${DW[_ADEVICE_PLAY_]}/\^${DW[_ADEVICE_PLAY_]}/")"
   [[ $ADEVICE_PLAYBACKs == "" ]] && ADEVICE_PLAYBACKs="null"

   #[[ $ARATEs =~ ${DW[_ARATE_]} ]] && ARATEs="$(echo "$ARATEs" | sed -e "s/${DW[_ARATE_]}/\^${DW[_ARATE_]}/")"

	if [[ $PTTs =~ ${DW[_PTT_]} ]]
   then
      PTTs="$(echo "$PTTs" | sed "s/${DW[_PTT_]}/\^${DW[_PTT_]}/")"
   else
      PTTs+="!^${DW[_PTT_]}"
   fi
	
	#AUDIOSTATs="0!15!30!45!60!90!120"
   #[[ $AUDIOSTATs =~ ${DW[_AUDIOSTATS_]} ]] && AUDIOSTATs="$(echo "$AUDIOSTATs" | sed -e "s/${DW[_AUDIOSTATS_]}/\^${DW[_AUDIOSTATS_]}/")"

	AGWPORT="${DW[_AGWPORT_]}"
	KISSPORT="${DW[_KISSPORT_]}"

}

function updateDirewolfSettings () {
  	echo "declare -gA DW" > "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CALL_]='${1^^}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ADEVICE_CAPTURE_]='${2}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ADEVICE_PLAY_]='${3}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ACHANNELS_]='${4}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CHANNEL_]='${5}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_PTT_]='${6}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_MODEM_]='${7}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_AGWPORT_]='${8}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_KISSPORT_]='${9}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CDIGIPEAT_]='${10}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CFILTER_]='${11}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CBEACON_]='${12}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ARGS_]='${13}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	source "$GUI_DIREWOLF_CONFIG_FILE"
	# Create a Direwolf config file with these settings
	makeDirewolfConfig
	local REGEX=' -c'
	if [[ ${DW[_ARGS_]} =~ $REGEX ]]
	then # User has specified a custom direwolf configuration file
		DIREWOLF_ARGS="${DW[_ARGS_]}"
	else # Configuration file created by this manager will be used
		DIREWOLF_ARGS="${DW[_ARGS_]} -c $DW_CONFIG"
	fi
	argModify DIREWOLF_ARGS=\"$DIREWOLF_ARGS\"
	echo "Direwolf settings saved." | Sender "manager" 
}

function makeDirewolfConfig () {
	if [[ -n ${DW[_CDIGIPEAT_]} ]]
	then
		CDIGIPEAT_CMD="CDIGIPEAT ${DW[_CDIGIPEAT_]}"
		[[ -n ${DW[_CFILTER_]} ]] && CFILTER_CMD="CFILTER ${DW[_CFILTER_]}" || CFILTER_CMD='' 
	else
		CDIGIPEAT_CMD=''
		CFILTER_CMD=''
	fi
	if [[ -n ${DW[_CBEACON_]} ]]
	then
		CBEACON_CMD="CBEACON ${DW[_CBEACON_]}"
	else
		CBEACON_CMD=''
	fi
	cat > $DW_CONFIG <<EOF
ADEVICE ${DW[_ADEVICE_CAPTURE_]} ${DW[_ADEVICE_PLAY_]}
ACHANNELS ${DW[_ACHANNELS_]}
CHANNEL ${DW[_CHANNEL_]}
PTT ${DW[_PTT_]}
MYCALL ${DW[_CALL_]}
MODEM ${DW[_MODEM_]}
AGWPORT ${DW[_AGWPORT_]}
KISSPORT ${DW[_KISSPORT_]}
$CDIGIPEAT_CMD
$CFILTER_CMD
$CBEACON_CMD
EOF
}


function yadDirewolf () {
   CMD=(
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>Direwolf Configuration</big></big></b>\n \
<span color='blue'><b>For Fe-Pi LEFT Radio:</b></span> Use <i>mono</i> ADEVICEs \
<b>fepi-capture-left</b> and <b>fepi-playback-left</b> and PTT <b>GPIO 12</b>.\n \
<span color='blue'><b>For Fe-Pi RIGHT Radio:</b></span> Use <i>mono</i> ADEVICEs \
<b>fepi-capture-right</b> and <b>fepi-playback-right</b> and PTT <b>GPIO 23</b>.\n \
Click the <b>Save and Apply Settings</b> button below after you make your changes.\n"
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=10
			--form
			--columns=2
			--use-interp
			--focus-field 1
			--field="<b>Call Sign</b>"
			--field="<b>ADEVICE Capture</b>":CB
			--field="<b>ADEVICE Playback</b>":CB
  			--field="<b>ACHANNELS</b>: <b>1</b> for mono\nADEVICE; <b>2</b> for stereo":CB
  			--field="<b>CHANNEL</b>: <b>0</b> for mono or\nstereo left; <b>1</b> for stereo right":CB  
			--field="<b>PTT</b>":CBE
  			--field="<b>MODEM</b>":CB 
			--field="<b>AGW Port</b>":NUM
			--field="<b>KISS Port</b>":NUM
			--field="<b>CDIGIPEAT</b>"
			--field="<b>CFILTER</b>"
			--field="<b>CBEACON</b>"
			--field="Arguments"
			--field="<b>Load Defaults</b>":FBTN
			--field="<b>Save and Apply Settings</b>":FBTN
			--
			"$MYCALL"
			"$ADEVICE_CAPTUREs"
			"$ADEVICE_PLAYBACKs"
			"$ACHANNELSs"
			"$CHANNELs"
			"$PTTs"
			"$MODEMs"
			"$AGWPORT!8001..8010!1!"
			"$KISSPORT!8011..8020!1!"
			"${DW[_CDIGIPEAT_]}"
			"${DW[_CFILTER_]}"
			"${DW[_CBEACON_]}"
			"${DW[_ARGS_]}"
			"$load_direwolf_defaults_cmd"
			"$save_direwolf_settings_cmd"
	)
	"${CMD[@]}" > $TMPDIR/CONFIGURE_DIREWOLF.txt &
	return $!
}

#============================
#  pat Functions
#============================

function editPatPassword () {
	PASSWD="${1:-}"
	local CMD=(yad --form 
		--title="Edit Passwd"
		--text-align=center
		--align=right
		--borders=5
		--item-separator="!"
		--separator="|"
		--form
		--field="<b>Winlink\nPassword</b>"
		--
		"$PASSWD"
	)
	NEW_PASSWD="$("${CMD[@]}")"	
	[[ $? == 0 ]] && echo "2:${NEW_PASSWD%%|*}" || echo "2:$PASSWD"
}

function loadPatSettings () {
	if [ -s "$GUI_PAT_CONFIG_FILE" ]
	then # There is a config file
   	echo "$GUI_PAT_CONFIG_FILE found." | Sender "manager"
	else # Set some default values (dummy rig) in a new config file
   	echo "Config file $GUI_DIREWOLF_CONFIG_FILE not found. Creating one." | Sender "manager"
		echo "PAT_AX25_LISTEN='FALSE'" > "$GUI_PAT_CONFIG_FILE"
		echo "PAT_TELNET_LISTEN='FALSE'" >> "$GUI_PAT_CONFIG_FILE"
		echo "PAT_ARDOP_LISTEN='FALSE'" >> "$GUI_PAT_CONFIG_FILE"
	fi
	source "$GUI_PAT_CONFIG_FILE"
	
	PAT_CALL="$(jq -r ".mycall" $PAT_CONFIG)"
	PAT_PASSWORD="$(jq -r ".secure_login_password" $PAT_CONFIG)"
	PAT_HTTP_PORT="$(jq -r ".http_addr" $PAT_CONFIG | cut -d: -f2)"
	PAT_TELNET_PORT="$(jq -r ".telnet.listen_addr" $PAT_CONFIG | cut -d: -f2)"
	PAT_TELNET_PASSWD="$(jq -r ".telnet.password" $PAT_CONFIG)"
	PAT_LOCATOR="$(jq -r ".locator" $PAT_CONFIG)"
	PAT_AX25_BEACON_INTERVAL="$(jq -r ".ax25.beacon.every" $PAT_CONFIG)"
	PAT_AX25_BEACON_MESSAGE="$(jq -r ".ax25.beacon.message" $PAT_CONFIG)"
	PAT_ARQ_BW_FORCED="$(jq -r ".ardop.arq_bandwidth.Forced" $PAT_CONFIG)"
	PAT_ARQ_BW_MAX="$(jq -r ".ardop.arq_bandwidth.Max" $PAT_CONFIG)"
	PAT_ARQ_BW_MAXs="200!500!1000!2000"
	if [[ $PAT_ARQ_BW_MAXs =~ $PAT_ARQ_BW_MAX ]]
	then
		PAT_ARQ_BW_MAXs="$(echo $PAT_ARQ_BW_MAXs | sed -e "s/$PAT_ARQ_BW_MAX/\^$PAT_ARQ_BW_MAX/")"
	else
		PAT_ARQ_BW_MAXs="$(echo $PAT_ARQ_BW_MAXs | sed -e "s/500/\^500/")"
	fi
	PAT_ARDOP_BEACON_INTERVAL="$(jq -r ".ardop.beacon_interval" $PAT_CONFIG)"
	PAT_CW_ID="$(jq -r ".ardop.cwid_enabled" $PAT_CONFIG)"
	PAT_ARDOP_PTT="$(jq -r ".ardop.ptt_ctrl" $PAT_CONFIG)"
	local ARGS=""
	[[ $PAT_AX25_LISTEN == TRUE ]] && ARGS+="ax25,"
	[[ $PAT_TELNET_LISTEN == TRUE ]] && ARGS+="telnet,"
	[[ $PAT_ARDOP_LISTEN == TRUE ]] && ARGS+="ardop"
	if [[ -n $ARGS ]]
	then
		argModify PAT_ARGS=\"-l $ARGS http\"
	else
		argModify PAT_ARGS=\"http\"
	fi
}

function updatePatSettings () {
	# Update the pat config.json file with the new data.
	local PAT_CALL_PREVIOUS="$(jq -r ".mycall" $PAT_CONFIG)"
	local PAT_AX25_PORT="$(jq -r ".ax25.port" $PAT_CONFIG)"
	PAT_CALL="${1^^}"
	PAT_PASSWORD="${2}"
	PAT_LOCATOR="${3^^}"
	PAT_HTTP_PORT="${4}"
	PAT_TELNET_PORT="${5}"
	PAT_TELNET_PASSWD="${6}"
	PAT_AX25_BEACON_INTERVAL="${7}"
	PAT_AX25_BEACON_MESSAGE="${8}"
	PAT_AX25_LISTEN="${9}"
	PAT_TELNET_LISTEN="${10}"
	PAT_ARDOP_LISTEN="${11}"
	PAT_ARQ_BW_FORCED="${12}"
	PAT_ARQ_BW_MAX="${13}"
	PAT_ARDOP_BEACON_INTERVAL="${14}"
	PAT_CW_ID="${15}"
	PAT_ARDOP_PTT="${16}"
	cat $PAT_CONFIG | jq \
		--arg C "$PAT_CALL" \
		--arg P "$PAT_PASSWORD" \
		--arg H "0.0.0.0:$PAT_HTTP_PORT" \
		--arg T "0.0.0.0:$PAT_TELNET_PORT" \
		--arg A "$PAT_TELNET_PASSWD" \
		--arg L "$PAT_LOCATOR" \
		--argjson X $PAT_AX25_BEACON_INTERVAL \
		--arg M "$PAT_AX25_BEACON_MESSAGE" \
		--argjson F ${PAT_ARQ_BW_FORCED,,} \
		--argjson B $PAT_ARQ_BW_MAX \
		--argjson D ${PAT_CW_ID,,} \
		--argjson K ${PAT_ARDOP_PTT,,} \
		--argjson I $PAT_ARDOP_BEACON_INTERVAL \
			'.mycall = $C | .secure_login_password = $P | .http_addr = $H | .telnet.listen_addr = $T | .telnet.password = $A |.locator = $L | .ax25.beacon.every = $X | .ax25.beacon.message = $M | .ardop.beacon_interval = $I | .ardop.arq_bandwidth.Max = $B | .ardop.arq_bandwidth.Forced = $F | .ardop.cwid_enabled = $D | .ardop.ptt_ctrl = $K' | sponge $PAT_CONFIG
	[[ $PAT_CALL_PREVIOUS != $PAT_CALL ]] && updateAxports "${PAT_AX25_PORT}" "${PAT_CALL}"
	echo "PAT_AX25_LISTEN='$PAT_AX25_LISTEN'" > "$GUI_PAT_CONFIG_FILE"
	echo "PAT_TELNET_LISTEN='$PAT_TELNET_LISTEN'" >> "$GUI_PAT_CONFIG_FILE"
	echo "PAT_ARDOP_LISTEN='$PAT_ARDOP_LISTEN'" >> "$GUI_PAT_CONFIG_FILE"
	source "$GUI_PAT_CONFIG_FILE"
	local ARGS=""
	[[ $PAT_AX25_LISTEN == TRUE ]] && ARGS+="ax25,"
	[[ $PAT_TELNET_LISTEN == TRUE ]] && ARGS+="telnet,"
	[[ $PAT_ARDOP_LISTEN == TRUE ]] && ARGS+="ardop"
	if [[ -n $ARGS ]]
	then
		argModify PAT_ARGS=\"-l $ARGS http\"
	else
		argModify PAT_ARGS=\"http\"
	fi
	cat > $TMPDIR/pat_web.sh <<EOF
xdg-open http://localhost:$PAT_HTTP_PORT >/dev/null 2>&1
EOF
	echo "pat settings saved." | Sender "manager"
}

function yadPat () {
   CMD=(	
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>pat Configuration</big></big></b>\n \
	Click the <b>Save and Apply Settings</b> button below after you make your changes."
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=10
			--form
			--columns=3
			--focus-field 1 
			--field="Call Sign"
			--field="Winlink Password":H
			--field="<b>Edit Password in visible text</b>":FBTN
			--field="Locator Code"
			--field="Web Service Port":NUM
			--field="Telnet Service\nPort":NUM
			--field="Telnet Service\nPassword"
			--field="Packet Beacon Interval\n(s) (0 disables beacon)":NUM
			--field="Packet Beacon Message"
			--field="Enable AX25 listener":CHK
			--field="Enable Telnet listener":CHK
			--field="Enable ARDOP listener":CHK
			--field="ARDOP Forced ARQ Bandwidth":CHK
			--field="ARDOP Max ARQ\nBandwidth (Hz)":CB
			--field="ARDOP Beacon Interval\n(seconds), 0 disables":NUM
			--field="ARDOP: Enable CW ID":CHK
			--field="ARDOP: pat controls PTT":CHK
			--field="<b>Edit Connection Aliases</b>":FBTN
			--field="<b>Save and Apply Settings</b>":FBTN
			--
			"$PAT_CALL"
			"$PAT_PASSWORD"
			'@bash -c "editPatPassword %2"'
			"$PAT_LOCATOR"
			"$PAT_HTTP_PORT!8040..8049!1!"
			"$PAT_TELNET_PORT!8770..8779!1!"
			"$PAT_TELNET_PASSWD"
			"$PAT_AX25_BEACON_INTERVAL!0..7200!1!"
			"$PAT_AX25_BEACON_MESSAGE"
			"$PAT_AX25_LISTEN"
			"$PAT_TELNET_LISTEN"
			"$PAT_ARDOP_LISTEN"
			"$PAT_ARQ_BW_FORCED"
			"$PAT_ARQ_BW_MAXs"
			"$PAT_ARDOP_BEACON_INTERVAL!0..7200!1!"
			"$PAT_CW_ID"
			"$PAT_ARDOP_PTT"
			"bash -c edit_pat_aliases.sh &"
			"$save_pat_settings_cmd"
	)		
	"${CMD[@]}" > $TMPDIR/CONFIGURE_PAT.txt &
	return $!
}

function makePatWebLauncher () {
	cat > $TMPDIR/pat_web.sh <<EOF
xdg-open http://localhost:$1 >/dev/null 2>&1
EOF

}

#============================
#  rigctl Functions
#============================

function loadRigctldSettings () {
	if [ -s "$GUI_RIGCTLD_CONFIG_FILE" ]
	then # There is a config file
   	echo "$GUI_RIGCTLD_CONFIG_FILE found." | Sender "manager"
	else # Set some default values (dummy rig) in a new config file
   	echo "Config file $GUI_DIREWOLF_CONFIG_FILE not found. Creating one." | Sender "manager"
		echo "RIGCTLD_CONFIG='-v -t $RIGCTLD_PORT -m 1'" > "$GUI_RIGCTLD_CONFIG_FILE"
	fi
	source "$GUI_RIGCTLD_CONFIG_FILE"
	
}

function updateRigctldSettings () {
	echo "$(grep RIGCTLD_ARGS $ARGS_CONFIG | sed -e 's/ARGS/CONFIG/')" > "$GUI_RIGCTLD_CONFIG_FILE"
	source "$GUI_RIGCTLD_CONFIG_FILE"
	echo "rigctld arguments updated" | Sender "manager"
}

function yadRigctl () {
	local CURRENT="$(grep RIGCTLD_ARGS $ARGS_CONFIG | cut -d= -f2)"
	local RIGCTL_INFO=" \
The rig control daemon (rigctld) is part of Hamlib. It provides a way to control \
various rigs using CAT commands, usually over a serial port.\n\nIn order to set up \
aliases (shortcuts) in the pat web interface for RMS Gateway stations ALONG WITH \
their frequency, pat requires the use of rigctld. When started, the GUI you're \
currently using will check to see if rigctld is already running. If it's not, it'll \
start rigctld using a 'dummy' rig, which fools pat into thinking it's controlling a \
radio when it's not (meaning you have to set your radio's frequency manually).\n\nIf \
your rig is supported by Hamlib (or to check to see if it is supported), click the \
'Manage Hamlib rigctld' button below to have the TNC and pat REALLY talk to your \
radio (if supported) and have pat automatically QSY as needed.\n\nIf your rig is \
supported by FLrig, then use that (search for 'flrig'). Make sure FLRig is configured \
to talk to your radio and is running when you [re]start rigctld."
	yad --plug="$ID" --tabnum=$1 --text-align=center --borders=20 --form --wrap \
		--text="<big><big><b>Hamlib Rig Control (rigctld)</b></big></big>" \
		--field="":TXT "$RIGCTL_INFO" \
		--field="<b>Manage Hamlib rigctld</b>":FBTN 'bash -c "rigctl_gui.sh $ARGS_CONFIG; updateRigctldSettings"' >/dev/null &
	return $!
}

#============================
#  Manager Functions
#============================

function yadManager () {
	URI_HANDLER='xdg-open "%s"'
	TEXT="<b><big><big>TNC and pat Manager</big></big></b>"
	[[ ${STARTUP[_DIREWOLF_START_]} == TRUE || ${STARTUP[_ARDOP_START_]} == TRUE ]] && TEXT+="\n<b>TNC PORTS:</b> "
	[[ ${STARTUP[_DIREWOLF_START_]} == TRUE ]] && TEXT+="AGW=<span color='blue'><b>${DW[_AGWPORT_]}</b></span> KISS=<span color='blue'><b>${DW[_KISSPORT_]}</b></span> AX.25=<span color='blue'><b>${AX25[_PORT_]}</b></span> "
	[[ ${STARTUP[_ARDOP_START_]} == TRUE ]] && TEXT+="ARDOP=<span color='blue'><b>${ARDOP[_PORT_]}</b></span>"
	[[ ${STARTUP[_PAT_START_]} == TRUE ]] && TEXT+="\n<b>pat PORTS:</b> telnet=<span color='blue'><b>$PAT_TELNET_PORT</b></span> web=<span color='blue'><b>http://$HOSTNAME.local:$PAT_HTTP_PORT</b></span>"
	MANAGER_TITLE="TNC and pat Manager $VERSION"
	yad --title="$MANAGER_TITLE" --text="$TEXT" --show-uri --uri-handler="$URI_HANDLER" \
		--use-interp \
  		--text-align="center" --notebook --key="$ID" \
  		--posx=$POSX --posy=$POSY \
		--use-interp \
  		--buttons-layout=center \
  		--tab="Startup" \
  		--tab="AX25" \
  		--tab="ARDOP" \
  		--tab="Direwolf" \
  		--tab="pat" \
  		--tab="Rig Control" \
  		--button="<b>Stop &#x26; Exit</b>"!!"Stop everything and exit":0 \
  		--button="<b>TNC</b>"!!"Status/start/stop Direwolf+AX25":'startStop tnc' \
  		--button="<b>PAT</b>"!!"Status/start/stop pat":'startStop pat' \
  		--button="<b>ARDOP</b>"!!"Status/start/stop ARDOP":'startStop ardop' \
  		--button="<b>PAT Web</b>"!!"Open PAT Web Interface":"bash -c $TMPDIR/pat_web.sh" \
  		--button="<b>Help</b>":"$click_help_cmd" &
	return $!
}

#============================
#  FILES AND VARIABLES
#============================

# Set Temp Directory
# -----------------------------------
# Create temp directory with three random numbers and the process ID
# in the name.  This directory is removed automatically at exit.
# -----------------------------------
export TMPDIR="/tmp/${SCRIPT_NAME}.$RANDOM.$RANDOM.$RANDOM.$$"
(umask 077 && mkdir "${TMPDIR}") || {
  Die "Could not create temporary directory! Exiting."
}

  #== general variables ==#
SCRIPT_NAME="$(basename ${0})" # scriptname without path
SCRIPT_DIR="$( cd $(dirname "$0") && pwd )" # script directory
SCRIPT_FULLPATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
SCRIPT_ID="$(ScriptInfo | grep script_id | tr -s ' ' | cut -d' ' -f3)"
SCRIPT_HEADSIZE=$(grep -sn "^# END_OF_HEADER" ${0} | head -1 | cut -f1 -d:)
VERSION="$(ScriptInfo version | grep version | tr -s ' ' | cut -d' ' -f 4)"

TITLE="TNC and pat Manager $VERSION"
CONFIG_DIR="$HOME/.config/nexus"
TNC_DIR="$HOME/.config/tnc"
GUI_STARTUP_CONFIG_FILE="$CONFIG_DIR/tnc_gui_startup.conf"
GUI_DIREWOLF_CONFIG_FILE="$CONFIG_DIR/tnc_gui_direwolf.conf"
GUI_ARDOP_CONFIG_FILE="$CONFIG_DIR/tnc_gui_ardop.conf"
GUI_AX25_CONFIG_FILE="$CONFIG_DIR/tnc_gui_ax25.conf"
GUI_RIGCTLD_CONFIG_FILE="$CONFIG_DIR/tnc_gui_rigctld.conf"
GUI_PAT_CONFIG_FILE="$CONFIG_DIR/tnc_gui_pat.conf"
DW_CONFIG="$TMPDIR/direwolf.conf"
MESSAGE="Direwolf Configuration"

#ID="${RANDOM}"
ID=$$
export ARGS_CONFIG="$TMPDIR/args.conf"


export SOCAT_PORT=3333
VIRTUAL_COM_SPEED=38400
VIRTUAL_COM_PORT="/tmp/vcom0"
export VIRTUAL_COM="${VIRTUAL_COM_PORT}:$VIRTUAL_COM_SPEED"
RIGCTLD_PORT=4532
export RIGCTL_PTT_ON="5420310A"
export RIGCTL_PTT_OFF="5420300A"

# YAD Dialog Window settings
POSX=20 
POSY=50 
WIDTH=300
HEIGHT=200
AX25PORT="wl2k"
AX25PORTFILE="/etc/ax25/axports"
PAT_VERSION="$(pat version | cut -d' ' -f2)"
[[ $PAT_VERSION =~ v0.1[01]. ]] && PAT_CONFIG="$HOME/.wl2k/config.json" || PAT_CONFIG="$HOME/.config/pat/config.json"
YAD_PIDs=()
RETURN_CODE=0


#============================
#  PARSE OPTIONS WITH GETOPTS
#============================
  
#== set short options ==#
SCRIPT_OPTS=':hv-:'

#== set long options associated with short one ==#
typeset -A ARRAY_OPTS
ARRAY_OPTS=(
	[help]=h
	[version]=v
)

LONG_OPTS="^($(echo "${!ARRAY_OPTS[@]}" | tr ' ' '|'))="

# Parse options
while getopts ${SCRIPT_OPTS} OPTION
do
	# Translate long options to short
	if [[ "x$OPTION" == "x-" ]]
	then
		LONG_OPTION=$OPTARG
		LONG_OPTARG=$(echo $LONG_OPTION | egrep "$LONG_OPTS" | cut -d'=' -f2-)
		LONG_OPTIND=-1
		[[ "x$LONG_OPTARG" = "x" ]] && LONG_OPTIND=$OPTIND || LONG_OPTION=$(echo $OPTARG | cut -d'=' -f1)
		[[ $LONG_OPTIND -ne -1 ]] && eval LONG_OPTARG="\$$LONG_OPTIND"
		OPTION=${ARRAY_OPTS[$LONG_OPTION]}
		[[ "x$OPTION" = "x" ]] &&  OPTION="?" OPTARG="-$LONG_OPTION"
		
		if [[ $( echo "${SCRIPT_OPTS}" | grep -c "${OPTION}:" ) -eq 1 ]]; then
			if [[ "x${LONG_OPTARG}" = "x" ]] || [[ "${LONG_OPTARG}" = -* ]]; then 
				OPTION=":" OPTARG="-$LONG_OPTION"
			else
				OPTARG="$LONG_OPTARG";
				if [[ $LONG_OPTIND -ne -1 ]]; then
					[[ $OPTIND -le $Optnum ]] && OPTIND=$(( $OPTIND+1 ))
					shift $OPTIND
					OPTIND=1
				fi
			fi
		fi
	fi

	# Options followed by another option instead of argument
	if [[ "x${OPTION}" != "x:" ]] && [[ "x${OPTION}" != "x?" ]] && [[ "${OPTARG}" = -* ]]; then 
		OPTARG="$OPTION" OPTION=":"
	fi

	# Finally, manage options
	case "$OPTION" in
		h) 
			ScriptInfo full
			exit 0
			;;
		v) 
			ScriptInfo version
			exit 0
			;;
		:) 
			Die "${SCRIPT_NAME}: -$OPTARG: option requires an argument"
			;;
		?) 
			Die "${SCRIPT_NAME}: -$OPTARG: unknown option"
			;;
	esac
done
shift $((${OPTIND} - 1)) ## shift options

# Ensure only this instance of this script is running. Kill the other instances.
OTHER_PIDs="$(pidof -o %PPID -x $(basename $0))"
[[ -n $OTHER_PIDs ]] && kill -SIGTERM $OTHER_PIDs

if pidof -x dw_pat_gui.sh >/dev/null
then
	TITLE="TNC and pat Manager $VERSION"
	TEXT="<b><span color='red'>TNC Manager is a <u>replacement</u> for the older Direwolf TNC and pat GUI!\n \
Only one of these programs can run at one time.</span>\n\n \
Stop the <u>Direwolf TNC and pat GUI</u> first, then run this TNC Manager program.</b>"
	yad --question --title="$TITLE" --text="$TEXT" \
	--text-align=center --buttons-layout=center \
	--button="OK":0
	SafeExit 1
fi

# Check for required apps.
for A in yad pat jq sponge piardopc direwolf rigctld
do 
	command -v $A >/dev/null 2>&1 || Die "$A is required but not installed."
done

# Check for pat's config file, config.json.  Create it if missing or corrupted.
RESULT="$(jq . $PAT_CONFIG 2>/dev/null)"
if [[ -z $RESULT ]]
then # config.json missing or corrupted.  Make a new one.
	[[ -f $PAT_CONFIG ]] && rm $PAT_CONFIG
	cd $HOME
	export EDITOR=ed
	echo -n "" | pat configure >/dev/null 2>&1
fi

# Set up pat for rigctl network connection in config.json
cat $PAT_CONFIG | jq \
   '.hamlib_rigs += {"rigctld": {"address": "localhost:4532", "network": "tcp"}}' | sponge $PAT_CONFIG
# Add the network Hamlib rig to the ax25 and ardop sections
cat $PAT_CONFIG | jq --arg R "rigctld" '.ax25.rig = $R' | sponge $PAT_CONFIG
cat $PAT_CONFIG | jq --arg R "rigctld" '.ardop.rig = $R' | sponge $PAT_CONFIG

export AX25PORTFILE
export PAT_CONFIG
export DW_CONFIG
export -f setAX25Defaults loadAX25Defaults updateAX25Settings updateAxports
export -f updateARDOPSettings setARDOPDefaults loadARDOPDefaults
export -f updateStartupSettings 
export -f updateRigctldSettings
export -f editPatPassword updatePatSettings 
export -f setDirewolfDefaults loadDirewolfDefaults updateDirewolfSettings
export -f makeDirewolfConfig
export -f Sender restart startStop
export -f argModify
export click_help_cmd='xdg-open /usr/local/share/nexus/tnc_manager_help.html'
export save_startup_settings_cmd='updateStartupSettings %1 %2 %3 %4'
export load_ardop_defaults_cmd='@bash -c "loadARDOPDefaults"'
export load_ax25_defaults_cmd='@bash -c "loadAX25Defaults"'
export load_direwolf_defaults_cmd='@bash -c "loadDirewolfDefaults"'
export save_ax25_settings_cmd='bash -c "updateAX25Settings %1 %2 %3 %4 %5; restart tnc; restart pat"'
export save_ardop_settings_cmd='updateARDOPSettings %1 %2 %3 %4 %5; restart ardop'
export save_direwolf_settings_cmd='updateDirewolfSettings %1 %2 %3 %4 %5 %6 %7 %8 %9 %10 %11 %12 %13; restart tnc; restart pat'
export save_pat_settings_cmd='bash -c "updatePatSettings %1 %2 %4 %5 %6 %7 %8 %9 %10 %11 %12 %13 %14 %15 %16 %17; restart tnc; restart pat"'

export GUI_STARTUP_CONFIG_FILE
export GUI_DIREWOLF_CONFIG_FILE
export GUI_ARDOP_CONFIG_FILE
export GUI_AX25_CONFIG_FILE
export GUI_RIGCTLD_CONFIG_FILE
export GUI_PAT_CONFIG_FILE


#============================
#  MAIN SCRIPT
#============================

# Trap bad exits with cleanup function
trap SafeExit EXIT INT TERM

# Exit on error. Append '||true' when you run the script if you expect an error.
#set -o errexit

# Check Syntax if set
$SYNTAX && set -n
# Run in debug mode, if set
$DEBUG && set -x 

MONITOR_PID=''

# If this is the first time running this script, don't attempt to start until 
# user configures
if [[ -s $PAT_CONFIG && -s $GUI_STARTUP_CONFIG_FILE && -s $GUI_ARDOP_CONFIG_FILE && -s $GUI_AX25_CONFIG_FILE && -s $GUI_DIREWOLF_CONFIG_FILE ]]	
then # GUI Configuration files exist
	if [[ $(jq -r ".mycall" $PAT_CONFIG) == "" ]]
	then # pat config files present, but not configured
		FIRST_RUN=true
	else # pat config files present and configured
		FIRST_RUN=false
	fi
else # No configuration files exist
	FIRST_RUN=true
fi

cat > $ARGS_CONFIG <<EOF
ID=$ID
SOCAT_PORT=$SOCAT_PORT
VIRTUAL_COM_SPEED=$VIRTUAL_COM_SPEED
VIRTUAL_COM_PORT="$VIRTUAL_COM_PORT"
RIGCTLD_PORT=$RIGCTLD_PORT
EOF

YAD_PIDs=()

# Start monitor window
if [[ -z $MONITOR_PID ]]
then
	MONITOR_TITLE="TNC and pat Monitor $VERSION"
	lxterminal --geometry=80x20 -t "$MONITOR_TITLE" -e "socat -u udp-recv:$SOCAT_PORT,reuseaddr -" &
	while [[ -z $MONITOR_PID ]]
	do
		MONITOR_PID=$(lsof -t -i udp:$SOCAT_PORT)
		sleep 0.5
	done
	echo "Monitor PID=$MONITOR_PID" | Sender "manager"
fi

# Load settings from configuration files
loadStartupSettings
loadAX25Settings
loadARDOPSettings
loadDirewolfSettings
loadPatSettings
loadRigctldSettings

# Start rigctld.
#if systemctl --user is-active --quiet $(systemd-escape --template rigctld@.service "$ARGS_CONFIG") || pgrep -x rigctld >/dev/null
if pgrep -fx "^.*$(command -v rigctld) $RIGCTLD_CONFIG"
then
	echo "rigctld $RIGCTLD_CONFIG already running." | Sender "manager"
else
	# Kill other instances of rigctld
	systemctl --user stop rigctld@*
	pkill "^$(command -v rigctld) .*"
	#argModify RIGCTLD_ARGS=\"-v -t \$RIGCTLD_PORT -m 1\"
	argModify RIGCTLD_ARGS=\"$RIGCTLD_CONFIG\"
	restart rigctld
fi

if [[ $FIRST_RUN == true ]]
then
	echo -e "Configure TNC, pat, ARDOP in the GUI,\nthen click \"Save...\" button." | Sender "manager"
else # Not a first run.  pat and Direwolf configured so start 'em
	# Configure /etc/ax25/axports if necessary.  This is needed in order to allocate a PTY for pat.
	updateAxports "${AX25[_PORT_]}" "${PAT_CALL}"		
	argModify KISS_PORT=${DW[_KISSPORT_]}
	[[ ${DW[_AUDIOSTATS_]} == 0 ]] && STATS="" || STATS="-a ${DW[_AUDIOSTATS_]}"
	REGEX=' -c'
	if [[ ${DW[_ARGS_]} =~ $REGEX ]]
	then # User has specified a custom direwolf configuration file
		DIREWOLF_ARGS="${DW[_ARGS_]}"
	else # Configuration file created by this manager will be used
		DIREWOLF_ARGS="${DW[_ARGS_]} -c $DW_CONFIG"
	fi
	argModify DIREWOLF_ARGS=\"$DIREWOLF_ARGS\"
	KISSPARMS_ARGS="-c 1 -p ${AX25[_PORT_]} -t ${AX25[_TXDELAY_]} -l ${AX25[_TXTAIL_]} -s ${AX25[_SLOTTIME_]} -r ${AX25[_PERSIST_]} -f n"
	argModify KISSPARMS_ARGS=\"$KISSPARMS_ARGS\"
	makeDirewolfConfig
	if [[ ${STARTUP[_DIREWOLF_START_]} == TRUE ]]
	then
		echo -e "\nUsing Direwolf configuration in $DW_CONFIG:" | Sender "direwolf"
		cat "$DW_CONFIG" | Sender "direwolf"
		echo "Starting direwolf ${DIREWOLF_ARGS}" | Sender "direwolf"
		restart tnc
	fi
		
	# Start ARDOP
	PIARDOPC_ARGS="${ARDOP[_PORT_]} ${ARDOP[_CAPTURE_]} ${ARDOP[_PLAYBACK_]}"
	[[ -n ${ARDOP[_ARGUMENTS_]} ]] && PIARDOPC_ARGS+=" ${ARDOP[_ARGUMENTS_]}"
	[[ ${ARDOP[_PTT_]} =~ GPIO ]] && PIARDOPC_ARGS+=" -g=${ARDOP[_PTT_]#* }"
	if [[ ${ARDOP[_PTT_]} =~ rigctld ]]
	then
		if lsof -t -i tcp:$RIGCTLD_PORT 2>&1 >/dev/null
		then
			PIARDOPC_ARGS+=" --cat=${VIRTUAL_COM} -k $RIGCTL_PTT_ON -u $RIGCTL_PTT_OFF"	
		else
			# rigctld isn't running so no point in setting up virtual com port
			echo "ERROR! rigctld not listening on TCP $RIGCTLD_PORT. Rig type must be '4'. ARDOP PTT disabled." | Sender "manager"
		fi
	fi
	argModify PIARDOPC_ARGS=\"$PIARDOPC_ARGS\"
	[[ ${PIARDOPC_ARGS} =~ $RIGCTL_PTT_ON ]] && restart rigctldvcom
	grep -q "^PIARDOPC_ARGS=.*--cat" $ARGS_CONFIG && restart rigctldvcom
	if [[ ${STARTUP[_ARDOP_START_]} == TRUE ]]
	then
		restart ardop
	fi
		
	# Start pat
	if [[ ${STARTUP[_PAT_START_]} == TRUE ]]
	then
		restart pat
	fi
fi
	
# Startup tab 1
yadStartup 1
YAD_PIDs+=( $! )
	
# AX25 tab 2
yadAX25 2 
YAD_PIDs+=( $! )
	
# ARDOP tab 3
yadARDOP 3
YAD_PIDs+=( $! )
	
# Direwolf tab 4 
yadDirewolf 4
YAD_PIDs+=( $! )

# pat tab 5
yadPat 5 
YAD_PIDs+=( $! )

# rigctld tab 6
yadRigctl 6
YAD_PIDs+=( $! )

# Make a pat web launcher script
cat > $TMPDIR/pat_web.sh <<EOF
xdg-open http://localhost:$PAT_HTTP_PORT >/dev/null 2>&1
EOF
chmod +x "$TMPDIR/pat_web.sh"

# Set up a yad notebook with the tabs.	
yadManager
MANAGER_PID=$!
echo "Manager started PID=$MANAGER_PID" | Sender "manager"
WID=''
while [[ -z $WID ]]
do
	WID=$(xdotool search --name "$MANAGER_TITLE" 2>/dev/null)
	sleep 0.5
done
GEOM=$(xdotool getwindowgeometry $WID)
if [[ -n $GEOM ]]
then
	POS=$(echo $GEOM | cut -d' ' -f4)
	LOC=$(echo $GEOM | cut -d' ' -f8)
	# Move monitor window so it doesn't sit under the manager window 	
	wmctrl -F -r "$MONITOR_TITLE" -e "0,$((${POS%,*} + ${LOC%x*} + 2)),${POSY},-1,-1"
fi
wait $MANAGER_PID
SafeExit 0
