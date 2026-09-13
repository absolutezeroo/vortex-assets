#!/bin/sh
# Pushes the asset tree to GitHub in chunks.
#
# GitHub refuses a single push over roughly 2 GB — the server answers HTTP 500 after receiving the
# whole pack, which reads like a network failure and is not one. The tree is 2.9 GB, so it goes up
# as a series of commits, each pushed on its own. Objects already sent are never sent again, so the
# total transfer is the same; only the packs are smaller.
#
# Re-runnable: a chunk with nothing new commits nothing and pushes nothing.
set -eu

cd "${ASSETS_DIR:-/c/Laragon/www/vortex-assets}"

# The first attempt made one commit holding the whole tree, which is exactly what cannot be pushed.
# Undo it while leaving every file on disk untouched. `update-ref -d` rather than `reset --soft
# HEAD~1`: the commit to undo is the repository's first, and it has no parent to reset to.
if [ -z "$(git log --oneline -n 2 2>/dev/null | sed -n 2p)" ] && git rev-parse HEAD >/dev/null 2>&1; then
    if ! git ls-remote --exit-code origin main >/dev/null 2>&1; then
        echo "== le commit initial est défait ; les fichiers restent sur le disque"
        git update-ref -d HEAD
        git reset -q
    fi
fi

# `git init` created `master` here, and the workflow triggers on `main`. `symbolic-ref` rather than
# `branch -M`: after the undo above the branch has no commit yet, and `branch -M` refuses to rename
# a branch that does not exist.
if [ "$(git symbolic-ref --short HEAD)" != "main" ]; then
    echo "== branche renommée en main"
    git symbolic-ref HEAD refs/heads/main
fi

step() {
    label="$1"
    shift

    # `--` so a pathspec starting with a dash cannot be read as an option.
    git add -- "$@"

    if git diff --cached --quiet; then
        echo "== $label: rien à commiter"
    else
        echo "== $label: commit"
        git commit -q -m "assets: $label"
    fi

    # Outside the branch above, deliberately. A chunk whose commit already exists can still be
    # unpushed — which is exactly the state a failed push leaves behind — and returning early there
    # would skip it silently on the retry, leaving the run "successful" with work still local.
    if [ -z "$(git log --oneline "@{u}..HEAD" 2>/dev/null)" ] && git rev-parse '@{u}' >/dev/null 2>&1; then
        echo "== $label: déjà poussé"
        return
    fi

    echo "== $label: push"
    git push -q -u origin main
    echo "== $label: fait"
}

# The recipe first, so the repository is usable even if a later chunk has to be retried.
step "the recipe" Dockerfile .dockerignore .gitattributes .github

# Smallest to largest: an early failure then costs the least to diagnose.
step "gamedata" gamedata
step "gordon" gordon
step "furni icons" dcr/hof_furni/icons
step "furni sounds" dcr/hof_furni/mp3
step "c_images" c_images

# The 1.78 GB of .nitro bundles, in the same six buckets the Dockerfile copies them in — each
# around 300 MB, comfortably under the limit. Quoted so git expands the pattern itself: unquoted,
# the shell would expand 75 000 filenames onto one command line.
step "furni a-c" 'dcr/hof_furni/[0-9_.aAbBcC]*'
step "furni d-g" 'dcr/hof_furni/[dDeEfFgG]*'
step "furni h-k" 'dcr/hof_furni/[hHiIjJkK]*'
step "furni l-o" 'dcr/hof_furni/[lLmMnNoO]*'
step "furni p-s" 'dcr/hof_furni/[pPqQrRsS]*'
step "furni t-z" 'dcr/hof_furni/[tTuUvVwWxXyYzZ]*'

# Anything the patterns above did not catch — a name starting with a character none of them list.
step "the remainder" .

echo
echo "Terminé. Vérifie l'onglet Actions : le workflow bâtit l'image."
