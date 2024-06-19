#!/usr/bin/env bash
[[ $DEBUG ]] && set -x
set -o errexit -o pipefail
shopt -s globstar nullglob


help_doc() {
	{ IFS= read -rd '' || printf '%s' "$REPLY" 1>&2; } <<-'HelpDoc'

		date-zones.bash [OPTION] [TIMEZONE...]

		Outputs the date for the first TIMEZONE and converts that date to all subsequent TIMEZONEs

		If no TIMEZONEs are provided the system timezone is used

		TIMEZONE:
		  _                       Use fzf to pick a timezone
		  utc                     Alias for Etc/UTC
		  local                   Use system timezone
		  LOCALE                  A standard locale, ex: America/Los_Angeles

		OPTION:
		  --date|-d DATE          Date to use for first timezone
		                          Default: 'now'
		  +FORMAT                 Date output format
		                          Default: '+%Y-%m-%d %I:%M:%S %p %Z'
		  --24hr                  Use 24hr clock for default date format
		  --silent|-s             Only output dates
		  --help                  Display help

		EXAMPLES:
		  # Output what UTC time will be next wed @ 2pm and convert it to local time and a timezone picked from fzf
		  date-zones.bash +%Y-%m-%dT%H:%M:%S -d 'wed 2pm' utc local _

		  # Output what local time will be in 2hrs and convert it to Los_Angeles and London time
		  date-zones.bash -d '2 hours' local America/Los_Angeles Europe/London

	HelpDoc
	[[ $1 ]] && exit "$1"
}



print_stderr() {
	if [[ $1 == '0' ]]; then
		[[ $2 ]] && printf "$2" "${@:3}" 1>&2 || :
	else
		[[ $2 ]] && printf '%s'"$2" "ERROR: ${0##*/}, " "${@:3}" 1>&2 || :
		exit "$1"
	fi
}



# Define defaults
date_str='now'
format='+%Y-%m-%d %I:%M %p %Z'
timezones=()
timezones_formatted=()
print_stderr__silent=
config_dir=${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}'/date-zones.bash'
declare -A timezone_aliases=(
	['utc']='Etc/UTC'
	['UTC']='Etc/UTC'
)



# Handle parameters
[[ $1 ]] || help_doc
while [[ $1 ]]; do
	case $1 in
		'-d'|'--date')
			shift; date_str=$1 ;;
		'+'*)
			format=$1 ;;
		'--24hr')
			format='+%Y-%m-%d %H:%M %Z' ;;
		'-s'|'--silent')
			print_stderr__silent=1 ;;
		'--help'|'-h')
			help_doc 0 ;;
		'--')
			shift; break ;;
		'-'*)
			print_stderr 1 '%s\n' 'unrecognized parameter: '"$1" ;;
		*)
			timezones+=("$1") ;;
	esac
	shift
done
timezones+=("$@")



# Check dependencies
type date 1>/dev/null



# Define functions
insert_arr_at_index(){
	local -n \
		insert_arr_at_index__source=$1 \
		insert_arr_at_index__destination=$2

	local \
		index=${3:-0} \
		index_offset_pre=${4:-0} \
		index_offset_post=${5:-0}

	insert_arr_at_index__destination=(
		"${insert_arr_at_index__destination[@]:0:index+index_offset_pre}"
		"${insert_arr_at_index__source[@]}"
		"${insert_arr_at_index__destination[@]:index+index_offset_post}"
	)
}



# Load aliases
if [[ -f $config_dir'/aliases' ]]; then
	while read -r timezone_alias timezone; do
		[[ $timezone_alias && $timezone ]] || continue
		timezone_aliases[$timezone_alias]=$timezone
	done < "$config_dir"'/aliases'
fi



# Define fzf timezone picker
get_tz() {
	local tz_path fzf_params

	# Check for fzf
	type fzf 1>/dev/null

	fzf_params=(
		'-i'		# Case-incensitive
		'--exact'	# Match contiguous normalized latin characters
		'--tac'		# Reverse order of input
		'--read0'	# Parse by null characters
		"$@"
	)

	cd '/usr/share/zoneinfo/'
	fzf "${fzf_params[@]}" < <(printf '%s\0' **)
}



# Expand timezone aliases
[[ ${#timezones} == '0' ]] && timezones=('local')
for i in "${!timezones[@]}"; do
	timezone=${timezones[i]}

	if [[ ${timezone_aliases[$timezone]} ]]; then
		insert_arr=(${timezone_aliases[$timezone]})
		insert_arr_at_index insert_arr timezones "$i" 0 1
		continue
	fi

	case $timezone in
		'_')
			timezone=$(get_tz --prompt="Timezone $((i+1)): ")
			[[ $timezone ]] || print_stderr 1 '%s\n' 'no timezone selected'
			timezones[i]=$timezone
			;;
		'local')
			timezones[i]=$(timedatectl show --property=Timezone --value)
			;;
	esac
done



# Validate timezone exists
for i in "${!timezones[@]}"; do
	[[ -e '/usr/share/zoneinfo/'${timezones[i]} ]] || print_stderr 1 '%s\n' 'No such TZ: '"${timezones[i]}"
done



# Get the date string of the primary (first) timezone and store the formatted string of all timezones
primary_date_str=$(TZ=${timezones[0]} date -d "$date_str" '+%Y-%m-%dT%H:%M:%S %Z')
for i in "${!timezones[@]}"; do
	timezones_formatted[i]=$(printf '%s\n' "$primary_date_str" | TZ=${timezones[i]} date -f - "$format")
done



# Output the formatted dates
[[ $print_stderr__silent ]] || printf '\e[32m%s\e[0m' "'$date_str' "
for i in "${!timezones[@]}"; do
	if [[ ! $print_stderr__silent ]]; then
		[[ $i == 1 ]] && printf '%s\n' "Converted to..."
		printf '\e[32m%s\e[0m ' "${timezones[i]}:"
	fi
	printf '%s\n' "${timezones_formatted[i]}"
done



