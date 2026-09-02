# Helpers shared by the steps of the clean-up-caches action.
#
# Sourced rather than executed, so that every step reports in the same
# shape without repeating it. gh reads GH_TOKEN and GH_REPO from the
# environment.

# GitHub reports what is in use but never the ceiling.
CACHE_LIMIT_MIB=10240

# Summed from the listing rather than read from actions/cache/usage. That
# endpoint lags by minutes, and this runs right after a build, so it would
# report the state from before the run that triggered it.
report_usage() {
	local all used_mib count
	all=$(all_caches)
	used_mib=$(jq '([.[].sizeInBytes] | add // 0) / 1048576 | floor' <<<"$all")
	count=$(jq 'length' <<<"$all")
	printf '%s: %s MiB of %s MiB across %s caches, %s MiB available\n' \
		"$1" "$used_mib" "$CACHE_LIMIT_MIB" "$count" \
		"$(( CACHE_LIMIT_MIB - used_mib ))"
}

all_caches() {
	gh cache list --limit 100 \
		--json id,key,ref,sizeInBytes,createdAt,lastAccessedAt
}

# A branch also owns whatever a pull request opened from it left behind, and
# the dispatch ref picker can name the branch but never that ref.
resolve_refs() {
	local ref="$1" branch out n
	[ -z "$ref" ] && return 0

	case "$ref" in
		refs/heads/*) branch="${ref#refs/heads/}" ;;
		refs/*) printf '%s\n' "$ref"; return 0 ;;
		*) branch="$ref" ;;
	esac

	out="refs/heads/$branch"
	for n in $(gh pr list --head "$branch" --state all --json number \
		--jq '.[].number' 2>/dev/null); do
		out="$out"$'\n'"refs/pull/$n/merge"
	done
	printf '%s\n' "$out"
}

# Every cache when no ref resolves.
in_scope() {
	local caches="$1" refs="$2"
	if [ -z "$refs" ]; then
		printf '%s' "$caches"
		return 0
	fi
	jq -c --argjson want "$(printf '%s\n' "$refs" | jq -R . | jq -s .)" \
		'[.[] | select(.ref as $r | $want | index($r))]' <<<"$caches"
}

tabulate() {
	jq -r 'if length == 0 then "  none"
	       else sort_by(.ref, .key)[]
	            | "  \(((.sizeInBytes/1048576)|floor|tostring)) MiB\t\(.ref)\t\(.key)"
	       end' <<<"$1" | column -t -s "$(printf '\t')"
}

# A cache cannot be overwritten, so each run leaves a new entry behind and
# only the newest of each prefix is ever restored. The key carries the
# timestamp that makes it unique, so grouping strips it.
select_superseded() {
	jq -c '
		group_by(.ref + "|" + (.key | sub("-[0-9]{4}-[0-9]{2}-[0-9]{2}T.*$"; "")))
		| map(sort_by(.createdAt) | .[0:-1])
		| flatten' <<<"$1"
}

# Over the ceiling GitHub evicts by last access, which takes a branch's
# caches first: a pull request keeps touching its own, a branch does not.
select_headroom() {
	jq -c --argjson t "$(( $2 * 1048576 ))" '
		([.[].sizeInBytes] | add // 0) as $total
		| if $total <= $t then []
		  else
		    ([.[] | select(.ref | startswith("refs/heads/") | not)]
		     | sort_by(.lastAccessedAt)) as $c
		    | reduce range(0; $c | length) as $i
		        ({need: ($total - $t), out: []};
		         if .need > 0
		         then {need: (.need - $c[$i].sizeInBytes),
		               out: (.out + [$c[$i]])}
		         else . end)
		    | .out
		  end' <<<"$1"
}

total_mib() {
	jq '([.[].sizeInBytes] | add // 0) / 1048576 | floor' <<<"$1"
}
