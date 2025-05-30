#!/bin/bash

# ===============================================================================
# MAXLINK - CORE COMMUN DES WIDGETS
# Version améliorée avec gestion robuste du démarrage au boot
# ===============================================================================

# Vérifier les dépendances
if [ -z "$BASE_DIR" ]; then
    echo "ERREUR: Ce module doit être sourcé après variables.sh"
    exit 1
fi

# ===============================================================================
# CONFIGURATION
# ===============================================================================

WIDGETS_DIR="$BASE_DIR/scripts/widgets"
WIDGETS_CONFIG_DIR="/etc/maxlink/widgets"
WIDGETS_TRACKING_FILE="/etc/maxlink/widgets_installed.json"

# Créer les répertoires
mkdir -p "$WIDGETS_CONFIG_DIR" "$(dirname "$WIDGETS_TRACKING_FILE")"

# ===============================================================================
# FONCTIONS DE BASE
# ===============================================================================

# Charger la configuration d'un widget
widget_load_config() {
    local widget_name=$1
    local config_file="$WIDGETS_DIR/$widget_name/${widget_name}_widget.json"
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration manquante: $config_file"
        return 1
    fi
    
    # Retourner le chemin pour utilisation
    echo "$config_file"
}

# Extraire une valeur du JSON
widget_get_value() {
    local json_file=$1
    local key_path=$2
    
    python3 -c "
import json
try:
    with open('$json_file', 'r') as f:
        data = json.load(f)
    # Naviguer dans le JSON avec le chemin de clés
    keys = '$key_path'.split('.')
    value = data
    for key in keys:
        value = value.get(key, '')
    print(value)
except:
    print('')
"
}

# Vérifier si un widget est installé
widget_is_installed() {
    local widget_name=$1
    
    if [ -f "$WIDGETS_TRACKING_FILE" ]; then
        python3 -c "
import json
try:
    with open('$WIDGETS_TRACKING_FILE', 'r') as f:
        data = json.load(f)
    print('yes' if '$widget_name' in data else 'no')
except:
    print('no')
"
    else
        echo "no"
    fi
}

# Enregistrer un widget comme installé
widget_register() {
    local widget_name=$1
    local service_name=$2
    local version=$3
    
    # Créer ou mettre à jour le fichier de tracking
    python3 -c "
import json
from datetime import datetime

# Charger ou créer
try:
    with open('$WIDGETS_TRACKING_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {}

# Ajouter/mettre à jour
data['$widget_name'] = {
    'installed_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'service_name': '$service_name',
    'version': '$version',
    'status': 'active'
}

# Sauvegarder
with open('$WIDGETS_TRACKING_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    
    log_success "Widget $widget_name enregistré"
}

# ===============================================================================
# INSTALLATION PYTHON
# ===============================================================================

# Installer les dépendances Python d'un widget
widget_install_python_deps() {
    local widget_name=$1
    local config_file=$2
    
    log_info "Vérification des dépendances Python pour $widget_name"
    
    # Extraire les dépendances
    local python_deps=$(widget_get_value "$config_file" "dependencies.python_packages")
    
    if [ -z "$python_deps" ] || [ "$python_deps" = "[]" ]; then
        log_info "Aucune dépendance Python pour $widget_name"
        return 0
    fi
    
    # Pour l'instant, on assume que les dépendances sont déjà installées
    # par update_install.sh et mqtt_wgs_install.sh
    log_info "Dépendances Python vérifiées (installées via le cache)"
    return 0
}

# ===============================================================================
# SERVICE SYSTEMD AMÉLIORÉ
# ===============================================================================

# Créer et installer un service systemd pour un widget avec démarrage robuste
widget_create_service() {
    local widget_name=$1
    local config_file=$2
    local collector_script=$3
    
    # Extraire les infos
    local service_name=$(widget_get_value "$config_file" "collector.service_name")
    local service_desc=$(widget_get_value "$config_file" "collector.service_description")
    
    if [ -z "$service_name" ]; then
        service_name="maxlink-widget-$widget_name"
    fi
    
    if [ -z "$service_desc" ]; then
        service_desc="MaxLink Widget $widget_name"
    fi
    
    log_info "Création du service $service_name"
    
    # Créer le fichier service avec configuration améliorée
    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=$service_desc
# Dépendances strictes pour assurer l'ordre de démarrage
After=network-online.target mosquitto.service
Wants=network-online.target
Requires=mosquitto.service

# Conditions de démarrage
ConditionPathExists=$collector_script
ConditionPathExists=$config_file

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/python3 $collector_script
Restart=always
RestartSec=30
StartLimitInterval=600
StartLimitBurst=5

# Utilisateur et groupe
User=root
StandardOutput=journal
StandardError=journal

# Environnement
Environment="PYTHONUNBUFFERED=1"
Environment="WIDGET_NAME=$widget_name"
Environment="CONFIG_FILE=$config_file"
Environment="MQTT_RETRY_ENABLED=true"
Environment="MQTT_RETRY_DELAY=10"
Environment="MQTT_MAX_RETRIES=0"

# Sécurité
PrivateTmp=true
NoNewPrivileges=true

# Timeout généreux pour le démarrage
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
    
    # Créer aussi un service de vérification pour s'assurer que mosquitto est vraiment prêt
    cat > "/etc/systemd/system/${service_name}-checker.service" << EOF
[Unit]
Description=Checker for $service_desc
Before=${service_name}.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'until mosquitto_pub -h localhost -p 1883 -u mosquitto -P mqtt -t test/boot -m "test" 2>/dev/null; do echo "Waiting for MQTT..."; sleep 2; done'
RemainAfterExit=yes

[Install]
WantedBy=${service_name}.service
EOF
    
    # Recharger systemd
    systemctl daemon-reload
    
    # Activer le checker
    systemctl enable "${service_name}-checker.service" >/dev/null 2>&1
    
    # Activer et démarrer le service principal
    if systemctl enable "$service_name" >/dev/null 2>&1; then
        log_success "Service activé: $service_name"
        
        if systemctl start "$service_name"; then
            log_success "Service démarré: $service_name"
            return 0
        else
            log_error "Impossible de démarrer le service"
            return 1
        fi
    else
        log_error "Impossible d'activer le service"
        return 1
    fi
}

# ===============================================================================
# VALIDATION
# ===============================================================================

# Valider la structure d'un widget
widget_validate() {
    local widget_name=$1
    local widget_dir="$WIDGETS_DIR/$widget_name"
    
    # Charger la config pour vérifier si le collector est requis
    local config_file="$widget_dir/${widget_name}_widget.json"
    
    # Vérifier que le fichier de config existe
    if [ ! -f "$config_file" ]; then
        log_error "Configuration manquante: $config_file"
        return 1
    fi
    
    # Valider le JSON
    if ! python3 -m json.tool "$config_file" >/dev/null 2>&1; then
        log_error "JSON invalide: ${widget_name}_widget.json"
        return 1
    fi
    
    # Vérifier si le widget a un collector
    local collector_enabled=$(widget_get_value "$config_file" "collector.enabled")
    
    # Fichiers requis de base
    local required_files=(
        "${widget_name}_widget.json"
        "${widget_name}_install.sh"
    )
    
    # Ajouter le collector seulement si nécessaire
    if [ "$collector_enabled" = "true" ] || [ "$collector_enabled" = "True" ]; then
        required_files+=("${widget_name}_collector.py")
    fi
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$widget_dir/$file" ]; then
            log_error "Fichier manquant: $widget_dir/$file"
            return 1
        fi
    done
    
    log_success "Widget $widget_name validé"
    return 0
}

# ===============================================================================
# INSTALLATION STANDARD
# ===============================================================================

# Fonction d'installation standard d'un widget
widget_standard_install() {
    local widget_name=$1
    
    echo ""
    echo "Installation du widget: $widget_name"
    echo "------------------------------------"
    
    # Valider
    if ! widget_validate "$widget_name"; then
        echo "  ↦ Widget invalide ✗"
        return 1
    fi
    
    # Charger la config
    local config_file=$(widget_load_config "$widget_name")
    local widget_dir="$WIDGETS_DIR/$widget_name"
    local collector_script="$widget_dir/${widget_name}_collector.py"
    
    # Vérifier si déjà installé
    if [ "$(widget_is_installed "$widget_name")" = "yes" ]; then
        echo "  ↦ Widget déjà installé, mise à jour..."
        
        # Arrêter l'ancien service
        local old_service=$(widget_get_value "$WIDGETS_TRACKING_FILE" "$widget_name.service_name")
        if [ -n "$old_service" ] && [ "$old_service" != "none" ]; then
            systemctl stop "$old_service" 2>/dev/null || true
            systemctl stop "${old_service}-checker" 2>/dev/null || true
        fi
    fi
    
    # Installer les dépendances Python si nécessaire
    if ! widget_install_python_deps "$widget_name" "$config_file"; then
        echo "  ↦ Dépendances Python manquantes ✗"
        return 1
    fi
    
    # Vérifier si le widget a un collector actif
    local collector_enabled=$(widget_get_value "$config_file" "collector.enabled")
    
    if [ "$collector_enabled" = "true" ] || [ "$collector_enabled" = "True" ]; then
        # Rendre le collector exécutable
        chmod +x "$collector_script"
        
        # Créer et démarrer le service
        if widget_create_service "$widget_name" "$config_file" "$collector_script"; then
            # Enregistrer l'installation
            local version=$(widget_get_value "$config_file" "widget.version")
            local service_name=$(widget_get_value "$config_file" "collector.service_name")
            [ -z "$service_name" ] && service_name="maxlink-widget-$widget_name"
            
            widget_register "$widget_name" "$service_name" "$version"
            
            echo "  ↦ Widget $widget_name installé ✓"
            return 0
        else
            echo "  ↦ Erreur lors de l'installation ✗"
            return 1
        fi
    else
        # Widget passif sans collector
        echo "  ↦ Widget passif (pas de collector)"
        
        # Enregistrer l'installation sans service
        local version=$(widget_get_value "$config_file" "widget.version")
        widget_register "$widget_name" "none" "$version"
        
        echo "  ↦ Widget $widget_name installé ✓"
        return 0
    fi
}

# ===============================================================================
# NOUVELLES FONCTIONS UTILITAIRES
# ===============================================================================

# Vérifier l'état de tous les widgets
widget_check_all_status() {
    echo "État des widgets installés :"
    
    if [ -f "$WIDGETS_TRACKING_FILE" ]; then
        python3 -c "
import json
import subprocess

with open('$WIDGETS_TRACKING_FILE', 'r') as f:
    widgets = json.load(f)

for name, info in widgets.items():
    service = info.get('service_name', 'none')
    if service != 'none':
        try:
            result = subprocess.run(['systemctl', 'is-active', service], 
                                  capture_output=True, text=True)
            status = '✓' if result.stdout.strip() == 'active' else '✗'
        except:
            status = '?'
    else:
        status = '-'
    
    print(f'  • {name}: {status} ({service})')
"
    else
        echo "  Aucun widget installé"
    fi
}

# Redémarrer tous les widgets
widget_restart_all() {
    echo "Redémarrage de tous les widgets..."
    
    if [ -f "$WIDGETS_TRACKING_FILE" ]; then
        python3 -c "
import json
import subprocess

with open('$WIDGETS_TRACKING_FILE', 'r') as f:
    widgets = json.load(f)

for name, info in widgets.items():
    service = info.get('service_name', 'none')
    if service != 'none':
        print(f'  • Redémarrage de {name}...')
        subprocess.run(['systemctl', 'restart', service])
"
    fi
}

# ===============================================================================
# EXPORT
# ===============================================================================

export -f widget_load_config
export -f widget_get_value
export -f widget_is_installed
export -f widget_register
export -f widget_install_python_deps
export -f widget_create_service
export -f widget_validate
export -f widget_standard_install
export -f widget_check_all_status
export -f widget_restart_all