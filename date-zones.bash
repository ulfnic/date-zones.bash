#!/usr/bin/env bash
[[ $DEBUG ]] && set -x
set -o errexit -o pipefail
shopt -s globstar nullglob


help_doc() {
	{ IFS= read -rd '' || printf '%s' "$REPLY" 1>&2; } <<-'HelpDoc'

		date-zones.bash [OPTION] [TIMEZONE...]

		Outputs a date defined by OPTIONs, then converts it to TIMEZONEs

		OPTION
		  --date|-d DATE          Date to use, default: 'now'
		  --tz TIMEZONE           Timezone to use with --date, default: localtime
		  +FORMAT                 Date output format, default: '+%Y-%m-%d %I:%M:%S %p %Z'
		  --24hr                  Use 24hr clock for default date format
		  --silent|-s             Only output dates
		  --help                  Display help

		TIMEZONE
		  _                       Use fzf to pick a timezone
		  utc                     Alias for Etc/UTC
		  local                   Use system timezone
		  LOCALE                  A standard locale, ex: America/Los_Angeles

		EXAMPLES
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



# Perform minimum BASH version check
if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3 ) )); then
	printf '%s\n' 'BASH version required >= 4.3 (released 2014)' 1>&2
fi



# Define defaults
date_str='now'
format='+%Y-%m-%d %I:%M %p %Z'
primary_tz='local'
timezones=()
timezones_formatted=()
print_stderr__silent=
config_dir=${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}'/date-zones.bash'
declare -A timezone_aliases=(
	['local']=$(timedatectl show --property=Timezone --value)
	['utc']='Etc/UTC'
	['UTC']='Etc/UTC'
)



# Handle parameters
while [[ $1 ]]; do
	case $1 in
		'-d'|'--date')
			shift; date_str=$1 ;;
		'--tz')
			shift; primary_tz=$1 ;;
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



# Define fzf timezone picker
get_tz() {
	GET_TZ__OUTPUT=
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
	GET_TZ__OUTPUT=$(fzf "${fzf_params[@]}" < <(
		for path in **; do
			[[ -d $path ]] && continue
			printf '%s\0' "$path"
		done
	))
}



# Load config timezone aliases
if [[ -f $config_dir'/aliases' ]]; then
	while read -r timezone_alias timezone; do
		[[ $timezone_alias && $timezone ]] || continue
		timezone_aliases[$timezone_alias]=$timezone
	done < "$config_dir"'/aliases'
fi



# Apply config timezone aliases
[[ ${timezone_aliases[$primary_tz]} ]] && primary_tz=${timezone_aliases[$primary_tz]}

for i in "${!timezones[@]}"; do
	timezone=${timezones[i]}

	if [[ ${timezone_aliases[$timezone]} ]]; then
		insert_arr=(${timezone_aliases[$timezone]})
		insert_arr_at_index insert_arr timezones "$i" 0 1
		continue
	fi
done



# Apply core aliases and timzeone selection
expand_underscore_alias() {
	EXPAND_UNDERSCORE_ALIAS__OUTPUT=
	[[ $1 == '_' ]] || return 1
	get_tz --prompt="Timezone $((i+1)): "
	[[ $GET_TZ__OUTPUT ]] || print_stderr 1 '%s\n' 'no timezone selected'
	EXPAND_UNDERSCORE_ALIAS__OUTPUT=$GET_TZ__OUTPUT
}
expand_underscore_alias "$primary_tz" && primary_tz=$EXPAND_UNDERSCORE_ALIAS__OUTPUT
for i in "${!timezones[@]}"; do
	expand_underscore_alias "${timezones[i]}" && timezones[i]=$EXPAND_UNDERSCORE_ALIAS__OUTPUT
done



# Validate timezones exists
validate_timezones() {
	while [[ $1 ]]; do
		[[ -e '/usr/share/zoneinfo/'$1 ]] || print_stderr 1 '%s\n' 'No such TZ: '"$1"
		shift
	done
}
validate_timezones "$primary_tz" "${timezones[@]}"



# Convert the primary date to UTC and use it to define all timezones in printing format
primary_date_str_utc=$(
	TZ=$primary_tz date -d "$date_str" '+%Y-%m-%dT%H:%M:%S %Z' \
	| date --utc -f - '+%Y-%m-%d %I:%M %p %Z' \
)
primary_date_formatted=$(printf '%s\n' "$primary_date_str_utc" | TZ=$primary_tz date -f - "$format")
for i in "${!timezones[@]}"; do
	timezones_formatted[i]=$(printf '%s\n' "$primary_date_str_utc" | TZ=${timezones[i]} date -f - "$format")
done



# Output formatted dates
[[ $print_stderr__silent ]] || printf '\e[32m%s\e[0m' "'${date_str}' ${primary_tz}: "
printf '%s\n' "$primary_date_formatted"

[[ ${#timezones[@]} == '0' ]] || printf '%s\n' "Converted to..."
for i in "${!timezones[@]}"; do
	[[ $print_stderr__silent ]] || printf '\e[32m%s\e[0m' "${timezones[i]}: "
	printf '%s\n' "${timezones_formatted[i]}"
done



