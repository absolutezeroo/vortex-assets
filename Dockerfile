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
# matchers at the bottom of this file, one per line, the same seven.
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
COPY gamedata /assets/gamedata

# --- the manifest, generated ---------------------------------------------------------------------
# The same seven entries hashes.php emitted, in the same order, with the same rule for a missing
# file: hash "1". That fallback is not a placeholder to clean up — furnidata_xml.xml and
# productdata_xml.xml genuinely do not exist in this tree, the client uses the _json pair, and the
# PHP behaved identically.
#
# md5sum rather than a checksum of our own choosing: it is what md5_file() produced, so a client
# holding a cached copy from the Apache days does not re-download the world on the first boot after
# the move.
RUN <<'GENERATE' sh
set -eu

cd /assets/gamedata

hash_of() { [ -f "$1" ] && md5sum "$1" | cut -d' ' -f1 || echo 1; }

entry() { printf '{"name":"%s","url":"%s/%s","hash":"%s"}' "$1" "$BASE" "$2" "$(hash_of "$3")"; }

BASE="${ASSETS_BASE_URL}/gamedata"

{
    printf '{"hashes":['
    entry external_texts     external_flash_texts external_flash_texts.json; printf ','
    entry external_variables external_variables   external_variables.json;   printf ','
    entry furnidata          furnidata_xml        furnidata_xml.xml;         printf ','
    entry figuredata         figuredata           figuredata.xml;            printf ','
    entry productdata        productdata          productdata_xml.xml;       printf ','
    entry furnidata_json     furnidata_json       furnidata_json.json;       printf ','
    entry productdata_json   productdata_json     productdata_json.json
    printf ']}'
} > hashes.json

# A manifest that named the wrong host would fail later and elsewhere — as a room that never
# draws — so it fails here instead. Written as an `if`, not `grep && exit`: under `set -e` the
# latter is the LAST command, so a grep that finds nothing (the good case) would fail the build.
if grep -q 'vortex-assets\.local' hashes.json; then
    echo 'hashes.json still names the development host'
    exit 1
fi

# The sources of the two Apache-only files have no business in the image.
rm -f hashes.php .htaccess
GENERATE

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
	@variables        path /gamedata/external_variables/*
	@furnidata_xml    path /gamedata/furnidata_xml/*
	@figuredata       path /gamedata/figuredata/*
	@productdata_xml  path /gamedata/productdata/*
	@furnidata_json   path /gamedata/furnidata_json/*
	@productdata_json path /gamedata/productdata_json/*

	rewrite @texts            /gamedata/external_flash_texts.json
	rewrite @variables        /gamedata/external_variables.json
	rewrite @furnidata_xml    /gamedata/furnidata_xml.xml
	rewrite @figuredata       /gamedata/figuredata.xml
	rewrite @productdata_xml  /gamedata/productdata_xml.xml
	rewrite @furnidata_json   /gamedata/furnidata_json.json
	rewrite @productdata_json /gamedata/productdata_json.json

	# `hashes` and `hashes.json` both answered the PHP; now both answer the generated file.
	rewrite /gamedata/hashes /gamedata/hashes.json

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
}
CADDYFILE

EXPOSE 80

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
