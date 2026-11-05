# Helpers sourced by the steps of the clean-up-caches action.

CACHE_LIMIT_MIB=10240

report_usage() {
	local label="$1" all used_mib count
	all=$(all_caches)
	used_mib=$(jq '([.[].sizeInBytes] | add // 0) / 1048576 | floor' <<<"$all")
	count=$(jq 'length' <<<"$all")
	printf '%s: %s MiB of %s MiB across %s caches, %s MiB available\n' \
		"$label" "$used_mib" "$CACHE_LIMIT_MIB" "$count" \
		"$(( CACHE_LIMIT_MIB - used_mib ))"
}

all_caches() {
	gh api --paginate "repos/$GH_REPO/actions/caches?per_page=100" \
		--jq '.actions_caches[] | {id, key, ref,
			sizeInBytes: .size_in_bytes,
			createdAt: .created_at,
			lastAccessedAt: .last_accessed_at}' \
		| jq -s -c .
}

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
	local caches="$1"
	jq -r 'if length == 0 then "  none"
	       else sort_by(.ref, .key)[]
	            | "  \(((.sizeInBytes/1048576)|floor|tostring)) MiB\t\(.ref)\t\(.key)"
	       end' <<<"$caches" | column -t -s "$(printf '\t')"
}

select_superseded() {
	local caches="$1" patterns="${2:-}"
	jq -c --arg patterns "$patterns" '
		def stem:
			(if startswith("fetched-")
			 then sub("-[0-9a-f]{64}$"; "")
			 else . end)
			| sub("-[0-9]{4}-[0-9]{2}-[0-9]{2}T.*$"; "")
			| sub("-[0-9a-f]{40}$"; "")
			| sub("-[0-9]{6,}$"; "");
		def regex:
			"^" + (split("*")
			       | map(gsub("(?<c>[.+?^$(){}|\\[\\]\\\\])"; "\\\(.c)"))
			       | join(".*")) + "$";
		($patterns | split("\n") | map(gsub("^\\s+|\\s+$"; ""))
		 | map(select(length > 0))) as $families
		| def family:
			if ($families | length) == 0 then stem
			else . as $key
			     | first($families[] | select(. as $p | $key | test($p | regex)))
			       // null
			end;
		map(.family = (.key | family))
		| map(select(.family != null))
		| group_by(.ref + "|" + .family)
		| map(sort_by(.createdAt) | .[0:-1])
		| flatten
		| map(del(.family))' <<<"$caches"
}

live_refs() {
	local refs
	refs=$(git ls-remote "https://x-access-token:$GH_TOKEN@github.com/$GH_REPO" \
		| awk '{print $2}')
	if [ -z "$refs" ]; then
		echo "No refs came back from the remote" >&2
		return 1
	fi
	printf '%s\n' "$refs"
}

select_dead() {
	local caches="$1" live="$2"
	jq -c --argjson live "$(printf '%s\n' "$live" | jq -R . | jq -s .)" \
		'[.[] | select(.ref as $r | $live | index($r) | not)]' <<<"$caches"
}

without() {
	local caches="$1" gone="$2"
	jq -c --argjson gone "$gone" \
		'[.[] | select(.id as $i | $gone | map(.id) | index($i) | not)]' <<<"$caches"
}

select_headroom() {
	local caches="$1" target_mib="$2"
	jq -c --argjson t "$(( target_mib * 1048576 ))" '
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
		  end' <<<"$caches"
}

total_mib() {
	local caches="$1"
	jq '([.[].sizeInBytes] | add // 0) / 1048576 | floor' <<<"$caches"
}
