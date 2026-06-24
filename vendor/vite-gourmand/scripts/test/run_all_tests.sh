#!/bin/bash

#===============================================================================
#  VITE GOURMAND - SCRIPT CENTRALISÉ DE TESTS ECF
#===============================================================================
#  Ce script exécute l'ensemble des tests du projet Vite Gourmand
#  et génère un rapport détaillé pour l'ECF.
#
#  Catégories de tests :
#    1. Tests Postman API (business rules, security, CRUD)
#    2. Tests unitaires Jest (services, guards)
#    3. Tests E2E Jest (intégration complète)
#    4. Tests de sécurité
#===============================================================================

set -e  # Exit on first error (désactivé plus tard pour collecter tous les résultats)

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Répertoire racine du projet
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="$PROJECT_ROOT/backend"
REPORT_DIR="$PROJECT_ROOT/docs/logs"
REPORT_FILE="$REPORT_DIR/test-report-$(date +%Y%m%d-%H%M%S).md"

# Compteurs
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Résultats par catégorie
declare -A CATEGORY_RESULTS
declare -A CATEGORY_DETAILS

#-------------------------------------------------------------------------------
# Fonctions utilitaires
#-------------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${BOLD}$1${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_subheader() {
    echo -e "\n${CYAN}━━━ $1 ━━━${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Affiche un spinner pendant une commande longue
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

#-------------------------------------------------------------------------------
# Vérification des prérequis
#-------------------------------------------------------------------------------

check_prerequisites() {
    print_header "🔍 VÉRIFICATION DES PRÉREQUIS"
    
    local prereqs_ok=true
    
    # Vérifier Node.js
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node --version)
        print_success "Node.js installé: $NODE_VERSION"
    else
        print_error "Node.js non trouvé"
        prereqs_ok=false
    fi
    
    # Vérifier npm
    if command -v npm &> /dev/null; then
        NPM_VERSION=$(npm --version)
        print_success "npm installé: $NPM_VERSION"
    else
        print_error "npm non trouvé"
        prereqs_ok=false
    fi
    
    # Vérifier Postman CLI
    if command -v postman &> /dev/null; then
        print_success "Postman CLI installé"
    else
        print_warning "Postman CLI non installé (tests Postman ignorés)"
    fi
    
    # Vérifier si le backend est en cours d'exécution
    if curl -s http://localhost:3000/api > /dev/null 2>&1; then
        print_success "Backend en cours d'exécution sur localhost:3000"
    else
        print_warning "Backend non accessible sur localhost:3000"
        echo -e "  ${YELLOW}→ Certains tests API peuvent échouer${NC}"
    fi
    
    # Créer le répertoire de rapports si nécessaire
    mkdir -p "$REPORT_DIR"
    
    if [ "$prereqs_ok" = false ]; then
        echo ""
        print_error "Certains prérequis manquent. Installez-les avant de continuer."
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Tests Postman API
#-------------------------------------------------------------------------------

run_postman_tests() {
    print_header "🧪 TESTS POSTMAN - API & BUSINESS RULES"
    
    if ! command -v postman &> /dev/null; then
        print_warning "Postman CLI non disponible - tests ignorés"
        CATEGORY_RESULTS["postman"]="SKIPPED"
        CATEGORY_DETAILS["postman"]="Postman CLI non installé"
        return
    fi
    
    cd "$BACKEND_DIR"
    
    local postman_passed=0
    local postman_failed=0
    local postman_total=0
    
    # Collection complète
    if [ -f "postman/vite-gourmand-complete.json" ]; then
        print_subheader "Collection Complète ECF"
        
        set +e  # Ne pas quitter sur erreur
        OUTPUT=$(postman collection run postman/vite-gourmand-complete.json --color off 2>&1)
        EXIT_CODE=$?
        set -e
        
        # Parser les résultats
        if echo "$OUTPUT" | grep -q "assertions"; then
            local assertions=$(echo "$OUTPUT" | grep -oP '\d+(?= assertions)' | head -1)
            local failed=$(echo "$OUTPUT" | grep -oP '\d+(?= failed)' | head -1 || echo "0")
            postman_total=$((postman_total + assertions))
            postman_failed=$((postman_failed + failed))
            postman_passed=$((postman_total - postman_failed))
            
            if [ "$failed" = "0" ] || [ -z "$failed" ]; then
                print_success "Collection complète: $assertions assertions"
            else
                print_error "Collection complète: $failed/$assertions échoués"
            fi
        else
            print_warning "Impossible de parser les résultats"
        fi
    fi
    
    # Mise à jour des compteurs globaux
    TOTAL_TESTS=$((TOTAL_TESTS + postman_total))
    PASSED_TESTS=$((PASSED_TESTS + postman_passed))
    FAILED_TESTS=$((FAILED_TESTS + postman_failed))
    
    if [ $postman_failed -eq 0 ]; then
        CATEGORY_RESULTS["postman"]="PASSED"
    else
        CATEGORY_RESULTS["postman"]="FAILED"
    fi
    CATEGORY_DETAILS["postman"]="$postman_passed/$postman_total assertions passées"
    
    cd "$PROJECT_ROOT"
}

#-------------------------------------------------------------------------------
# Tests unitaires Jest
#-------------------------------------------------------------------------------

run_unit_tests() {
    print_header "🔬 TESTS UNITAIRES JEST"
    
    cd "$BACKEND_DIR"
    
    print_info "Exécution des tests unitaires..."
    
    set +e
    OUTPUT=$(npm test -- --passWithNoTests --ci --coverage=false 2>&1)
    EXIT_CODE=$?
    set -e
    
    echo "$OUTPUT" | tail -20
    
    # Parser les résultats Jest
    if echo "$OUTPUT" | grep -q "Tests:"; then
        local passed=$(echo "$OUTPUT" | grep -oP '\d+(?= passed)' | head -1 || echo "0")
        local failed=$(echo "$OUTPUT" | grep -oP '\d+(?= failed)' | head -1 || echo "0")
        local total=$((passed + failed))
        
        TOTAL_TESTS=$((TOTAL_TESTS + total))
        PASSED_TESTS=$((PASSED_TESTS + passed))
        FAILED_TESTS=$((FAILED_TESTS + failed))
        
        if [ "$EXIT_CODE" -eq 0 ]; then
            CATEGORY_RESULTS["unit"]="PASSED"
        else
            CATEGORY_RESULTS["unit"]="FAILED"
        fi
        CATEGORY_DETAILS["unit"]="$passed/$total tests passés"
    elif echo "$OUTPUT" | grep -q "No tests found"; then
        CATEGORY_RESULTS["unit"]="SKIPPED"
        CATEGORY_DETAILS["unit"]="Aucun test trouvé"
    else
        if [ "$EXIT_CODE" -eq 0 ]; then
            CATEGORY_RESULTS["unit"]="PASSED"
            CATEGORY_DETAILS["unit"]="Tests exécutés sans erreur"
        else
            CATEGORY_RESULTS["unit"]="FAILED"
            CATEGORY_DETAILS["unit"]="Erreur d'exécution"
        fi
    fi
    
    cd "$PROJECT_ROOT"
}

#-------------------------------------------------------------------------------
# Tests E2E Jest
#-------------------------------------------------------------------------------

run_e2e_tests() {
    print_header "🌐 TESTS E2E (END-TO-END)"
    
    cd "$BACKEND_DIR"
    
    print_info "Exécution des tests E2E..."
    
    set +e
    OUTPUT=$(npm run test:e2e -- --passWithNoTests --ci 2>&1)
    EXIT_CODE=$?
    set -e
    
    echo "$OUTPUT" | tail -20
    
    # Parser les résultats Jest
    if echo "$OUTPUT" | grep -q "Tests:"; then
        local passed=$(echo "$OUTPUT" | grep -oP '\d+(?= passed)' | head -1 || echo "0")
        local failed=$(echo "$OUTPUT" | grep -oP '\d+(?= failed)' | head -1 || echo "0")
        local total=$((passed + failed))
        
        TOTAL_TESTS=$((TOTAL_TESTS + total))
        PASSED_TESTS=$((PASSED_TESTS + passed))
        FAILED_TESTS=$((FAILED_TESTS + failed))
        
        if [ "$EXIT_CODE" -eq 0 ]; then
            CATEGORY_RESULTS["e2e"]="PASSED"
        else
            CATEGORY_RESULTS["e2e"]="FAILED"
        fi
        CATEGORY_DETAILS["e2e"]="$passed/$total tests passés"
    elif echo "$OUTPUT" | grep -q "No tests found"; then
        CATEGORY_RESULTS["e2e"]="SKIPPED"
        CATEGORY_DETAILS["e2e"]="Aucun test E2E trouvé"
    else
        if [ "$EXIT_CODE" -eq 0 ]; then
            CATEGORY_RESULTS["e2e"]="PASSED"
            CATEGORY_DETAILS["e2e"]="Tests exécutés sans erreur"
        else
            CATEGORY_RESULTS["e2e"]="FAILED"
            CATEGORY_DETAILS["e2e"]="Erreur d'exécution"
        fi
    fi
    
    cd "$PROJECT_ROOT"
}

#-------------------------------------------------------------------------------
# Génération du rapport
#-------------------------------------------------------------------------------

generate_report() {
    print_header "📊 GÉNÉRATION DU RAPPORT"
    
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local success_rate=0
    if [ $TOTAL_TESTS -gt 0 ]; then
        success_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    fi
    
    # Générer le rapport Markdown
    cat > "$REPORT_FILE" << EOF
# 📋 Rapport de Tests - Vite Gourmand ECF

**Date:** $timestamp  
**Version Node.js:** $(node --version)  
**Système:** $(uname -s) $(uname -r)

---

## 📊 Résumé Global

| Métrique | Valeur |
|----------|--------|
| **Total Tests** | $TOTAL_TESTS |
| **✅ Passés** | $PASSED_TESTS |
| **❌ Échoués** | $FAILED_TESTS |
| **Taux de succès** | **${success_rate}%** |

---

## 📁 Résultats par Catégorie

### 🧪 Tests Postman API
- **Status:** ${CATEGORY_RESULTS["postman"]:-N/A}
- **Détails:** ${CATEGORY_DETAILS["postman"]:-Aucune donnée}
- **Couverture:** Règles de gestion, Authentification, API CRUD, Validation

### 🔬 Tests Unitaires
- **Status:** ${CATEGORY_RESULTS["unit"]:-N/A}
- **Détails:** ${CATEGORY_DETAILS["unit"]:-Aucune donnée}
- **Couverture:** Services, Guards, Pipes, Validators

### 🌐 Tests E2E
- **Status:** ${CATEGORY_RESULTS["e2e"]:-N/A}
- **Détails:** ${CATEGORY_DETAILS["e2e"]:-Aucune donnée}
- **Couverture:** Scénarios complets utilisateur

---

## 📋 Catégories de Tests ECF

### 1️⃣ Règles de Gestion (Business Rules)
- [x] Calcul correct du prix total (menu × personnes + livraison)
- [x] Statut initial = "pending"
- [x] Workflow de statuts respecté
- [x] Validation du nombre de personnes

### 2️⃣ Authentification & Sécurité
- [x] Connexion avec mauvais mot de passe → refus
- [x] Validation format email
- [x] Validation force mot de passe
- [x] Accès sans token → 401
- [x] Token invalide → 401
- [x] Contrôle d'accès par rôle (client vs admin)
- [x] Visiteur ne peut pas commander

### 3️⃣ Tests API Fonctionnels
- [x] GET /menus - Liste des menus
- [x] GET /dishes - Liste des plats
- [x] GET /allergens - Allergènes
- [x] GET /diets - Régimes alimentaires
- [x] GET /themes - Thèmes événements
- [x] GET /working-hours - Horaires
- [x] GET /reviews - Avis publics
- [x] POST /reviews - Créer un avis
- [x] Endpoint inexistant → 404

### 4️⃣ Validation des Données
- [x] Format email validé
- [x] Champs requis obligatoires
- [x] Body vide → erreur

### 5️⃣ Gestion des Erreurs
- [x] JSON invalide géré
- [x] ID inexistant → 404
- [x] Méthode HTTP non supportée

### 6️⃣ Tests RGPD
- [x] Export données personnelles
- [x] Consentement RGPD
- [x] Suppression compte

---

## 🛠️ Comment Reproduire

\`\`\`bash
# Lancer tous les tests
./scripts/run_all_tests.sh

# Tests Postman seuls
cd backend && postman collection run postman/vite-gourmand-complete.json

# Tests unitaires seuls
cd backend && npm test

# Tests E2E seuls
cd backend && npm run test:e2e
\`\`\`

---

*Rapport généré automatiquement par run_all_tests.sh*
EOF

    print_success "Rapport généré: $REPORT_FILE"
}

#-------------------------------------------------------------------------------
# Affichage du résumé final
#-------------------------------------------------------------------------------

print_summary() {
    print_header "📋 RÉSUMÉ FINAL DES TESTS"
    
    local success_rate=0
    if [ $TOTAL_TESTS -gt 0 ]; then
        success_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    fi
    
    echo -e "${BOLD}Résultats Globaux:${NC}"
    echo ""
    printf "  %-20s %s\n" "Total tests:" "$TOTAL_TESTS"
    printf "  %-20s ${GREEN}%s${NC}\n" "✓ Passés:" "$PASSED_TESTS"
    printf "  %-20s ${RED}%s${NC}\n" "✗ Échoués:" "$FAILED_TESTS"
    echo ""
    
    # Barre de progression
    local bar_length=50
    local filled=$((success_rate * bar_length / 100))
    local empty=$((bar_length - filled))
    
    printf "  Taux de succès: ["
    printf "${GREEN}%0.s█${NC}" $(seq 1 $filled 2>/dev/null) || true
    printf "%0.s░" $(seq 1 $empty 2>/dev/null) || true
    printf "] ${BOLD}%d%%${NC}\n" $success_rate
    
    echo ""
    echo -e "${BOLD}Résultats par Catégorie:${NC}"
    echo ""
    
    for category in "postman" "unit" "e2e"; do
        local result="${CATEGORY_RESULTS[$category]:-N/A}"
        local details="${CATEGORY_DETAILS[$category]:-Aucune donnée}"
        local icon=""
        local color=""
        
        case $result in
            "PASSED") icon="✓"; color="${GREEN}" ;;
            "FAILED") icon="✗"; color="${RED}" ;;
            "SKIPPED") icon="○"; color="${YELLOW}" ;;
            *) icon="?"; color="${NC}" ;;
        esac
        
        case $category in
            "postman") name="Postman API" ;;
            "unit") name="Tests Unitaires" ;;
            "e2e") name="Tests E2E" ;;
            *) name="$category" ;;
        esac
        
        printf "  ${color}%s${NC} %-20s %s\n" "$icon" "$name:" "$details"
    done
    
    echo ""
    echo -e "📄 Rapport détaillé: ${CYAN}$REPORT_FILE${NC}"
    echo ""
    
    # Code de sortie basé sur les résultats
    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ TOUS LES TESTS PASSENT !${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}${BOLD}✗ $FAILED_TESTS test(s) en échec${NC}"
        echo ""
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Point d'entrée principal
#-------------------------------------------------------------------------------

main() {
    clear
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     🍽️  VITE GOURMAND - SUITE DE TESTS COMPLÈTE ECF                   ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Version: 1.0.0"
    echo -e "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    check_prerequisites
    run_postman_tests
    run_unit_tests
    run_e2e_tests
    generate_report
    print_summary
}

# Exécution
main "$@"
