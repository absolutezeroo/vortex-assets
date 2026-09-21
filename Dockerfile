# syntax=docker/dockerfile:1

# =================================================================================================
# vortex-assets — the Nitro tree, as an image
# =================================================================================================
# Built here, where the files are, and pushed to a registry:
#
#   docker build -t ghcr.io/<you>/vortex-assets:latest .
#   docker push  ghcr.io/<you>/vortex-assets:latest
#
# Coolify then pulls an image rather than cloning three gigabytes of binaries it would have to
# re-clone on every deploy, and a registry pull moves only the layers that actually changed.
#
# ---------------------------------------------------------------------------------------------
# What replaces Apache
# ---------------------------------------------------------------------------------------------
# The tree was served by Laragon, and two Apache-only things went with it:
#
#   gamedata/hashes.php   generated the manifest at request time, md5_file() per entry
#   gamedata/.htaccess    rewrote <name>/<hash> to the real file, seven times over
#
# Neither survives in a static container. So the manifest is GENERATED HERE, at build time, from
# the same files with the same md5s — and it comes out better than the PHP did, because the base
# URL is an argument rather than a line someone has to remember to edit. The rewrites become Caddy
# matchers at the bottom of this file, one per line.
#
# Keep the two in step. The development host still has hashes.php and .htaccess and they are what
# Laragon serves; this file is what production serves, and an entry added to one and not the other
# is a file that loads locally and is silently absent live.
#
# ---------------------------------------------------------------------------------------------
# Why the COPY is split
# ---------------------------------------------------------------------------------------------
# A layer is content-addressed: one that has not changed is not rebuilt, not re-pushed and not
# re-pulled. A single `COPY . /assets` would make the whole tree one layer, so adding one furni
# would move 2.9 GB. Split, only the touched layer moves.
#
# The order is load-bearing and easy to get backwards: **Docker invalidates a changed layer and
# every layer after it**. The most stable content goes FIRST and the most frequently edited LAST.
# gamedata — furnidata, external_variables, the catalogue's own data — is what actually gets
# touched, so it is last and costs 64 MB to republish. First, every edit would rebuild all 2.9 GB.
#
# Measured on this tree:
#   dcr/hof_furni/*.nitro  1 780 MB   75 734 files   (split six ways below)
#   dcr/hof_furni/icons      139 MB   79 019 files
#   dcr/hof_furni/mp3        278 MB      806 files
#   c_images                 491 MB   52 507 files
#   gordon                   153 MB    9 607 files
#   gamedata                  64 MB       14 files

FROM caddy:2-alpine

# The origin the manifest will name. Everything the client loads after hashes.json is a URL taken
# from inside it, so this one value decides where the whole tree is fetched from — and being an
# argument is what lets the same source build a local image and the hotel's.
ARG ASSETS_BASE_URL=https://assets.vortex-hotel.online

# --- the furni bundles, six buckets by first letter ------------------------------------------------
# One layer for all 75k .nitro files would mean a new furni costs 1.8 GB. Six buckets put that at
# roughly 300 MB. The ranges carry both cases: the filenames are mixed (`AlphaFurni`, `bar_chair`)
# and Docker's pattern matching is case-sensitive even where the filesystem they came from was not.
COPY dcr/hof_furni/[0-9_.aAbBcC]*     /assets/dcr/hof_furni/
COPY dcr/hof_furni/[dDeEfFgG]*        /assets/dcr/hof_furni/
COPY dcr/hof_furni/[hHiIjJkK]*        /assets/dcr/hof_furni/
COPY dcr/hof_furni/[lLmMnNoO]*        /assets/dcr/hof_furni/
COPY dcr/hof_furni/[pPqQrRsS]*        /assets/dcr/hof_furni/
COPY dcr/hof_furni/[tTuUvVwWxXyYzZ]*  /assets/dcr/hof_furni/

# --- the rest of the static tree ---------------------------------------------------------------
COPY dcr/hof_furni/icons /assets/dcr/hof_furni/icons
COPY dcr/hof_furni/mp3   /assets/dcr/hof_furni/mp3
COPY c_images            /assets/c_images
COPY gordon              /assets/gordon

# --- what actually changes ---------------------------------------------------------------------
# Last on purpose. Everything above survives an edit here.
#
# Into /opt, not /assets: in production /assets/gamedata is a bind mount, and a mount SHADOWS
# whatever the image put there. Copied to the served path, these files would be invisible -- which
# is exactly what happened when the split texts files were added to this repo, built into the image,
# deployed successfully, and answered 404 because the host directory did not have them.
#
# So this is the seed, and the entrypoint copies from it into the mount: a file the mount does not
# have is placed, a file it already has is LEFT ALONE. The dashboard writes into that same directory
# at runtime, so overwriting would throw away an operator's edits on every restart.
COPY gamedata /opt/gamedata-default

# --- the manifest, generated ---------------------------------------------------------------------
# The same entries hashes.php emitted, with the same rule for a missing file: hash "1". That
# fallback is not a placeholder to clean up — furnidata_xml.xml and productdata_xml.xml genuinely do
# not exist in this tree, the client uses the _json pair, and the PHP behaved identically.
#
# md5sum rather than a checksum of our own choosing: it is what md5_file() produced, so a client
# holding a cached copy from the Apache days does not re-download the world on the first boot after
# the move.
#
# ---------------------------------------------------------------------------------------------
# Why this is a SCRIPT and runs at STARTUP, not just at build
# ---------------------------------------------------------------------------------------------
# /assets/gamedata is a bind mount in production (/data/vortex/gamedata on the host), because the
# dashboard writes these files at runtime — external_variables, furnidata, the texts. A mount
# SHADOWS the image's directory, so a manifest generated at build time never reaches the served
# tree, and the one being served is whatever file happens to sit in the host directory.
#
# That had already gone wrong before this script existed: on 2026-09-21 the hotel was serving a
# hashes.json from 2026-09-13 while external_variables.json beside it had been edited on the 20th.
# Eight days of gamedata edits that no client could see, because the manifest still named the old
# hashes, and nothing anywhere said so.
#
# So the manifest is regenerated on every container start, against whatever is actually mounted.
# The build-time run below stays, so the image is still correct when nothing is mounted over it.
COPY <<'GENERATE' /usr/local/bin/generate-manifest
#!/bin/sh
set -eu

# Place what the mount does not have, keep what it does. `cp -n` never overwrites, so a file the
# dashboard edited at runtime survives every restart, while a file added to the repository appears
# on the next deploy without anyone copying it onto the host by hand.
mkdir -p /assets/gamedata
(cd /opt/gamedata-default && find . -type d -exec mkdir -p /assets/gamedata/{} \;)
(cd /opt/gamedata-default && find . -type f -exec cp -n {} /assets/gamedata/{} \;)

cd /assets/gamedata

hash_of() { [ -f "$1" ] && md5sum "$1" | cut -d' ' -f1 || echo 1; }

entry() { printf '{"name":"%s","url":"%s/%s","hash":"%s"}' "$1" "$2" "$3" "$(hash_of "$4")"; }

BASE="${ASSETS_BASE_URL}/gamedata"

# Always published, with hash 1 when the file is absent: isValid() on the client wants
# external_texts, external_variables, furnidata AND productdata, and rejects the whole manifest
# without them -- leaving one out does not degrade the manifest, it kills it.
shared() {
    entry external_variables "$BASE" external_variables external_variables.json; printf ','
    entry furnidata          "$BASE" furnidata_xml      furnidata_xml.xml;       printf ','
    entry figuredata         "$BASE" figuredata         figuredata.xml;          printf ','
    entry productdata        "$BASE" productdata        productdata_xml.xml;     printf ','
    entry furnidata_json     "$BASE" furnidata_json     furnidata_json.json;     printf ','
    entry productdata_json   "$BASE" productdata_json   productdata_json.json
}

# A texts file: the language's own copy when it has one, the root otherwise, and nothing at all
# when neither exists -- an advertised file that is not there is one the client fetches and 404s
# on. So a language ships only the keys it translates: the root file loads first and the rest
# merges over it.
texts() {
    name="$1"; slug="$2"; file="$3"; lang="$4"

    if [ -n "$lang" ] && [ -f "$lang/$file" ]; then
        printf ','; entry "$name" "$BASE/$lang" "$slug" "$lang/$file"
    elif [ -f "$file" ]; then
        printf ','; entry "$name" "$BASE" "$slug" "$file"
    fi
}

# external_text_* are the texts split by domain. The client loads external_texts and then every
# external_text_* entry into the same key store, in the order they appear here -- so a key defined
# twice keeps the value from the file listed last.
manifest() {
    printf '{"hashes":['
    shared
    texts external_texts        external_flash_texts  external_flash_texts.json  "$1"
    texts external_text_catalog external_catalog_text external_catalog_text.json "$1"
    texts external_text_badges  external_badges_text  external_badges_text.json  "$1"
    printf ']}'
}

manifest "" > hashes.json

# One manifest per language directory: that is what localization.<n>.url in external_variables
# points at, and the client parses it as a manifest rather than as texts.
for dir in */; do
    lang="${dir%/}"
    case "$lang" in *[!a-zA-Z0-9-]*) continue ;; esac
    manifest "$lang" > "$lang/hashes.json"
done

# A manifest that named the wrong host would fail later and elsewhere — as a room that never
# draws — so it says so here instead. Written as an `if`, not `grep && exit`: under `set -e` the
# latter is the LAST command, so a grep that finds nothing (the good case) would fail the script.
if grep -q 'vortex-assets\.local' hashes.json; then
    echo 'generate-manifest: hashes.json still names the development host' >&2
    exit 1
fi

# The sources of the two Apache-only files have no business in the served tree. They are the
# development host's, and a mount can carry them in.
rm -f hashes.php .htaccess

echo "generate-manifest: $(grep -o '"name"' hashes.json | wc -l) entries, $(ls -d */ 2>/dev/null | wc -l) language manifest(s)"
GENERATE

# The build-time run: an image nobody mounts over still serves a correct manifest, and the
# HEALTHCHECK below has something to ask for.
RUN chmod +x /usr/local/bin/generate-manifest && ASSETS_BASE_URL="${ASSETS_BASE_URL}" /usr/local/bin/generate-manifest

# Regenerate against whatever is mounted, then hand over to Caddy's own entrypoint unchanged.
COPY <<'ENTRYPOINT' /usr/local/bin/entrypoint
#!/bin/sh
set -eu
/usr/local/bin/generate-manifest || echo 'entrypoint: manifest generation failed, serving what is there' >&2
exec /usr/bin/caddy "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/entrypoint

# --- how it is served ----------------------------------------------------------------------------
COPY <<'CADDYFILE' /etc/caddy/Caddyfile
{
	# Coolify's proxy terminates TLS in front of this container, so Caddy serves plain HTTP on :80
	# and must not try to obtain a certificate of its own.
	auto_https off
}

:80 {
	# The .htaccess exclusion, kept and for the reason it gave: furnidata and productdata are tens
	# of megabytes and were measured arriving in 70-120 ms uncompressed, which a per-request
	# compression pass does not beat. Everything else is compressed.
	@compressible not path /gamedata/furnidata* /gamedata/productdata*
	encode @compressible zstd gzip

	root * /assets

	# What .htaccess did with seven RewriteRules. The client asks for <name>/<hash> — the hash is
	# a cache-buster in the path, not a directory — and each maps to one real file.
	@texts            path /gamedata/external_flash_texts/*
	@catalog_texts    path /gamedata/external_catalog_text/*
	@badges_texts     path /gamedata/external_badges_text/*
	@variables        path /gamedata/external_variables/*
	@furnidata_xml    path /gamedata/furnidata_xml/*
	@figuredata       path /gamedata/figuredata/*
	@productdata_xml  path /gamedata/productdata/*
	@furnidata_json   path /gamedata/furnidata_json/*
	@productdata_json path /gamedata/productdata_json/*

	rewrite @texts            /gamedata/external_flash_texts.json
	rewrite @catalog_texts    /gamedata/external_catalog_text.json
	rewrite @badges_texts     /gamedata/external_badges_text.json
	rewrite @variables        /gamedata/external_variables.json
	rewrite @furnidata_xml    /gamedata/furnidata_xml.xml
	rewrite @figuredata       /gamedata/figuredata.xml
	rewrite @productdata_xml  /gamedata/productdata_xml.xml
	rewrite @furnidata_json   /gamedata/furnidata_json.json
	rewrite @productdata_json /gamedata/productdata_json.json

	# The same thing one directory down, for every language at once. A regexp rather than nine more
	# matchers per language: the set of languages is decided in external_variables, not here, and a
	# language whose rewrite someone forgot to add would lose its texts silently.
	# It cannot swallow the rules above: it needs three segments after /gamedata/, and the second
	# has to start with `external_`.
	@lang_texts path_regexp lt ^/gamedata/([a-zA-Z0-9-]+)/(external_[a-z_]+)/.+$
	rewrite @lang_texts /gamedata/{re.lt.1}/{re.lt.2}.json

	# `hashes` and `hashes.json` both answered the PHP; now both answer the generated file.
	rewrite /gamedata/hashes /gamedata/hashes.json

	@lang_hashes path_regexp lh ^/gamedata/([a-zA-Z0-9-]+)/hashes(\.json)?$
	rewrite @lang_hashes /gamedata/{re.lh.1}/hashes.json

	file_server

	# The header the separate hostname pays for. The client reads hashes.json, furnidata,
	# figuredata and every .nitro through fetch/XHR, and loads images into WebGL textures.
	# Cross-origin, all of that needs this — and without it the hotel's login screen works
	# perfectly while no room ever draws, with nothing obvious in the network tab.
	#
	# `*` rather than the hotel's origin: these are public files fetched without credentials, and a
	# wildcard needs no `Vary: Origin` to stay cacheable at a CDN later.
	header Access-Control-Allow-Origin "*"

	# The tree is content-addressed through hashes.json, so a long max-age is safe and is what
	# keeps a room from re-fetching a thousand files on every visit. The manifest itself is the one
	# thing that must not be cached, or a new hash would never be seen.
	header Cache-Control "public, max-age=604800"
	header /gamedata/hashes* Cache-Control "no-cache"

	# Same for a language's own manifest: `/gamedata/hashes*` does not match one directory down, so
	# without this a translation would be published and no client would see it until its cache aged
	# out a week later.
	@any_hashes path_regexp ^/gamedata/([a-zA-Z0-9-]+/)?hashes(\.json)?$
	header @any_hashes Cache-Control "no-cache"
}
CADDYFILE

# An ARG exists only during the build, and the entrypoint needs the same value at every start --
# without this the regenerated manifest would name an empty host and no asset would load.
ENV ASSETS_BASE_URL=${ASSETS_BASE_URL}

EXPOSE 80

# Redefining ENTRYPOINT resets the base image's CMD, so caddy's own arguments are restated here
# rather than inherited. They are the ones caddy:2-alpine ships.
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

# `/gamedata/hashes.json`, not `/`. There is no index page in this tree, so `/` answers 404 and
# would report a perfectly healthy asset host as broken.
#
# The manifest is also the right thing to ask for: it is the one file this build GENERATES rather
# than copies, and every URL the client loads afterwards comes from inside it. A 200 here proves
# the RUN block above produced it and that Caddy is serving the tree; if it is missing, the login
# screen still works and no room ever draws.
#
# wget is the busybox applet in the alpine base — this image ships no other HTTP client.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/gamedata/hashes.json || exit 1
