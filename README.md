# Radarr Genre Sorter

## ✨ Features

- Uses the movie’s **first** genre (with smart fallbacks).
- **Controlled folder creation**
  - Creates a folder **only if** the genre is mapped in `GENRE_MAP` **and** the mapped folder is missing.
  - If genre is **unmapped**, uses an existing same-named folder **if present**; otherwise falls back to **`Unknown`** (created if missing).
- Logs every decision (genre source, mapping choice, created vs used, final PUT status).
- Works inside **Docker containers** (NAS-friendly).

---

## 🧠 How it Works

1. Triggered by Radarr on events you choose (e.g., **On Grab**, **On File Import**, **On File Upgrade**, **On Rename**, **On Movie Added**).
2. Fetches metadata in this order:
   - Radarr DB (`/api/v3/movie/{id}`)
   - `radarr_movie_genres` environment variable (from Radarr)
   - TMDb lookup (via `radarr_movie_tmdbid`)
   - IMDb lookup (via `radarr_movie_imdbid`)
3. Resolves destination folder:
   - If the first genre exists in `GENRE_MAP` → use mapped folder (create if missing).
   - Else, if a same-named folder exists under `GENRE_ROOT` → use it.
   - Else → use `UNKNOWN_GENRE_FOLDER` (create if missing).
4. Calls `PUT /api/v3/movie/{id}?moveFiles=true` to let **Radarr** move the files and update its DB.

---

## ✅ Requirements

- Radarr v3+ (LinuxServer.io image recommended)
- jq installed on Radarr container
- `bash`, `curl`, `jq` **inside the Radarr container**
- Your movies root mounted inside the container (e.g., `/media/Movies`)
- Radarr API key

---

## 🚀 Quick Start

> Replace `<container_name>` with your Radarr container name (often `radarr` or `linuxserver/radarr`).

### 1) Install `jq` in the container
```bash
docker exec -it <container_name> apk add --no-cache jq
```
### 1.1) Persist across container updates (LinuxServer images):
```bash
-e DOCKER_MODS=linuxserver/mods:universal-package-install
-e APK_PACKAGES=jq
```

### 2) Get Genre_Sorter_Radarr.sh script into Radarr container
- Place it somewhere accessible within the Radarr container. e.g /Config/Scripts

### 3) Configure Radarr Notifications to trigger scrtip | Radarr → Connect → Custom Script
- Path: /Config/Scripts/Genre_Sorter_Radarr.sh
- Notification Triggers: (On Grab, On File Import, On File Upgrade, On Rename, On Movie Added)

### 4) Update Config Variables
- Minimum update to the config variables are `RADARR_URL`, `RADARR_API_KEY` & `GENRE_ROOT`
  - RADARR_URL - Update radarrURLentrypoint text palceholder
  - RADARR_API_KEY - Update API-KEY text placeholder
  - GENRE_ROOT - Update /media/Movies path placeholder
 
### 5) Make Genre_Sorter_Radarr.sh executable within the Radarr container
- Connect to container
```bash
docker exec -it <container_name>
```
- Make Genre_Sorter_Radarr.sh executable
```bash
docker exec -it radarr chmod +x /config/scripts/Genre_Sorter_Radarr.sh
```

---

## 💭 How the Genre mapping works
- Genre mapping is constructed as first value = Matching the movies first TMdb movie genre value `["Science Fiction"]` and then matching the destination folder name `"Sci-Fi"`
  
### Mapping multiple genres to a single folder
#### Example
- I may want to classify Fantasy and Science Finction as the same genre and place it into a single destination folder
```bash
  ["Fantasy"]="Sci-Fi"
  ["Science Fiction"]="Sci-Fi"
```
## Good to Know!
- If the script is updated - Radarr will need to be given permissions to the file to successfully perform executions/access the file
  - First: access the Radarr docker container
  ````bash
  docker exec -it radarr sh
  ````
  - Second: provide access to the updated file
  ````bash
  chmod 755 /ROOT:FOLDER/Scripts/genre_sort.sh
  ````
  
