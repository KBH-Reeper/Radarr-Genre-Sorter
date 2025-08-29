#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
RADARR_URL="${RADARR_URL:-radarrURLentrypoint}"   # e.g. http://192.168.0.96:7878
RADARR_API_KEY="${RADARR_API_KEY:-API-KEY}".   # replace API-KEY with your Radarr api key
GENRE_ROOT="${GENRE_ROOT:-/media/Movies}"    # path Radarr can access your movie folder/main storage for movies(Genre folders will be created here)
ONLY_ON="${ONLY_ON:-Rename,Grab,Download,MovieAdded}"   # Radarr triggers that script will allow to fulfil genre match/move
UNKNOWN_GENRE_FOLDER="${UNKNOWN_GENRE_FOLDER:-Unknown}"

# Genre mapping | Radarr/TMDb genre -> destination folder name
# you can map multiple Radarr/TMBd genres to a single genre destination folder e.g. Science Fiction > Sci-Fi and Sci-Fi > Sci-Fi
declare -A GENRE_MAP=(
  ["Action"]="Action"
  ["Adventure"]="Adventure"
  ["Animation"]="Animation"
  ["Comedy"]="Comedy"
  ["Crime"]="Crime"
  ["Documentary"]="Documentary"
  ["Drama"]="Drama"
  ["Family"]="Family"
  ["Fantasy"]="Fantasy"
  ["Horror"]="Horror"
  ["Mystery"]="Mystery"
  ["Romance"]="Romance"
  ["Science Fiction"]="Sci-Fi"
  ["Sci-Fi"]="Sci-Fi"
  ["Thriller"]="Thriller"
  ["War"]="War"
  ["Western"]="Western"
)

# ===== FORMAT HELPERS =====
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
csv_has () {
  local needle="$(lower "$1")"; local hay="$(lower "$2")"
  IFS=',' read -r -a arr <<< "$hay"
  for x in "${arr[@]}"; do
    local cleaned="${x// /}"
    [[ "$needle" == "$(lower "$cleaned")" || "$needle" == "$(lower "$x")" ]] && return 0
  done
  return 1
}
safe() { local s="${1//\//-}"; printf '%s' "$(printf '%s' "$s" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]\.]+|[[:space:]\.]+$//g')" ; }
normpath() { local p="${1%/}"; echo "$p" | sed -E 's:/+:/:g'; }

get_json() { # url -> stdout (body), prints http code on a final line
  curl -sS -w "\n%{http_code}" -H "X-Api-Key: $RADARR_API_KEY" "$1"
}

# ===== GENRE LOOKUP/MATCHER =====
lookup_by_tmdb() { # tmdbId -> movie json (first match)
  local out code
  log "Lookup: TMDb ID $1 via /movie/lookup/tmdb"
  out="$(get_json "$RADARR_URL/api/v3/movie/lookup/tmdb?tmdbId=$1")"; code="${out##*$'\n'}"; out="${out%$'\n'*}"
  log "Lookup: tmdb endpoint HTTP $code"
  if [[ "$code" == "200" && -n "$out" && "$out" != "[]" ]]; then
    echo "$out" | jq -c 'if type=="array" then .[0] else . end'
    return 0
  fi
  log "Lookup: fallback via term=tmdb:$1"
  out="$(get_json "$RADARR_URL/api/v3/movie/lookup?term=tmdb:$1")"; code="${out##*$'\n'}"; out="${out%$'\n'*}"
  log "Lookup: term=tmdb HTTP $code"
  [[ "$code" == "200" && -n "$out" && "$out" != "[]" ]] && echo "$out" | jq -c 'if type=="array" then .[0] else . end'
}

lookup_by_imdb() { # imdbId (tt...) -> movie json (first match)
  local out code
  log "Lookup: IMDb ID $1 via /movie/lookup/imdb"
  out="$(get_json "$RADARR_URL/api/v3/movie/lookup/imdb?imdbId=$1")"; code="${out##*$'\n'}"; out="${out%$'\n'*}"
  log "Lookup: imdb endpoint HTTP $code"
  if [[ "$code" == "200" && -n "$out" && "$out" != "[]" ]]; then
    echo "$out" | jq -c 'if type=="array" then .[0] else . end'
    return 0
  fi
  log "Lookup: fallback via term=imdb:$1"
  out="$(get_json "$RADARR_URL/api/v3/movie/lookup?term=imdb:$1")"; code="${out##*$'\n'}"; out="${out%$'\n'*}"
  log "Lookup: term=imdb HTTP $code"
  [[ "$code" == "200" && -n "$out" && "$out" != "[]" ]] && echo "$out" | jq -c 'if type=="array" then .[0] else . end'
}

get_first_genre() {
  local json="$1"
  [[ -z "$json" ]] && return 1
  echo "$json" | jq -r '(.genres // empty)[0] // empty'
}

# ===== MAIN SCRIPT =====
EVENT_TYPE="${radarr_eventtype:-${RADARR_EVENTTYPE:-}}"
MOVIE_ID_RAW="${radarr_movie_id:-${RADARR_MOVIE_ID:-}}"
TMDB_ID="${radarr_movie_tmdbid:-${RADARR_MOVIE_TMDBID:-}}"
IMDB_ID="${radarr_movie_imdbid:-${RADARR_MOVIE_IMDBID:-}}"
TITLE_HINT="${radarr_movie_title:-${RADARR_MOVIE_TITLE:-}}"

# Sanitize ID (guards against smart quotes etc.)
MOVIE_ID="$(printf '%s' "${MOVIE_ID_RAW:-}" | tr -cd '0-9')"

log "Start: EVENT='$EVENT_TYPE' RADARR_ID='${MOVIE_ID_RAW:-}'(->'$MOVIE_ID') TMDB='$TMDB_ID' IMDb='${IMDB_ID:-}' TitleHint='${TITLE_HINT:-}'"
log "Config: RADARR_URL='$RADARR_URL' GENRE_ROOT='$GENRE_ROOT' ONLY_ON='$ONLY_ON'"

# Event filter
if [[ -n "${ONLY_ON:-}" && -n "${EVENT_TYPE:-}" ]]; then
  ev_nospace="$(lower "${EVENT_TYPE// /}")"
  if ! csv_has "$ev_nospace" "$ONLY_ON"; then
    log "Skip: event '$EVENT_TYPE' not in ONLY_ON='$ONLY_ON'"
    exit 0
  fi
fi

if [[ -z "${RADARR_API_KEY:-}" || "$RADARR_API_KEY" == "ENTER-RADARR-API-HERE" ]]; then
  log "ERROR: RADARR_API_KEY not set"; exit 2
fi

# 1) Try fetch movie by internal Radarr ID
movie_json=""
if [[ -n "$MOVIE_ID" ]]; then
  log "Fetch: Radarr movie by ID $MOVIE_ID"
  out="$(get_json "$RADARR_URL/api/v3/movie/$MOVIE_ID")"; code="${out##*$'\n'}"; body="${out%$'\n'*}"
  log "Fetch: HTTP $code"
  if [[ "$code" == "200" ]]; then
    movie_json="$body"
  else
    log "Warn: movie id $MOVIE_ID not found in DB, will try lookups"
    MOVIE_ID="" # allow fallback path
  fi
fi

# 2) Determine first genre (DB -> env -> TMDb -> IMDb)
first_genre=""
genre_src=""

if [[ -n "$movie_json" ]]; then
  g="$(get_first_genre "$movie_json" || true)"
  if [[ -n "$g" ]]; then first_genre="$g"; genre_src="db"; log "Genre: from DB -> '$first_genre'"; fi
fi

if [[ -z "$first_genre" && -n "${radarr_movie_genres:-}" ]]; then
  IFS='|' read -r first_genre _ <<< "$radarr_movie_genres"
  genre_src="env"
  log "Genre: from env radarr_movie_genres -> '$first_genre'"
fi

if [[ -z "$first_genre" && -n "$TMDB_ID" ]]; then
  lookup="$(lookup_by_tmdb "$TMDB_ID" || true)"
  g="$(get_first_genre "$lookup" || true)"
  if [[ -n "$g" ]]; then first_genre="$g"; genre_src="tmdb"; log "Genre: from TMDb lookup -> '$first_genre'"; fi
  [[ -z "${TITLE_HINT:-}" && -n "$lookup" ]] && TITLE_HINT="$(echo "$lookup" | jq -r '.title // empty')"
fi

if [[ -z "$first_genre" && -n "$IMDB_ID" ]]; then
  lookup="$(lookup_by_imdb "$IMDB_ID" || true)"
  g="$(get_first_genre "$lookup" || true)"
  if [[ -n "$g" ]]; then first_genre="$g"; genre_src="imdb"; log "Genre: from IMDb lookup -> '$first_genre'"; fi
  [[ -z "${TITLE_HINT:-}" && -n "$lookup" ]] && TITLE_HINT="$(echo "$lookup" | jq -r '.title // empty')"
fi

if [[ -z "$first_genre" ]]; then
  log "WARN: No genre from DB/env/lookup; will use fallback bucket"
fi

# 3) Resolve and ensure destination folder (controlled creation)
dest_folder=""

if [[ -n "$first_genre" && -n "${GENRE_MAP[$first_genre]+x}" ]]; then
  # MAPPED GENRE: use mapped folder; create if missing
  dest_folder="$(safe "${GENRE_MAP[$first_genre]}")"
  if [[ ! -d "$GENRE_ROOT/$dest_folder" ]]; then
    log "Folder: mapped '$first_genre' -> '$dest_folder' (missing) -> creating"
    mkdir -p "$GENRE_ROOT/$dest_folder"
  else
    log "Folder: mapped '$first_genre' -> '$dest_folder' (exists)"
  fi
else
  # UNMAPPED: only use raw genre if folder already exists
  cand="$(safe "$first_genre")"
  if [[ -n "$cand" && -d "$GENRE_ROOT/$cand" ]]; then
    dest_folder="$cand"
    log "Folder: unmapped '$first_genre' -> using existing '$dest_folder'"
  else
    # FALLBACK Unknown; ensure it exists
    dest_folder="$(safe "$UNKNOWN_GENRE_FOLDER")"
    if [[ ! -d "$GENRE_ROOT/$dest_folder" ]]; then
      log "Folder: fallback '$dest_folder' (missing) -> creating"
      mkdir -p "$GENRE_ROOT/$dest_folder"
    else
      log "Folder: fallback '$dest_folder' (exists)"
    fi
  fi
fi

# 4) Build target path details
title="$( [[ -n "$movie_json" ]] && echo "$movie_json" | jq -r '.title // empty' || echo "${TITLE_HINT:-}" )"
year="$(  [[ -n "$movie_json" ]] && echo "$movie_json" | jq -r '.year  // empty' || echo "" )"
[[ -z "$title" ]] && title="Unknown"
title_dir="$title"; [[ -n "$year" && "$year" != "null" ]] && title_dir="$title ($year)"
new_path="$GENRE_ROOT/$dest_folder/$title_dir"
log "Path: target -> '$new_path' (genre='$first_genre' src='${genre_src:-none}')"

# 5) Ensure we have the Radarr DB object (need its internal id for PUT)
if [[ -z "$movie_json" ]]; then
  if [[ -n "$MOVIE_ID" ]]; then
    log "Fetch: DB object by ID (second attempt)"
    movie_json="$(curl -sS -H "X-Api-Key: $RADARR_API_KEY" "$RADARR_URL/api/v3/movie/$MOVIE_ID")"
  else
    log "Fetch: DB object by title search '$title'"
    all="$(curl -sS -H "X-Api-Key: $RADARR_API_KEY" "$RADARR_URL/api/v3/movie")"
    movie_json="$(echo "$all" | jq -c --arg t "$title" '.[] | select(.title|test($t; "i"))' | head -n 1)"
  fi
fi

if ! echo "${movie_json:-}" | jq -e .id >/dev/null 2>&1; then
  log "ERROR: Could not resolve movie in Radarr DB to update path"
  exit 1
fi

id="$(echo "$movie_json" | jq -r '.id')"
current_path="$(echo "$movie_json" | jq -r '.path // ""')"
log "Path: current -> '$(normpath "$current_path")'"

# 6) Skip if already correct
norm_cur="$(normpath "$current_path")"; norm_new="$(normpath "$new_path")"
if [[ "$norm_cur" == "$norm_new" ]]; then
  log "No-op: already in desired path"
  echo "Already in desired path: $new_path"
  exit 0
fi

# 7) Update Radarr path & let Radarr move files
tmpfile="$(mktemp)"; echo "$movie_json" | jq --arg p "$new_path" '.path = $p' > "$tmpfile"
log "PUT: /api/v3/movie/$id?moveFiles=true -> '$new_path'"
status="$(curl -sS -o /dev/stderr -w "%{http_code}" -X PUT \
  -H "X-Api-Key: $RADARR_API_KEY" -H "Content-Type: application/json" \
  --data-binary @"$tmpfile" \
  "$RADARR_URL/api/v3/movie/$id?moveFiles=true")" || true
log "PUT: HTTP $status"

if [[ "${status:-500}" -ge 400 ]]; then
  log "PUT: retry with moveFiles in body"
  echo "$movie_json" | jq --arg p "$new_path" '.path = $p | .moveFiles = true' > "$tmpfile"
  status2="$(curl -sS -o /dev/stderr -w "%{http_code}" -X PUT \
    -H "X-Api-Key: $RADARR_API_KEY" -H "Content-Type: application/json" \
    --data-binary @"$tmpfile" \
    "$RADARR_URL/api/v3/movie/$id")" || true
  log "PUT: fallback HTTP $status2"
  if [[ "${status2:-500}" -ge 400 ]]; then
    log "ERROR: Radarr PUT failed (status=$status, fallback=$status2)"
    rm -f "$tmpfile"
    exit 1
  fi
fi

rm -f "$tmpfile"
log "Success: moved '$title' -> '$new_path'"
echo "Moved '$title' → $new_path (genre='${first_genre:-Unknown}')"
exit 0
