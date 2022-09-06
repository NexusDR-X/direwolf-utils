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
#-    version         ${SCRIPT_NAME} 0.0.2
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
   kill $DIREWOLF_PID >/dev/null 2>&1
   kill $PAT_PID >/dev/null 2>&1
	kill $MONITOR_PID >/dev/null 2>&1
	kill -9 $ARDOP_PID  >/dev/null 2>&1
   for P in ${YAD_PIDs[@]}
	do
		kill $P >/dev/null 2>&1
	done
   kill $VIRTUAL_COM_PID >/dev/null 2>&1
   sudo pkill kissattach >/dev/null 2>&1
   rm -f /tmp/kisstnc
}

function TrapCleanup() {
   [[ -d "${TMPDIR}" ]] && rm -rf "${TMPDIR}/"
   kill $MANAGER_PID >/dev/null 2>&1
}

function SafeExit() {
	EXIT_CODE=${1:-0}
   trap - INT TERM EXIT SIGINT
	TrapCleanup
	KillApps
	#kill $RIGCTLD_PID >/dev/null 2>&1
   rm -f $PIPE
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

function Sender () {
	# Data piped to this function is sent to a socat pipe, prepended by the 
	# app name (optional) and a time stamp
   #declare input=${1:-$(</dev/stdin)}
   declare APP="${1:-}"
   [[ -n $APP ]] && APP=" ${APP}:"
   #cat -v | ts "${TIME_FORMAT}${APP}" | socat - udp-sendto:127.255.255.255:$SOCAT_PORT,broadcast
   stdbuf -oL ts "${TIME_FORMAT}${APP}" | socat - udp-sendto:127.255.255.255:$SOCAT_PORT,broadcast 
}

function getPlaybackDevices () {
	if pgrep pulseaudio >/dev/null 2>&1
   then # There may be pulseaudio ALSA devices.  Look for them.
      PLAYBACK_IGNORE="$(pacmd list-sources 2>/dev/null | grep name: | tr -d '\t' | cut -d' ' -f2 | sed 's/^<//;s/>$//' | tr '\n' '\|' | sed 's/|/\\|/g')"
      PLAYBACKs="$(aplay -L | grep -v "$PLAYBACK_IGNORE^ .*\|^dsnoop\|^sys\|^default\|^dmix\|^hw\|^hdmi\|^usbstream\|^jack\|^pulse\|^upmix\|^vdownmix\|^oss\|^speexrate\|^samplerate\|^surround\|^front\|^lavrate" | tr '\n' '!' | sed 's/!$//')"
   else  # pulseaudio isn't running.  Check only for null and plughw devices
      PLAYBACKs="$(aplay -L | grep "^null\|^plughw" | tr '\n' '!' | sed 's/!$//')"
   fi
   echo "$PLAYBACKs"
}

function getCaptureDevices () {
	if pgrep pulseaudio >/dev/null 2>&1
   then # There may be pulseaudio ALSA devices.  Look for them.
      CAPTURE_IGNORE="$(pacmd list-sinks 2>/dev/null | grep name: | tr -d '\t' | cut -d' ' -f2 | sed 's/^<//;s/>$//' | tr '\n' '\|' | sed 's/|/\\|/g')"
      CAPTUREs="$(arecord -L | grep -v "$CAPTURE_IGNORE^ .*\|^dsnoop\|^sys\|^default\|^dmix\|^hw\|^hdmi\|^usbstream\|^jack\|^pulse\|^upmix\|^vdownmix\|^oss\|^speexrate\|^samplerate\|^surround\|^front\|^lavrate" | tr '\n' '!' | sed 's/!$//')"
   else  # pulseaudio isn't running.  Check only for null and plughw devices
      CAPTUREs="$(arecord -L | grep "^null\|^plughw" | tr '\n' '!' | sed 's/!$//')"
   fi
   echo "$CAPTUREs"
}

#============================
#  Startup Functions
#============================

function setStartupDefaults () {
		declare -gA STARTUP_default
   	STARTUP_default[_PAT_START_]='TRUE'
   	STARTUP_default[_DIREWOLF_START_]='TRUE'
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
      echo "STARTUP[_PAT_START_]='${STARTUP_default[_PAT_START_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
      echo "STARTUP[_DIREWOLF_START_]='${STARTUP_default[_DIREWOLF_START_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
      echo "STARTUP[_ARDOP_START_]='${STARTUP_default[_ARDOP_START_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
		echo "STARTUP[_BOOTSTART_]='${STARTUP_default[_BOOTSTART_]}'" >> "$GUI_STARTUP_CONFIG_FILE"
	fi
	source "$GUI_STARTUP_CONFIG_FILE"
	BOOTSTARTs="disabled!none!1!12!13!14!123!124!134!1234!2!23!234!24!3!34!4"
	[[ $BOOTSTARTs =~ ${STARTUP[_BOOTSTART_]} && ${STARTUP[_BOOTSTART_]} =~ ^(none|[1-4]{1,4})$ ]] && BOOTSTARTs="$(echo "$BOOTSTARTs" | sed "s/!${STARTUP[_BOOTSTART_]}/!\^${STARTUP[_BOOTSTART_]}/1")" || BOOTSTARTs="^$BOOTSTARTs"
}

function updateStartupSettings () {
	[[ -s $TMPDIR/CONFIGURE_STARTUP.txt ]] || Die "Unexpected input from dialog"
	PREVIOUS_AUTOSTART="$STARTUP[_BOOTSTART_]"
	IFS='|' read -r -a TF < "$TMPDIR/CONFIGURE_STARTUP.txt"
  	echo "declare -gA STARTUP" > "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_PAT_START_]='${TF[0]}'" >> "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_DIREWOLF_START_]='${TF[1]}'" >> "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_ARDOP_START_]='${TF[2]}'" >> "$GUI_STARTUP_CONFIG_FILE"
	echo "STARTUP[_BOOTSTART_]='${TF[3]}'" >> "$GUI_STARTUP_CONFIG_FILE"
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
}

function yadStartup () {
   CMD=(	
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>Startup Configuration</big></big></b>\n\n \
	Click the <b>Save...</b> button below after you make your changes.\n"
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=10
			--form
			--columns=1
			--focus-field 1
			--field="Start pat when this manager [re]starts":CHK
			--field="Start Direwolf when this manager [re]starts":CHK
			--field="Start ARDOP when this manager [re]starts":CHK
			--field="Autostart this manager when\nthese piano switch levers are <b>ON</b>:":CB
			--
			"${STARTUP[_PAT_START_]}"
			"${STARTUP[_DIREWOLF_START_]}"
			"${STARTUP[_ARDOP_START_]}"
			"$BOOTSTARTs"
	)
	"${CMD[@]}" > $TMPDIR/CONFIGURE_STARTUP.txt &
	return $!
}

#============================
#  AX25 Functions
#============================

function setAX25Defaults () {
	declare -gA AX25_default
	AX25_default[_PORT_]="wl2k"		# AX25 port
   AX25_default[_TXDELAY_]="200"	# TX Delay
	AX25_default[_TXTAIL_]="50"		# TX Tail
   AX25_default[_PERSIST_]="64"	# Persist
   AX25_default[_SLOTTIME_]="20"	# Slot Time
}

function loadAX25Defaults () {
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
	[[ -s $TMPDIR/CONFIGURE_AX25.txt ]] || Die "Unexpected input from dialog"
	IFS='|' read -r -a TF < "$TMPDIR/CONFIGURE_AX25.txt"
  	echo "declare -gA AX25" > "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_PORT_]='${TF[0]}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_TXDELAY_]='${TF[1]}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_TXTAIL_]='${TF[2]}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_PERSIST_]='${TF[3]}'" >> "$GUI_AX25_CONFIG_FILE"
	echo "AX25[_SLOTTIME_]='${TF[4]}'" >> "$GUI_AX25_CONFIG_FILE"
	source "$GUI_AX25_CONFIG_FILE"
}

function yadAX25 () {
   CMD=(	
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>AX25 Configuration</big></big></b>\n\n \
	Click the <b>Save...</b> button below after you make your changes.\n"
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=20
			--form
			--columns=1
			--focus-field 1 
			--field="<b>AX25 Port</b>"
			--field="<b>TX Delay</b> (ms)":NUM
			--field="<b>TX Tail</b> (ms)":NUM
			--field="<b>Persist</b>":NUM
			--field="<b>Slot Time</b> (ms)":NUM
			--field="<b>Load Default AX25 Timers</b>":FBTN
			--
			"${AX25[_PORT_]}"
			"${AX25[_TXDELAY_]}!0..500!1!"
			"${AX25[_TXTAIL_]}!0..200!10!"
			"${AX25[_PERSIST_]}!0..255!1!"
			"${AX25[_SLOTTIME_]}!0..255!10!"
			"$load_ax25_defaults_cmd"
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
  	if [[ $ARDOP_PTTs =~ ${ARDOP[_PTT_]} ]]
   then
      ARDOP_PTTs="$(echo "$ARDOP_PTTs" | sed "s/${ARDOP[_PTT_]}/\^${ARDOP[_PTT_]}/")"
   else
      ARDOP_PTTs+="!^${ARDOP[_PTT_]}"
   fi
}

function updateARDOPSettings () {
	[[ -s $TMPDIR/CONFIGURE_ARDOP.txt ]] || Die "Unexpected input from dialog"
	IFS='|' read -r -a TF < "$TMPDIR/CONFIGURE_ARDOP.txt"
  	echo "declare -gA ARDOP" > "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_CAPTURE_]='${TF[0]}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_PLAYBACK_]='${TF[1]}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_PTT_]='${TF[2]}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_PORT_]='${TF[3]}'" >> "$GUI_ARDOP_CONFIG_FILE"
	echo "ARDOP[_ARGUMENTS_]='${TF[4]}'" >> "$GUI_ARDOP_CONFIG_FILE"
	source "$GUI_ARDOP_CONFIG_FILE"
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
Click the <b>Save...</b> button below after you make your changes.\n"
		--item-separator="!"
		--separator="|"
  		--text-align=center
  		--align=right
  		--borders=10
  		--form
		--columns=1
  	  	--field="<b>Audio Capture</b>":CB
  	  	--field="<b>Audio Playback</b>":CB
  	  	--field="<b>PTT</b>":CB
   	--field="<b>Port</b>":NUM
		--field="<b>piardopc</b> arguments\n(Usually not needed)":TEXT
  	  	--focus-field 1
		--
		"$ARDOP_CAPTUREs"
		"$ARDOP_PLAYBACKs"
		"$ARDOP_PTTs"
		"${ARDOP[_PORT_]}!8510..8519!1!"
		"${ARDOP[_ARGUMENTS_]}"
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
   DW_default[_ARATE_]="48000" 	# Audio playback rate (ARATE)
   DW_default[_PTT_]="GPIO 23" 	# GPIO PTT (BCM pin)
   DW_default[_AGWPORT_]="8001" 	# AGW Port
   DW_default[_KISSPORT_]="8011" # KISS Port
   DW_default[_AUDIOSTATS_]=0		# Audio stats print interval
   DW_default[_COLORS_]=0			# Terminal print colors
   DW_default[_CDIGIPEAT_]=''		# CDIGIPEAT arguments
   DW_default[_CFILTER_]=''		# CFILTER arguments
}

function loadDirewolfSettings () {
	 
	MODEMs="300!1200!2400!4800!9600"
   ARATEs="48000!96000"
   #ARATEs="48000"
   PTTs="GPIO 12!GPIO 23!RIG 2 localhost:4532"
	DW_CONFIG="$TMPDIR/direwolf.conf"

	if [ -s "$GUI_DIREWOLF_CONFIG_FILE" ]
	then # There is a config file
   	echo "$GUI_DIREWOLF_CONFIG_FILE found." | Sender "manager"
	else # Set some default values in a new config file
   	echo "Config file $GUI_DIREWOLF_CONFIG_FILE not found. Creating one." | Sender "manager"
		setDirewolfDefaults
   	echo "declare -gA DW" > "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CALL_]='${DW_default[_CALL_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_MODEM_]='${DW_default[_MODEM_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ADEVICE_CAPTURE_]='${DW_default[_ADEVICE_CAPTURE_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ADEVICE_PLAY_]='${DW_default[_ADEVICE_PLAY_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_ARATE_]='${DW_default[_ARATE_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_PTT_]='${DW_default[_PTT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_AUDIOSTATS_]='${DW_default[_AUDIOSTATS_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_AGWPORT_]='${DW_default[_AGWPORT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_KISSPORT_]='${DW_default[_KISSPORT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_COLORS_]='${DW_default[_COLORS_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CDIGIPEAT_]='${DW_default[_CDIGIPEAT_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
   	echo "DW[_CFILTER_]='${DW_default[_CFILTER_]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	fi
  	source "$GUI_DIREWOLF_CONFIG_FILE"
	MYCALL="${DW[_CALL_]}"
   [[ $MODEMs =~ ${DW[_MODEM_]} ]] && MODEMs="$(echo "$MODEMs" | sed "s/${DW[_MODEM_]}/\^${DW[_MODEM_]}/")"
   ADEVICE_CAPTUREs="$(getCaptureDevices)"
   ADEVICE_PLAYBACKs="$(getPlaybackDevices)"
   [[ -n ${DW[_ADEVICE_CAPTURE_]} && $ADEVICE_CAPTUREs =~ ${DW[_ADEVICE_CAPTURE_]} ]] && ADEVICE_CAPTUREs="$(echo "$ADEVICE_CAPTUREs" | sed -e "s/${DW[_ADEVICE_CAPTURE_]}/\^${DW[_ADEVICE_CAPTURE_]}/")"
   [[ $ADEVICE_CAPTUREs == "" ]] && ADEVICE_CAPTUREs="null"
   [[ -n ${DW[_ADEVICE_PLAY_]} && $ADEVICE_PLAYBACKs =~ ${DW[_ADEVICE_PLAY_]} ]] && ADEVICE_PLAYBACKs="$(echo "$ADEVICE_PLAYBACKs" | sed -e "s/${DW[_ADEVICE_PLAY_]}/\^${DW[_ADEVICE_PLAY_]}/")"
   [[ $ADEVICE_PLAYBACKs == "" ]] && ADEVICE_PLAYBACKs="null"

   [[ $ARATEs =~ ${DW[_ARATE_]} ]] && ARATEs="$(echo "$ARATEs" | sed -e "s/${DW[_ARATE_]}/\^${DW[_ARATE_]}/")"

	if [[ $PTTs =~ ${DW[_PTT_]} ]]
   then
      PTTs="$(echo "$PTTs" | sed "s/${DW[_PTT_]}/\^${DW[_PTT_]}/")"
   else
      PTTs+="!^${DW[_PTT_]}"
   fi
	
	AUDIOSTATs="0!15!30!45!60!90!120"
   [[ $AUDIOSTATs =~ ${DW[_AUDIOSTATS_]} ]] && AUDIOSTATs="$(echo "$AUDIOSTATs" | sed -e "s/${DW[_AUDIOSTATS_]}/\^${DW[_AUDIOSTATS_]}/")"

	AGWPORT="${DW[_AGWPORT_]}"
	KISSPORT="${DW[_KISSPORT_]}"
	CDIGIPEAT="${DW[_CDIGIPEAT_]}"
	CFILTER="${DW[_CFILTER_]}"
	if [[ -n $CDIGIPEAT ]]
	then
		CDIGIPEAT_CMD="CDIGIPEAT $CDIGIPEAT"
		[[ -n $CFILTER ]] && CFILTER_CMD="CFILTER $CFILTER" || CFILTER_CMD='' 
	else
		CDIGIPEAT_CMD=''
		CFILTER_CMD=''
	fi
	# Create a Direwolf config file with these settings
	cat > $DW_CONFIG <<EOF
ADEVICE ${DW[_ADEVICE_CAPTURE_]} ${DW[_ADEVICE_PLAY_]}
ACHANNELS 1
CHANNEL 0
ARATE ${DW[_ARATE_]}
PTT ${DW[_PTT_]}
MYCALL ${DW[_CALL_]}
MODEM ${DW[_MODEM_]}
AGWPORT ${DW[_AGWPORT_]}
KISSPORT ${DW[_KISSPORT_]}
$CDIGIPEAT_CMD
$CFILTER_CMD
EOF
}

function updateDirewolfSettings () {
	[[ -s $TMPDIR/CONFIGURE_DIREWOLF.txt ]] || Die "Unexpected input from dialog"
	IFS='|' read -r -a TF < "$TMPDIR/CONFIGURE_DIREWOLF.txt"
  	echo "declare -gA DW" > "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CALL_]='${TF[0]^^}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ADEVICE_CAPTURE_]='${TF[1]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ADEVICE_PLAY_]='${TF[2]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_ARATE_]='${TF[3]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_MODEM_]='${TF[4]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_PTT_]='${TF[5]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_AUDIOSTATS_]='${TF[6]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_AGWPORT_]='${TF[7]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_KISSPORT_]='${TF[8]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_COLORS_]='${TF[9]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CDIGIPEAT_]='${TF[10]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	echo "DW[_CFILTER_]='${TF[11]}'" >> "$GUI_DIREWOLF_CONFIG_FILE"
	source "$GUI_DIREWOLF_CONFIG_FILE"
}

function yadDirewolf () {
   CMD=(
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>Direwolf Configuration</big></big></b>\n\n \
<b><u><big>Typical Direwolf Sound Card and PTT Settings for Nexus DR-X</big></u></b>\n \
<span color='blue'><b>LEFT Radio:</b></span> Use ADEVICEs \
<b>fepi-capture-left</b> and <b>fepi-playback-left</b> and PTT <b>GPIO 12</b>.\n \
<span color='blue'><b>RIGHT Radio:</b></span> Use ADEVICEs \
<b>fepi-capture-right</b> and <b>fepi-playback-right</b> and PTT <b>GPIO 23</b>.\n\n \
Click the <b>Save...</b> button below after you make your changes.\n"
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=10
			--form
			--columns=2
			--focus-field 1
			--field="<b>Call Sign</b>"
			--field="<b>ADEVICE Capture</b>":CB
			--field="<b>ADEVICE Playback</b>":CB
			--field="<b>Direwolf ARATE</b>":CB
			--field="<b>Direwolf MODEM</b>":CB
			--field="<b>Direwolf PTT</b>":CBE
			--field="<b>Audio Stats interval (s)</b>":CB
			--field="<b>AGW Port</b>":NUM
			--field="<b>KISS Port</b>":NUM
			--field="<b>Text colors</b> (0=off)":NUM
			--field="Optional <b>CDIGIPEAT</b> arguments\n(Format&#x3A; <b>0 0</b> [<i>aliases</i>])"
			--field="Optional <b>CFILTER</b> arguments\n(Format&#x3A; <b>0 0</b> <i>filter-expression</i>)"
			--
			"$MYCALL"
			"$ADEVICE_CAPTUREs"
			"$ADEVICE_PLAYBACKs"
			"$ARATEs"
			"$MODEMs"
			"$PTTs"
			"$AUDIOSTATs"
			"$AGWPORT!8001..8010!1!"
			"$KISSPORT!8011..8020!1!"
			"${DW[_COLORS_]}~0..4~1~"
			"$CDIGIPEAT"
			"$CFILTER"
	)
	"${CMD[@]}" > $TMPDIR/CONFIGURE_DIREWOLF.txt &
	return $!
}

#============================
#  pat Functions
#============================

function loadPatSettings () {
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
}

function updatePatSettings () {
	# Update the pat config.json file with the new data.
	[[ -s $TMPDIR/CONFIGURE_PAT.txt ]] || Die "Unexpected input from dialog"
	IFS='|' read -r -a TF < "$TMPDIR/CONFIGURE_PAT.txt"
	PAT_CALL="${TF[0]^^}"
	PAT_PASSWORD="${TF[1]}"
	PAT_LOCATOR="${TF[2]^^}"
	PAT_HTTP_PORT="${TF[3]}"
	PAT_TELNET_PORT="${TF[4]}"
	PAT_TELNET_PASSWD="${TF[5]}"
	PAT_AX25_BEACON_INTERVAL="${TF[6]}"
	PAT_AX25_BEACON_MESSAGE="${TF[7]}"
	PAT_ARQ_BW_FORCED="${TF[8]}"
	PAT_ARQ_BW_MAX="${TF[9]}"
	PAT_ARDOP_BEACON_INTERVAL="${TF[10]}"
	PAT_CW_ID="${TF[11]}"
	PAT_ARDOP_PTT="${TF[12]}"
	cat $PAT_CONFIG | jq \
		--arg C "$PAT_CALL" \
		--arg P "$PAT_PASSWORD" \
		--arg H "0.0.0.0:$PAT_HTTP_PORT" \
		--arg T "0.0.0.0:$PAT_TELNET_PORT" \
		--arg A "$PAT_TELNET_PASSWD" \
		--arg L "$PAT_LOCATOR" \
		--argjson X $PAT_AX25_BEACON_INTERVAL \
		--arg M "$PAT_AX25_BEACON_MESSAGE" \
		--arg R "127.0.0.1:${ARDOP[_PORT_]}" \
		--argjson F ${PAT_ARQ_BW_FORCED,,} \
		--argjson B $PAT_ARQ_BW_MAX \
		--argjson D ${PAT_CW_ID,,} \
		--argjson K ${PAT_ARDOP_PTT,,} \
		--argjson I $PAT_ARDOP_BEACON_INTERVAL \
			'.mycall = $C | .secure_login_password = $P | .http_addr = $H | .ardop.addr = $R | .telnet.listen_addr = $T | .telnet.password = $A |.locator = $L | .ax25.beacon.every = $X | .ax25.beacon.message = $M | .ardop.beacon_interval = $I | .ardop.arq_bandwidth.Max = $B | .ardop.arq_bandwidth.Forced = $F | .ardop.cwid_enabled = $D | .ardop.ptt_ctrl = $K' | sponge $PAT_CONFIG
}

function yadPat () {
   CMD=(	
		yad --plug="$ID" --tabnum=$1
			--text="<b><big><big>pat Configuration</big></big></b>\n \
	Click the <b>Save...</b> button below after you make your changes."
			--item-separator="!"
			--separator="|"
			--text-align=center
			--align=right
			--borders=10
			--form
			--columns=2
			--focus-field 1 
			--field="Call Sign"
			--field="Winlink Password":H
			--field="Locator Code"
			--field="Web Service Port":NUM
			--field="Telnet Service Port":NUM
			--field="Telnet Service Password\n(default&#x3A; no password)"
			--field="Packet Beacon Interval\n(s) (0 disables beacon)":NUM
			--field="Packet Beacon Message"
			--field="ARDOP Forced ARQ Bandwidth":CHK
			--field="ARDOP Max ARQ\nBandwidth (Hz)":CB
			--field="ARDOP Beacon Interval\n(seconds), 0 disables":NUM
			--field="ARDOP: Enable CW ID":CHK
			--field="ARDOP: pat controls PTT":CHK
			--field='':LBL
			--field="<b>Edit pat Connection Aliases</b>":FBTN
			--
			"$PAT_CALL"
			"$PAT_PASSWORD"
			"$PAT_LOCATOR"
			"$PAT_HTTP_PORT!8040..8049!1!"
			"$PAT_TELNET_PORT!8770..8779!1!"
			"$PAT_TELNET_PASSWD"
			"$PAT_AX25_BEACON_INTERVAL!0..7200!1!"
			"$PAT_BEACON_MESSAGE"
			"$PAT_ARQ_BW_FORCED"
			"$PAT_ARQ_BW_MAXs"
			"$PAT_ARDOP_BEACON_INTERVAL!0..7200!1!"
			"$PAT_CW_ID"
			"$PAT_ARDOP_PTT"
			''
			"bash -c edit_pat_aliases.sh &"
	)		
	"${CMD[@]}" > $TMPDIR/CONFIGURE_PAT.txt &
	return $!
}

#============================
#  rigctl Functions
#============================

function yadRigctl () {
	RIGCTL_INFO=" \
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
		--field="<b>Manage Hamlib rigctld</b>":FBTN "bash -c rigctl_gui.sh >/dev/null &" >/dev/null &
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
  		--text-align="center" --notebook --key="$ID" \
  		--posx=$POSX --posy=$POSY \
  		--buttons-layout=center \
  		--tab="Startup" \
  		--tab="AX25" \
  		--tab="ARDOP" \
  		--tab="Direwolf" \
  		--tab="pat" \
  		--tab="Rig Control" \
  		--button="<b>Stop &#x26; Exit</b>":1 \
  		--button="<b>Save &#x26; Restart</b>":0 \
  		--button="<b>Open pat Web interface</b>":"bash -c $TMPDIR/pat_web.sh" \
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
TMPDIR="/tmp/${SCRIPT_NAME}.$RANDOM.$RANDOM.$RANDOM.$$"
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
GUI_STARTUP_CONFIG_FILE="$CONFIG_DIR/tnc_gui_startup.conf"
GUI_DIREWOLF_CONFIG_FILE="$CONFIG_DIR/tnc_gui_direwolf.conf"
GUI_ARDOP_CONFIG_FILE="$CONFIG_DIR/tnc_gui_ardop.conf"
GUI_AX25_CONFIG_FILE="$CONFIG_DIR/tnc_gui_ax25.conf"
MESSAGE="Direwolf Configuration"

ID="${RANDOM}"

SOCAT_PORT=3333
# YAD Dialog Window settings
POSX=20 
POSY=50 
WIDTH=300
HEIGHT=200
TIME_FORMAT="%Y/%m/%d %H:%M:%S"
AX25PORT="wl2k"
AX25PORTFILE="/etc/ax25/axports"
PAT_VERSION="$(pat version | cut -d' ' -f2)"
[[ $PAT_VERSION =~ v0.1[01]. ]] && PAT_CONFIG="$HOME/.wl2k/config.json" || PAT_CONFIG="$HOME/.config/pat/config.json"
VIRTUAL_COM_SPEED=38400
VIRTUAL_COM_PORT="/tmp/vcom0"
VIRTUAL_COM="${VIRTUAL_COM_PORT}:$VIRTUAL_COM_SPEED"
RIGCTLD_PORT="4532"
VIRTUAL_COM_SOCAT="socat pty,link=${VIRTUAL_COM_PORT},waitslave,b${VIRTUAL_COM_SPEED} tcp:localhost:${RIGCTLD_PORT},retry"
RIGCTL_PTT_ON="5420310A"
RIGCTL_PTT_OFF="5420300A"
RIGCTLD_PORT=4532
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

# Ensure only one instance of this script is running.
pidof -o %PPID -x $(basename "$0") >/dev/null && exit 1

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

# If this is the first time running this script, don't attempt to start until user configures
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

# Set up pat for rigctl network connection in config.json
cat $PAT_CONFIG | jq \
   '.hamlib_rigs += {"network": {"address": "localhost:4532", "network": "tcp"}}' | sponge $PAT_CONFIG
# Add the network Hamlib rig to the ax25 and ardop sections
cat $PAT_CONFIG | jq --arg R "network" '.ax25.rig = $R' | sponge $PAT_CONFIG
cat $PAT_CONFIG | jq --arg R "network" '.ardop.rig = $R' | sponge $PAT_CONFIG

export -f setAX25Defaults loadAX25Defaults
export load_ax25_defaults_cmd='@bash -c "setAX25Defaults; loadAX25Defaults"'
export click_help_cmd='bash -c "xdg-open /usr/local/share/nexus/tnc_manager_help.html"'

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

while true
do
	YAD_PIDs=()
	
	# Kill any running processes and remove temporary config files
	KillApps
	DIREWOLF_PID=''
	PAT_PID=''
	RIGCTLD_PID=$(pgrep rigctld)
	PIARDOPC_PID=''
	VIRTUAL_COM_PID=''
	for F in DIREWOLF PAT ARDOP AX25 STARTUP
	do
		rm -f $TMPDIR/CONFIGURE_${F}.txt
	done
	
	# Start monitor window
	MONITOR_PID=''
	MONITOR_TITLE="TNC and pat Monitor $VERSION"
	lxterminal --geometry=80x20 -t "$MONITOR_TITLE" -e "socat udp-recv:$SOCAT_PORT,reuseaddr -" &
	while [[ -z $MONITOR_PID ]]
	do
		MONITOR_PID=$(lsof -t -i udp:$SOCAT_PORT)
		sleep 0.5
	done
	echo "Monitor window PID=$MONITOR_PID" | Sender "manager"

	# Load settings from configuration files
	loadStartupSettings
	loadAX25Settings
	loadARDOPSettings
	loadDirewolfSettings
	loadPatSettings

	# Start rigctld.
	if [[ -n $RIGCTLD_PID ]]
	then
		echo "rigctld already running." | Sender "manager"
	else # Start rigctl as a dummy rig because we have no idea what rig is used.
		echo "Starting rigctld using dummy rig..." | Sender "manager"
		($(command -v rigctld) -m 1 2>&1 | Sender 'rigctld') &
		RIGCTLD_PID=$(pgrep -f "$(command -v rigctld) -m 1")
		echo "Done." | Sender "manager"
	fi

	if [[ $FIRST_RUN == true ]]
	then
		echo -e "Configure TNC and pat in the GUI,\nthen click \"Save...\" button." | Sender "manager"
	else # Not a first run.  pat and Direwolf configured so start 'em
		# Configure /etc/ax25/axports if necessary.  This is needed in order to allocate a PTY for pat.
		if ! grep -q "^${AX25[_PORT_]}[[:space:]]*${PAT_CALL}" $AX25PORTFILE 2>/dev/null
		then #$AX25PORT $MYCALL entry not found
			# Remove existing lines with $AX25PORT and any empty lines if present
			sudo sed -i -e "s/^${AX25[_PORT_]}[[:space:]].*$//g" -e '/^[[:space:]]*$/d' $AX25PORTFILE
			# Add the entry for $MYCALL
			echo "${AX25[_PORT_]}	$PAT_CALL	0	255	7	Winlink" | sudo tee --append $AX25PORTFILE >/dev/null
		fi
		
		if [[ ${STARTUP[_DIREWOLF_START_]} == TRUE ]]
		then
			# Start Direwolf
			# Direwolf does not allow embedded spaces in timestamp format string -T
			#DIREWOLF="$(command -v direwolf) -p -t 0 -d u -T "%Y%m%dT%H:%M:%S""
			DIREWOLF="$(command -v direwolf) -p -t ${DW[_COLORS_]} -d u -a ${DW[_AUDIOSTATS_]}"
			echo -e "\nUsing Direwolf configuration:" | Sender "direwolf"
			cat "$DW_CONFIG" | Sender "direwolf"
			($DIREWOLF -c $DW_CONFIG 2>&1 | Sender "direwolf") & 
			DIREWOLF_PID=$(pgrep -f "^$DIREWOLF -c $DW_CONFIG")
			echo "Direwolf TNC has started.  PID=$DIREWOLF_PID" | Sender "direwolf"
			# Wait for Direwolf to allocate a PTY
			COUNTER=0
			MAXWAIT=8
			while [ $COUNTER -lt $MAXWAIT ]
			do # Allocate a PTY to ax25
				[ -L /tmp/kisstnc ] && break
				sleep 1
				let COUNTER=COUNTER+1
			done
			if [ $COUNTER -ge $MAXWAIT ]
			then
				Die "Direwolf failed to allocate a PTY! Aborting. Is ADEVICE set to your sound card?"
			fi
			echo "Direwolf has allocated a PTY." | Sender "direwolf"
			echo "kissattach to this PTY." | Sender "kissattach"

			# Start kissattach on new PTY
			sudo $(command -v kissattach) $(readlink -f /tmp/kisstnc) ${AX25[_PORT_]} 2>&1 | Sender "kissattach"
			if [ ${PIPESTATUS[0]} -ne 0 ]
			then
				echo "kissattach FAILED." | Sender "kissattach"
				Die "kissattach failed.  Aborting."
			fi
		
			# Set KISS parameters
			KISSPARMS="-c 1 -p ${AX25[_PORT_]} -t ${AX25[_TXDELAY_]} -l ${AX25[_TXTAIL_]} -s ${AX25[_SLOTTIME_]} -r ${AX25[_PERSIST_]} -f n"
			echo "Setting $(command -v kissparms) $KISSPARMS" | Sender "kissparms"
			sleep 2
			sudo $(command -v kissparms) $KISSPARMS 2>&1 | Sender "kissparms"
			[ ${PIPESTATUS[0]} -eq 0 ] || Die "kissparms settings failed.  Aborting."
		fi

		if [[ ${STARTUP[_ARDOP_START_]} == TRUE ]]
		then
			# Start ARDOP
			PIADROPC_ARGUMENTS="${ARDOP[_PORT_]} ${ARDOP[_CAPTURE_]} ${ARDOP[_PLAYBACK_]}"
			[[ -n ${ARDOP[_ARGUMENTS_]} ]] && PIADROPC_ARGUMENTS+=" ${ARDOP[_ARGUMENTS_]}"
			[[ ${ARDOP[_PTT_]} =~ GPIO ]] && PIADROPC_ARGUMENTS+=" -g=${ARDOP[_PTT_]#* }"
			if [[ ${ARDOP[_PTT_]} =~ rigctld ]]
			then
				if lsof -t -i tcp:$RIGCTLD_PORT 2>&1 >/dev/null
				then
					($VIRTUAL_COM_SOCAT 2>&1 | Sender "socat") &
					VIRTUAL_COM_PID=$(pgrep -f "$VIRTUAL_COM_SOCAT")
					if [[ -n $VIRTUAL_COM_SOCAT ]]
					then
						echo "Virtual serial port $VIRTUAL_COM_PORT created (PID=${VIRTUAL_COM_PID}) and connected to rigctld" | Sender "manager"
						PIADROPC_ARGUMENTS+=" --cat=${VIRTUAL_COM} -k $RIGCTL_PTT_ON -u $RIGCTL_PTT_OFF"	
					else
						echo "ERROR! Virtual serial port $VIRTUAL_COM_PORT creation FAILED. ARDOP PTT disabled." | Sender "manager"
					fi
				else
					# rigctld isn't running so no point in setting up virtual com port
					echo "ERROR! rigctld not listening on $RIGCTLD_PORT. ARDOP PTT disabled." | Sender "manager"
				fi
			fi
			PIARDOPC="$(command -v piardopc) $PIADROPC_ARGUMENTS"
			($PIARDOPC 2>&1 | Sender "ardop") &
			ARDOP_PID=$(pgrep -f "$PIARDOPC")
			echo "piardopc has started PID=$ARDOP_PID" | Sender "ardop"
		fi
		
		# Start pat
		if [[ ${STARTUP[_PAT_START_]} == TRUE ]]
		then
			PAT_LISTENERS="-l telnet"
			[[ ${STARTUP[_DIREWOLF_START_]} == TRUE ]] && PAT_LISTENERS+=",ax25"
			[[ ${STARTUP[_ARDOP_START_]} == TRUE ]] && PAT_LISTENERS+=",ardop"
			PAT="$(command -v pat) $PAT_LISTENERS http"
			($PAT 2>&1 | Sender "pat") &
			PAT_PID=$(pgrep -f "$PAT")
		else
			PAT_PID=""
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

	if [[ -z $PAT_PID ]]
	then
		cat > $TMPDIR/pat_web.sh <<EOF
yad --center --title="Error" --borders=20 --text "<b>pat is not running.\nNo web interface to open.</b>" --button="Close":0 --buttons-layout=center
EOF
	else
		cat > $TMPDIR/pat_web.sh <<EOF
xdg-open http://$HOSTNAME.local:$PAT_HTTP_PORT >/dev/null 2>&1
EOF
	fi
	chmod +x $TMPDIR/pat_web.sh

	# Set up a yad notebook with the tabs.	
	yadManager
  	MANAGER_PID=$!
  	echo "Manager window PID=$MANAGER_PID" | Sender "manager"
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
	RETURN_CODE=$?

	case $RETURN_CODE in
		0) # Read and handle the data from each yad tab instance
			updateStartupSettings
			updateAX25Settings
			updateARDOPSettings
			updateDirewolfSettings
			updatePatSettings
		;;
		*) # User click Exit button or closed window. 
			break
			;;
	esac
done
SafeExit 0
