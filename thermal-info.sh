#!/usr/bin/env bash

# Thermal Monitor Script for Fujitsu Celsius H730
# Displays current temperatures and configured thresholds

# Color definitions
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
RESET=$(tput sgr0)

header() {
    echo "${BLUE}====[ $1 ]====${RESET}"
}

# Check required tools
check_dependencies() {
    if ! command -v sensors &> /dev/null; then
        echo "Install lm-sensors package first: sudo apt install lm-sensors"
        exit 1
    fi
}

show_cpu_temp() {
    header "CPU TEMPERATURES"
    sensors coretemp-isa-0000 | grep -E '(Package|Core)'
}

show_thermal_zones() {
    header "THERMAL ZONES"
    for zone in /sys/class/thermal/thermal_zone*; do
        type=$(cat $zone/type)
        temp=$(($(cat $zone/temp) / 1000))
        echo -n "${YELLOW}Zone ${zone##*thermal_zone}: ${type}${RESET} - "
        echo "Current: ${temp}C"
        
        # Show trip points
        i=0
        while [ -f $zone/trip_point_${i}_type ]; do
            type=$(cat $zone/trip_point_${i}_type)
            temp=$(($(cat $zone/trip_point_${i}_temp) / 1000))
            echo "  Trip $i: ${GREEN}${type}${RESET} at ${YELLOW}${temp}C${RESET}"
            ((i++))
        done
    done
}

show_thermald_config() {
    header "THERMALD CONFIGURATION"
    config_file="/etc/thermald/thermal-conf.xml"
    
    if [ -f "$config_file" ]; then
        echo "Using config: ${GREEN}${config_file}${RESET}"
        
        # Extract trip points using xmllint
        xmllint --xpath '//TripPoint/Temperature/text()' $config_file 2>/dev/null | \
            while read -r temp; do
                celsius=$((temp / 1000))
                echo "  Configured threshold: ${YELLOW}${celsius}C${RESET}"
            done
    else
        echo "${RED}No custom thermald config found${RESET}"
    fi
}

show_power_limits() {
    header "RAPL POWER LIMITS"
    rapl_path="/sys/class/powercap/intel-rapl/intel-rapl:0"
    
    if [ -d "$rapl_path" ]; then
        echo "Package Power Limits:"
        echo "  Long-term: $(cat $rapl_path/constraint_0_power_limit_uw) μW"
        echo "  Short-term: $(cat $rapl_path/constraint_1_power_limit_uw) μW"
        echo "  Max: $(cat $rapl_path/max_energy_range_uj) μJ"
    else
        echo "${RED}RAPL interface not available${RESET}"
    fi
}

show_legends() {
    header "LEGEND"
    echo "${GREEN}Passive${RESET} = Throttling actions"
    echo "${GREEN}Active${RESET}  = Active cooling measures"
    echo "${YELLOW}Values${RESET}  = Current measurements"
}

main() {
    check_dependencies
    show_cpu_temp
    show_thermal_zones
    show_thermald_config
    show_power_limits
    show_legends
}

# Run main function
main
