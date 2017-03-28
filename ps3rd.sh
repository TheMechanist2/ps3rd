#!/bin/bash
# PS3 Remote Control Daemon (PS3RD)
# by -~= The Mechanist =~- 08-12-2015
# Update: 03-12-2017
# GPL3 Licensed
# since it's meant to be used with kodi, check forum.kodi.tv for support / help 
# http://forum.kodi.tv/showthread.php?tid=251308
#
# Dependencies: bash4, curl, logger, sed, grep
#
# ! requires advanced privileges (e.g. root) cause of access to /dev/input 
# ! daemonize with & 
# you'll find it useful to add it to init system of your distribution to run at start up 
# (e.g. ubuntu 14.04: cp to /usr/bin, chown root, add /etc/rc.local with &)
#
# Known to run well ;-) Ubuntu 14.04 + Kodi 15.2 + PS3 BD Remote + bluez (v. 4.xx) /blueman 
# Works with Kodi Jarvis, Krypton 17.1
# *** Ubuntu 16.04 & bluez (v. 5.37): needs changes to line 222 !

#
# activate webserver & remote control, enter adress (e.g. http://127.0.0.1:8080)
#
KODI_HOST=""
# your secret as set in kodi ..
USER_NAME=""
USER_PW=""

#
# at least at debian based systems ..
# check /proc/bus/input/devices for the remote name: e.g. Ubuntu 16.04 with bluez 5.37 - "BD Remote Control"
#

PS3_CONTROLLER_NAME="PS3 Remote Controller"
INPUT_DEVICES="/proc/bus/input/devices"
INPUT_INTERFACES="/dev/input/"

#
# if in debug mode (0) output to console, else (1) to log via logger (syslog)
# if script doesn't work, start from command line with debug set to 0 to see, if the keys are correctly recognized
#

DEBUG=1

#
# will hold the interface
#

ps3_interface=""

#
# Translation table
# Hashtable (bash v. > 4) with key strokes and KODI JSON RPC Commands
# to get more key codes just run sudo hexdump -s 18 -n 2 -e '1/2 "%04x"' /dev/input/eventXY from command line
# for more KODI JSON RPC Commands check their website
# http://kodi.wiki/view/JSON-RPC_API/v6
# http://kodi.wiki/view/Window_IDs
# http://kodi.wiki/view/Action_IDs
#
# Input.ContextMenu, Input.Down, Input.Back, Input.Home, Input.Info
# Input.Left, Input.Right, Input.Select, Input.ShowOSD, Input.Up
# Application.Quit, Application.SetMute param: globaltoggle mute
# Application.SetVolume params mixed volume 
# PVR.Record [ Global.Toggle record = "toggle" ] [ mixed channel = "current" ] 
# System.EjectOpticalDrive, Player.PlayPause
# System.Shutdown
#

METHOD_HEADER='{"jsonrpc": "2.0", "method": '

#
# create hash table (bash v. 4)
#

declare -A PS3_TO_KODI

#
# define some actions
# bluez recognizes PS3 BD Remote as kbd and maps some keys (eg. 0-9, Return)
# these keys can't be remapped that way !
#


# STOP
PS3_TO_KODI[0080]='"Input.ExecuteAction", "params": {"action": "stop"}'
# Pause
PS3_TO_KODI[0077]='"Input.ExecuteAction", "params": {"action": "pause"}'
# Play
PS3_TO_KODI[00cf]='"Input.ExecuteAction", "params": {"action": "play"}'
# Step +
PS3_TO_KODI[01b5]='"Input.ExecuteAction", "params": {"action": "stepforward"}'
# Step -
PS3_TO_KODI[01b4]='"Input.ExecuteAction", "params": {"action": "stepback"}'
# Next
PS3_TO_KODI[0197]='"Input.ExecuteAction", "params": {"action": "skipnext"}'
# Prev
PS3_TO_KODI[019c]='"Input.ExecuteAction", "params": {"action": "skipprevious"}'
# Scan +
PS3_TO_KODI[009f]='"Input.ExecuteAction", "params": {"action": "fastforward"}'
# Scan -
PS3_TO_KODI[00a8]='"Input.ExecuteAction", "params": {"action": "rewind"}'
# View/Square -> Fullscreen
PS3_TO_KODI[0177]='"Input.ExecuteAction", "params": {"action": "fullscreen"}'
# R1 -> Volume +
PS3_TO_KODI[0137]='"Input.ExecuteAction", "params": {"action": "volumeup"}'
# L1 -> Volume -
PS3_TO_KODI[0136]='"Input.ExecuteAction", "params": {"action": "volumedown"}'
# Time -> Show Time
PS3_TO_KODI[0167]='"Input.ExecuteAction", "params": {"action": "showtime"}'
# Start -> Play DVD
PS3_TO_KODI[013b]='"Input.ExecuteAction", "params": {"action": "playdvd"}'
# POP UP/MENU
PS3_TO_KODI[01b6]='"Input.ContextMenu"'
# RED -> Teletext
PS3_TO_KODI[018e]='"GUI.ActivateWindow", "params": {"window": "teletext"}'
# GREEN -> EPG
PS3_TO_KODI[018f]='"GUI.ActivateWindow", "params": {"window": "tvguide"}'
# Display -> Info
PS3_TO_KODI[0166]='"Input.ExecuteAction", "params": {"action": "info"}'
# Eject -> Shutdown Menu
PS3_TO_KODI[00a1]='"GUI.ActivateWindow", "params": {"window": "shutdownmenu"}'
# Top Menu -> videoosd
PS3_TO_KODI[008b]='"GUI.ActivateWindow", "params": {"window": "videoosd"}'
# Audio -> Audio Settings
PS3_TO_KODI[0188]='"GUI.ActivateWindow", "params": {"window": "osdaudiosettings"}'
# Angle -> Video Settings
PS3_TO_KODI[0173]='"GUI.ActivateWindow", "params": {"window": "osdvideosettings"}'
# Subtitle -> subtitlesearch
PS3_TO_KODI[0172]='"Input.ExecuteAction", "params": {"action": "showsubtitles"}'
# Yellow -> PVR OSD -> Channel EPG
PS3_TO_KODI[0190]='"GUI.ActivateWindow", "params": {"window": "pvrosdguide"}'
# Blue -> PVR OSD -> Channel List
PS3_TO_KODI[0191]='"GUI.ActivateWindow", "params": {"window": "pvrosdchannels"}'
# Options -> Settings
PS3_TO_KODI[0165]='"GUI.ActivateWindow", "params": {"window": "settings"}'
# Select -> Select Dialog
PS3_TO_KODI[0161]='"Input.ExecuteAction", "params": {"action": "select"}'

#
# write to logfile if not in debug mode
#

function output() {
    if [ $DEBUG -eq 1 ]; then
		logger $1
    else
		echo $1
    fi
}

#
# Check for PS3 Remote and return interface to the remote controller
# set ps3_interface if found with return code 0
#

function find_ps3_remote() {

	# Check INPUT_DEVICES if PS3 remote is connected
	# grep -n: exact line number of match

	local avail=$(grep -n "$PS3_CONTROLLER_NAME" "$INPUT_DEVICES")

	if [ -n "$avail" ]; then

		# Controller found 
		# find connected interface /dev/input/eventXY
		# grep told us line number of information block
		# we need the 4. line below that line, which is containing controller name

		local line_number=$(expr match "$avail" '\([0-9]*\)')
		linenumber=$((line_number+4))

		# let's use sed to get that special line
		# cmd for sed to return just one line from a file

		local sed_cmd=$linenumber"q;d"

		# get the line with event code for ps3 controller and grep the right interface

		local new_interface=$INPUT_INTERFACES$(sed $sed_cmd $INPUT_DEVICES | grep -o "event[0-9]*")
		if [ "$new_interface" != "$ps3_interface" ]; then
		    output "PS3RD: Found PS3 BD Remote connected to $new_interface"
		    ps3_interface=$new_interface
		fi 

		return 0
	else
		# Not found, maybe disconnected
		# reset interface
		if [ -n "$ps3_interface" ]; then
		    output "PS3RD: PS3 BD Remote disconnected"
		    output "PS3RD: Waiting for PS3 BD Remote"
		    ps3_interface=""
		fi
		return 1
	fi
}

#
# - Basic knowlegde about input handling -
#
# https://www.kernel.org/doc/Documentation/input/input.txt
# /dev/input/event* : defined in include/linux/input.h
# http://lxr.free-electrons.com/source/include/linux/input.h
#
# input event results in: struct timeval time (2 * _kernel_long_t), __u16 type, __u16 code and __s32 value
# timestamp, eventtype, eventcode and eventvalue (?)
# 'cause of time size differs between hw architectures 
#
# Assuming x86 64 bit: timeval: timeval 2 * 64 Bit, type: 16 Bit, code: 16 Bit, value: 32 Bit
# One key press should result in a block of 3 * 64 Bit = 24 Bytes
# for an unknown reason every block is 48 bytes long and contains the information twice

# hexdump reads (binary) file and returns hex values
# option 	-s: skip given number of bytes - 18 bytes (timeval & type of event)
#			-n: read ony given number of bytes - code of event 
#			-e: format string: output 1 block of two bytes (u16) als 4 digit hex value
#

function ps3_to_kodi() {
	local ps3_command=""
	local last_command=""
	local rpc_command=""

	# infinite loop
	while : 
	do
	    # hexdumps waits for event .. redirect stdrr output
	    # !!!! This line is imported to recognize the pressed keys !!!!
	    # Obviously it could differ from os to os or bluetooth stack versions:
	    # in Ubuntu 16.04 with bluez 5.37 change "-s 18" to "-s 42" (offset in data for the keys), try with debug mode enabled
	    
	    last_command=$(hexdump -s 18 -n 2 -e '1/2 "%04x"' "$ps3_interface" 2> /dev/null)
		
		# hexdump exits with 1 when something went wrong, especially when event handler disconnected 
		if [ $? != 0 ] || [ -z $last_command ] || [ "$last_command" = "0000" ]; then
			break
		fi	

	    # PS3 BD Remote sends command if key is pressed and released, catch release event
	    if [ "$ps3_command" = "$last_command" ]; then
			ps3_command=""
	    else
			# Key ..
			ps3_command=$last_command
			# .. to RPC Command
			rpc_command=$METHOD_HEADER${PS3_TO_KODI[$ps3_command]}'}'

			# Quite interessting for debug but too much for log file
			if [ $DEBUG -eq 0 ]; then
				echo "Key Code: $ps3_command"
				echo "RPC Command: $rpc_command"
			fi

			# Send only mapped events to server
			if [ -n "${PS3_TO_KODI[$ps3_command]}" ]; then
				# let's use curl (in silent mode) for sending the right kodi rpc command
				# credits fly to dataolle for sendxbmc script https://gist.github.com/dataolle/4207390
				curl --silent -f -u "$USER_NAME":"$USER_PW" -d "$rpc_command" -H "Content-type:application/json" -X POST "${KODI_HOST}/jsonrpc" > /dev/null
			fi

	    fi
	done
	
	return 0
}

#
#  main rockz .. every real programmer should have a main() at home ;-)
#

function main() {
	output "PS3RD: Waiting for PS3 BD Remote"

	# infinite loop
	while :
	do
		# any PS3 BD Remote connected ?
		if ! find_ps3_remote ; then

			# wait for 5 seconds, it's bluetooth, maybe just disconnected to change batteries 
			sleep 5
		
		# found .. but do we have enough privileges ?
		elif [ ! -r $ps3_interface ]; then
			output "PS3RD: Not enough privileges to read PS3 BD event interface $ps3_interface !"
			output "PS3RD: Shutting down"
			exit 2

		# PS3 BD Remote is connected and we got the privileges .. it's time to do something 
		else
			output "PS3RD: Key translation thread started"
			ps3_to_kodi
			output "PS3RD: Key translation thread stopped"
		fi
	done
	exit 0
}

#
# check if daemon is already running
# any processes with the same name ${0##*/} of script but with different PID than own PID $$ ?
#

output "PS3RD: Starting"
match_string=^.*$$
match_string2=.*${0##*/}
ps -A c | grep -v "$match_string" | grep "$match_string2" > /dev/null
if [ $? -eq 0 ] ; then
	output "PS3RD: ${0##*/} is already running !"
	output "PS3RD: Shutting down"
	exit 1
fi

main
exit 0
