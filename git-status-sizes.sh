#!/usr/bin/env bash
# git-status-sizes.sh
# Affiche les fichiers de `git status` avec leur taille, en highlightant les gros fichiers.

# Seuils (en octets)
WARN_BYTES=$((500 * 1024))   # 500 Ko  → jaune
CRIT_BYTES=$((1 * 1024 * 1024))  # 1 Mo   → rouge

# Couleurs ANSI
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Formatage lisible d'une taille en octets
human_size() {
    local bytes=$1
    awk -v b="$bytes" 'BEGIN {
        if      (b >= 1073741824) printf "%.1f Go", b/1073741824
        else if (b >= 1048576)   printf "%.1f Mo", b/1048576
        else if (b >= 1024)      printf "%.1f Ko", b/1024
        else                     printf "%d B",    b
    }'
}

# Vérifie qu'on est dans un repo git
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌  Pas dans un dépôt git." >&2
    exit 1
fi

# Récupère les fichiers depuis git status (porcelain = format stable)
# Colonnes 1-2 : status XY, colonne 4+ : path (gère les renames "old -> new")
mapfile -t lines < <(git status --porcelain)

if [[ ${#lines[@]} -eq 0 ]]; then
    echo "✅  Rien à signaler (working tree propre)."
    exit 0
fi

# En-tête
printf "\n${BOLD}%-6s  %-10s  %s${RESET}\n" "ST" "TAILLE" "FICHIER"
printf '%s\n' "------  ----------  $(printf '%.0s-' {1..60})"

total_warn=0
total_crit=0

for line in "${lines[@]}"; do
    # Status = 2 premiers caractères
    xy="${line:0:2}"
    # Fichier = reste (après l'espace), gestion des renames (A -> B)
    rest="${line:3}"
    # Pour les renames git indique "ancien -> nouveau", on prend la destination
    if [[ "$rest" == *" -> "* ]]; then
        filepath="${rest##* -> }"
    else
        filepath="$rest"
    fi
    # Supprime les guillemets éventuels (chemins avec espaces)
    filepath="${filepath//\"/}"

    # Fichier supprimé : pas de taille sur disque
    if [[ "${xy:0:1}" == "D" || "${xy:1:1}" == "D" ]]; then
        printf "${DIM}%-6s  %-10s  %s${RESET}\n" "$xy" "(deleted)" "$filepath"
        continue
    fi

    if [[ -f "$filepath" ]]; then
        size_bytes=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
        size_human=$(human_size "$size_bytes")

        if (( size_bytes >= CRIT_BYTES )); then
            color=$RED
            label="⚠️  !!!"
            (( total_crit++ ))
        elif (( size_bytes >= WARN_BYTES )); then
            color=$YELLOW
            label="⚠️   ! "
            (( total_warn++ ))
        else
            color=$GREEN
            label=""
        fi

        printf "${color}%-6s  %-10s  %s %s${RESET}\n" \
            "$xy" "$size_human" "$filepath" "$label"
    else
        printf "${DIM}%-6s  %-10s  %s${RESET}\n" "$xy" "?" "$filepath"
    fi
done

# Résumé
echo ""
if (( total_crit > 0 )); then
    echo -e "${RED}${BOLD}$total_crit fichier(s) dépassent 1 Mo — vérifier avant de committer !${RESET}"
fi
if (( total_warn > 0 )); then
    echo -e "${YELLOW}$total_warn fichier(s) entre 500 Ko et 1 Mo.${RESET}"
fi
echo ""
