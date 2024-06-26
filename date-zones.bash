#!/usr/bin/env bash
[[ $DEBUG ]] && set -x
set -o errexit -o pipefail
shopt -s globstar nullglob


help_doc() {
	{ IFS= read -rd '' || printf '%s' "$REPLY" 1>&2; } <<-'HelpDoc'

		date-zones.bash [OPTION] [TIMEZONE...]

		Outputs a date defined by OPTIONs, then converts it to TIMEZONEs

		OPTION
		  --date|-d <DATE>        Date to use, default: 'now'
		  --tz <TIMEZONE>         Timezone to use with --date, default: localtime
		  +<FORMAT>               Date output format, default: '+%Y-%m-%d %I:%M:%S %p %Z'
		  --24hr                  Use 24hr clock for default date format
		  --silent|-s             Only output dates
		  --help                  Display help

		TIMEZONE
		  _                       Use fzf to pick a timezone
		  utc                     Alias for Etc/UTC
		  local                   Use system timezone
		  <LOCALE>                A standard locale, ex: America/Los_Angeles

		EXAMPLES
		  # Output local date and using a specific format
		  date-zones.bash +%Y-%m-%dT%H:%M:%S

		  # Output local date, then convert it to America/New_York time and two fzf picked timezones
		  date-zones.bash 'America/New_York' _ _

		  # Output date in Prague for Wed 2pm, then convert it to Asia/Hong_Kong time
		  date-zones.bash --tz 'Europe/Prague' -d 'Wed 2pm' 'Asia/Hong_Kong'

		  # Output date in fzf picked timezone at Wed 2pm, then convert it to Europe/London time
		  date-zones.bash --tz _ -d 'wed 2pm' 'Europe/London'

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
date_output_format='+%Y-%m-%d %I:%M %p %Z'
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
			date_output_format=$1 ;;
		'--24hr')
			date_output_format='+%Y-%m-%d %H:%M %Z' ;;
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



# Define array combiner
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
tz_picker() {
	TZ_PICKER__OUTPUT=
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
	TZ_PICKER__OUTPUT=$(fzf "${fzf_params[@]}" < <(
		for path in **; do
			[[ -d $path ]] && continue
			printf '%s\0' "$path"
		done
	))
}



# Add aliases present in config file
if [[ -f $config_dir'/aliases' ]]; then
	while read -r timezone_alias timezone; do
		[[ $timezone_alias && $timezone ]] || continue
		timezone_aliases[$timezone_alias]=$timezone
	done < "$config_dir"'/aliases'
fi



# Convert aliases to timezones
[[ ${timezone_aliases[$primary_tz]} ]] && primary_tz=${timezone_aliases[$primary_tz]}
for i in "${!timezones[@]}"; do
	timezone=${timezones[i]}

	if [[ ${timezone_aliases[$timezone]} ]]; then
		insert_arr=(${timezone_aliases[$timezone]})
		insert_arr_at_index insert_arr timezones "$i" 0 1
		continue
	fi
done



# Replace underscores with tz_picker output
handle_underscore() {
	HANDLE_UNDERSCORE__OUTPUT=
	[[ $1 == '_' ]] || return 1
	tz_picker --prompt="Timezone $((i+1)): "
	[[ $TZ_PICKER__OUTPUT ]] || print_stderr 1 '%s\n' 'no timezone selected'
	HANDLE_UNDERSCORE__OUTPUT=$TZ_PICKER__OUTPUT
}
handle_underscore "$primary_tz" && primary_tz=$HANDLE_UNDERSCORE__OUTPUT
for i in "${!timezones[@]}"; do
	handle_underscore "${timezones[i]}" && timezones[i]=$HANDLE_UNDERSCORE__OUTPUT
done



# Validate all timezones exist
validate_timezones() {
	while [[ $1 ]]; do
		[[ -e '/usr/share/zoneinfo/'$1 ]] || print_stderr 1 '%s\n' 'No such TZ: '"$1"
		shift
	done
}
validate_timezones "$primary_tz" "${timezones[@]}"




# Prepare dates for printing using the Unix epoch time of the primary date for all locales
primary_date_epoch=$(TZ=$primary_tz date -d "$date_str" '+%s')
primary_date_formatted=$(TZ=$primary_tz date -d "@${primary_date_epoch}" "$date_output_format")
for i in "${!timezones[@]}"; do
	timezones_formatted[i]=$(TZ=${timezones[i]} date -d "@${primary_date_epoch}" "$date_output_format")
done



# Output formatted dates
[[ $print_stderr__silent ]] || printf '\e[32m%s\e[0m' "'${date_str}' ${primary_tz}: "
printf '%s\n' "$primary_date_formatted"

[[ ${#timezones[@]} == '0' ]] || printf '%s\n' "Converted to..."
for i in "${!timezones[@]}"; do
	[[ $print_stderr__silent ]] || printf '\e[32m%s\e[0m' "${timezones[i]}: "
	printf '%s\n' "${timezones_formatted[i]}"
done



