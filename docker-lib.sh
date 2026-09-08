# shellcheck shell=bash
# Stack discovery shared by omarchy-docker-stacks and omarchy-docker-action.

DEFAULT_ROOTS="$HOME/dev"

die() {
  jq -n --arg error "$1" '{ok: false, error: $error}'
  exit 1
}

have_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}

# Compose derives a project name from the directory: lowercased, with anything
# outside [a-z0-9_-] dropped. Mirrored here so a stack that has never been
# started still lands on the same key as one the daemon already knows.
project_name() {
  local base
  base=$(basename "${1%/}")
  base=${base,,}
  printf '%s' "$(printf '%s' "$base" | tr -cd 'a-z0-9_-')"
}

# name \t dir \t comma-separated compose files, one line per directory found.
scan_roots() {
  local roots="$1" root dir cand files
  local -a parts

  IFS=',' read -ra parts <<<"$roots"
  for root in "${parts[@]}"; do
    root="${root#"${root%%[![:space:]]*}"}"
    root="${root%"${root##*[![:space:]]}"}"
    root="${root/#\~/$HOME}"
    [[ -d $root ]] || continue

    for dir in "$root"/*/; do
      [[ -d $dir ]] || continue
      files=()
      for cand in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$dir$cand" ]] && files+=("$dir$cand") && break
      done
      ((${#files[@]})) || continue
      for cand in docker-compose.override.yml docker-compose.override.yaml \
                  compose.override.yml compose.override.yaml; do
        [[ -f "$dir$cand" ]] && files+=("$dir$cand") && break
      done
      printf '%s\t%s\t%s\n' "$(project_name "$dir")" "${dir%/}" "$(IFS=,; printf '%s' "${files[*]}")"
    done
  done
}

# One JSON array of stacks, merging what the daemon reports with what is on
# disk. The daemon knows the live state but not the stacks that have never run;
# the scan knows the reverse. Neither side alone is the list you want to see.
stacks_json() {
  local roots="${1:-$DEFAULT_ROOTS}" daemon scanned

  daemon=$(docker compose ls --all --format json 2>/dev/null) || daemon=""
  [[ -n $daemon ]] || daemon="[]"
  scanned=$(scan_roots "$roots")

  jq -n --argjson daemon "$daemon" --arg scanned "$scanned" '
    def counts:
      [ (. // "") | scan("([a-z]+)\\(([0-9]+)\\)") ]
      | map({state: .[0], n: (.[1] | tonumber)});

    def state_of($running; $total):
      if $total == 0 then "idle"
      elif $running == $total then "running"
      elif $running > 0 then "partial"
      else "stopped" end;

    ($scanned | split("\n") | map(select(length > 0) | split("\t"))
      | map({key: .[0], value: {dir: .[1], files: (.[2] | split(","))}})
      | from_entries) as $disk

    | ($daemon | map(
        (.Status | counts) as $c
        | (($c | map(select(.state == "running") | .n) | add) // 0) as $running
        | (($c | map(.n) | add) // 0) as $total
        | (.ConfigFiles // "" | split(",") | map(select(length > 0))) as $files
        | {
            name: .Name,
            running: $running,
            total: $total,
            state: state_of($running; $total),
            status: .Status,
            files: $files,
            dir: ($disk[.Name].dir // ($files[0] // "" | if . == "" then "" else sub("/[^/]+$"; "") end)),
            known: true
          }
      )) as $live

    | ($live | map(.name)) as $seen
    | $live + (
        $disk | to_entries | map(select(.key as $k | $seen | index($k) | not) | {
          name: .key,
          running: 0,
          total: 0,
          state: "idle",
          status: "",
          files: .value.files,
          dir: .value.dir,
          known: false
        })
      )
    | sort_by(.name)
  '
}

# Resolve one stack to the argv prefix that addresses it.
compose_args() {
  local name="$1" roots="$2" json
  json=$(stacks_json "$roots") || return 1
  jq -r --arg name "$name" '
    (map(select(.name == $name)) | first) as $s
    | if $s == null then empty
      else ($s.files | map("-f\n" + .) | join("\n")) + "\n--project-directory\n" + $s.dir
      end
  ' <<<"$json"
}
