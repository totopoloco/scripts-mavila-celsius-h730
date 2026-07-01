#!/usr/bin/env bash

function show_help() {
    cat <<EOF

Usage: $(basename "$0") <command>

Commands:
  start      Start all services (ELK + others)
  stop       Stop all services
  restart    Restart all services
  status     Show status of services
  lf         Stop only Logstash + Filebeat
  help       Show this help message

Examples:
  ./$(basename "$0") start
  ./$(basename "$0") status
  ./$(basename "$0") lf

EOF
}

# List of all services to manage
ALL_SERVICES=(
    logstash
    filebeat
    kibana
    elasticsearch
    # metricbeat
    guacd
    tomcat9
)

stop_services() {
    echo "Stopping services..."
    for svc in "${ALL_SERVICES[@]}"; do
        echo " → Stopping $svc"
        sudo systemctl stop "$svc"
    done
}

start_services() {
    echo "Starting services..."
    for svc in "${ALL_SERVICES[@]}"; do
        echo " → Starting $svc"
        sudo systemctl start "$svc"
    done
}

status_services() {
    echo "Service statuses:"
    for svc in "${ALL_SERVICES[@]}"; do
        echo ""
        sudo systemctl status "$svc"
    done
}

# If no arguments provided, show help
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

case "$1" in
    start)
        start_services
        ;;

    stop)
        stop_services
        ;;

    restart)
        echo "Restarting everything..."
        stop_services
        start_services
        ;;

    status)
        status_services
        ;;

    lf)
        echo "Stopping Logstash & Filebeat only..."
        sudo systemctl stop logstash
        sudo systemctl stop filebeat
        ;;

    help|-h|--help)
        show_help
        ;;

    *)
        echo "⚠️  Unknown command: $1"
        show_help
        exit 1
        ;;
esac

exit 0

