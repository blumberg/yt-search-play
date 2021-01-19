#!/bin/bash

## Where am I?

script_path=$(realpath $0)
script_dir="$(dirname "$script_path")"
default_configfile="$script_dir/.default.config.json"

## Variable defaults

search_size=30
max_history_size=50
max_cache_age=60
data_dir=".data"
force_no_cache=
subs_mode=

## Rewrite_default_config

jq -n --arg search_size "$search_size" --arg max_history_size "$max_history_size" --arg max_cache_age "$max_cache_age" --arg data_dir "$data_dir" --arg force_no_cache "$force_no_cache" --arg subs_mode "$subs_mode" '{search_size: $search_size, max_history_size: $max_history_size, max_cache_age: $max_cache_age, data_dir: $data_dir, force_no_cache: $force_no_cache, subs_mode: $subs_mode}' > "$default_configfile"

## Define functions

find_config () {
	if [[ -s "$passed_configfile" ]]
	then
		echo "$passed_configfile"
	elif [[ -s "$script_dir/config.json" ]]
	then
		echo "$script_dir/config.json"
	elif [[ -s "$HOME/.config/yt-search-play/config.json" ]]
	then
		echo "$HOME/.config/yt-search-play/config.json"
	else
		echo "$default_configfile"
	fi
}

load_config () {
	configfile="$(find_config)"

	if [[ -n "$configfile" ]]
	then
		config=$(jq '.' "$configfile")
		search_size=$(echo "$config" | jq -r --arg default "$search_size" '. | if has("search_size") then .search_size else $default end')
		max_history_size=$(echo "$config" | jq -r --arg default "$max_history_size" '. | if has("max_history_size") then .max_history_size else $default end')
		max_cache_age=$(echo "$config" | jq -r --arg default "$max_cache_age" '. | if has("max_cache_age") then .max_cache_age else $default end')
		data_dir=$(echo "$config" | jq -r --arg default "$data_dir" '. | if has("data_dir") then .data_dir else $default end')
		force_no_cache=$(echo "$config" | jq -r --arg default "$force_no_cache" '. | if has("force_no_cache") then .force_no_cache else $default end')
		subs_mode=$(echo "$config" | jq -r --arg default "$subs_mode" '. | if has("subs_mode") then .subs_mode else $default end')
	fi

	if ! [[ "$search_size" =~ ^[0-9]+$ ]]
	then
		>&2 echo "Error in $configfile: search_size must be an integer."
		exit 1
	fi
	if ! [[ "$max_history_size" =~ ^[0-9]+$ ]]
	then
		>&2 echo "Error in $configfile: max_history_size must be an integer."
		exit 1
	fi
	if ! [[ "$max_cache_age" =~ ^[0-9]+$ ]]
	then
		>&2 echo "Error in $configfile: max_cache_age must be an integer."
		exit 1
	fi

	case $data_dir in
		/*) mkdir -p "$data_dir" ;;
		*) mkdir -p "$script_dir/$data_dir" ;;
	esac
	if [[ $? -ne 0 ]]
	then
		>&2 echo "Error in $configfile: $data_dir is not a valid directory."
		exit 1
	fi

	historyfile="$script_dir/$data_dir/search-history"
	cookiefile="$script_dir/$data_dir/cookies.txt"
	cachefile="$script_dir/$data_dir/cache.json"
	
	if [[ ! -f "$historyfile" ]]
	then
		touch -a "$historyfile"
	fi
	history_size=$(< "$historyfile" wc -l 2>/dev/null || echo 0)
}

clear_history () {
	rm -f "$historyfile"
}

clear_cache () {
	rm -f "$cachefile"
}

update_history () {
	if [[ -n "$history_entry" ]] && [[ "$(tail -n 1 "$historyfile")" != "$history_entry" ]]
	then
		echo "$history_entry" >> "$historyfile"
	fi

	if [[ $history_size -gt $max_history_size ]]
	then
		echo $(tail -n $max_history_size "$historyfile") > "$historyfile"
	fi
}

purge_expired_cache () {
	jq --arg time "$(($(date +%s)-$max_cache_age))" 'del(.[] | select(.time < $time))' "$cachefile" > "$cachefile.tmp" && mv "$cachefile.tmp" "$cachefile"
}

write_to_cache () {
	if [[ -n "$2" ]]
	then
		if [[ ! -s "$cachefile" ]] || [[ -z "$(cat "$cachefile" | tr -d '[:space:]')" ]]
  	then
  	  echo "[]" > "$cachefile"
  	fi

  	tail --pid="$2" -f /dev/null
  	local cache=$(<"$temp_idx")
  
		if [[ -n "$cache" ]]
		then
			jq --arg sel "$1" 'del(.[] | select(.entry == $sel))' "$cachefile" | jq --arg sel "$1" --arg time "$(date +%s)" --arg cc "$cache" '. += [{entry: $sel, time: $time, cache: $cc}]' > "$cachefile.tmp" && mv "$cachefile.tmp" "$cachefile"
		fi
	fi
	rm -f "$temp_idx"
}

read_from_cache () {
	if [[ -s "$cachefile" ]]
  then
		purge_expired_cache
    local entry_found=$(jq --arg sel "$1" '.[] | select(.entry == $sel)' "$cachefile")
    if [[ -n "$entry_found" ]]
    then
      echo "$entry_found"
    fi
  fi 
}

find_video () {
	local search_url="$1"
	selection=
	url=

	# check/update this file if sub feed breaks
	[[ -n "$subs_mode" ]] && local include_cookies="--cookies $cookiefile"
	[[ -z "$force_no_cache" ]] && local cache_result=$(read_from_cache "$search_url")
	
	if [[ -z "$cache_result" ]]
	then
		temp_idx=$(mktemp /tmp/ysp_idx.XXXXXXXX)
		temp_pid=$(mktemp /tmp/ysp_pid.XXXXXXXX)
		
		( youtube-dl -i --playlist-end $search_size $include_cookies -j "$search_url" & echo $! >&3 ) 3>"$temp_pid" \
			| jq --unbuffered -r '. | "\(.fulltitle) :: \(.uploader) => \(.webpage_url)"' > "$temp_idx" &
		ytdl_pid=$(<"$temp_pid")
		rm -f "$temp_pid"

		idx=$(tail -f "$temp_idx" | stdbuf -o0 awk 'BEGIN{FS=OFS=" => "}{NF--; print}' \
			| rofi -dmenu -i -p 'Select Video' -no-show-icons -l 10 -scroll-method 0 -format i -async-pre-read 0 &)
		
		if [[ -n "$idx" ]]
		then
			selection=$(sed "$((idx+1))q;d" "$temp_idx")
		fi

		[[ -z "$force_no_cache" ]] && write_to_cache "$search_url" $ytdl_pid || (kill $ytdl_pid 2>/dev/null; rm -f "$temp_idx") &
	else
		local cache_value=$(echo "$cache_result" | jq -r '.cache')
    idx=$(echo "$cache_value" | stdbuf -o0 awk 'BEGIN{FS=OFS=" => "}{NF--; print}' \
      | rofi -dmenu -i -p 'Select Video' -no-show-icons -l 10 -scroll-method 0 -format i -async-pre-read 0 &)
    if [[ -n "$idx" ]]
    then
      selection=$(echo "$cache_value" | sed "$((idx+1))q;d")
    fi
	fi

	url=$(echo "$selection" | awk 'BEGIN{FS=OFS=" => "}{print $NF}')
}

process_args () {
	if [[ $# -gt 0 ]]
	then
		if [[ "$@" =~ --clear-history ]] && [[ "$@" =~ --clear-cache ]]
		then
			clear_history
			clear_cache
			exit
		elif [[ "$@" =~ --clear-history ]]
		then
			clear_history
			exit
		elif [[ "$@" =~ --clear-cache ]]
		then
			clear_cache
			exit
		else
			while [[ $# -gt 0 ]]
			do
				key="$1"
				case $key in
					--subs)
						subs_mode=true
						shift
						;;
					--n)
						search_size="$2"
						shift
						shift
						;;
					--config)
						passed_configfile="$2"
						load_config
						shift
						shift
						;;
				esac
			done
		fi
	fi
}

do_search () {
	if [[ -n "$subs_mode" ]]
	then
		find_video "https://www.youtube.com/feed/subscriptions"
	else
		search_query=$(tac "$historyfile" | rofi -dmenu -p "Search YouTube" -theme-str 'entry { placeholder: "Enter text or select recent search..."; }' -l $([[ $history_size -lt 10 ]] && echo "$history_size" || echo 10) -scroll-method 0)
		if [[ "$search_query" =~ (https?\:\/\/)?(www\.)?(youtube\.com|youtu\.?be)\/.+$ ]]
		then
			selection="$search_query"
			url="${BASH_REMATCH[0]}"
		elif [[ -n "$search_query" ]]
		then
			sanitised_query=${search_query// /+}
			find_video "ytsearch$search_size:$sanitised_query"
		else
			exit
		fi
	fi
}

play_video () {
	if [[ -n "$url" ]]
	then
		history_entry="$selection"
		pkill mpv
		mpv --really-quiet "$url" &
	else
		history_entry="$search_query"
	fi
}

## Main thread

load_config
process_args "$@"
do_search
play_video
update_history
